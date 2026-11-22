import Foundation
import XCTest
@testable import CleanAppCacheLib

final class StorageSnapshotTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private let today = Date(timeIntervalSinceReferenceDate: 900_000_000)

    private func daysAgo(_ days: Int) -> Date {
        calendar.date(byAdding: .day, value: -days, to: today)!
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    func testStoreKeepsLatestSnapshotPerCalendarDayOnDisk() async throws {
        let directory = try temporaryDirectory()
        let store = StorageSnapshotStore(directory: directory, calendar: calendar)
        let dayStart = calendar.startOfDay(for: today)
        let earlier = StorageSnapshot(date: dayStart, usedBytes: 10, categories: [])
        let later = StorageSnapshot(date: dayStart.addingTimeInterval(60), usedBytes: 20, categories: [])
        let yesterday = StorageSnapshot(date: dayStart.addingTimeInterval(-1), usedBytes: 30, categories: [])
        await store.record(later, now: today)
        await store.record(earlier, now: today)
        await store.record(yesterday, now: today)

        let reloaded = StorageSnapshotStore(directory: directory, calendar: calendar)
        let history = await reloaded.history(now: today)
        XCTAssertEqual(history, [yesterday, later])
    }

    func testStoreRetainsNinetyCalendarDays() async throws {
        let directory = try temporaryDirectory()
        let store = StorageSnapshotStore(directory: directory, calendar: calendar)
        let expired = StorageSnapshot(date: daysAgo(90), usedBytes: 10, categories: [])
        let boundary = StorageSnapshot(date: daysAgo(89), usedBytes: 20, categories: [])
        let current = StorageSnapshot(date: today, usedBytes: 30, categories: [])
        let file = directory.appendingPathComponent("storage-snapshots.json")
        try JSONEncoder().encode([expired, boundary]).write(to: file)
        let initial = await store.history(now: today)
        XCTAssertEqual(initial, [boundary])
        await store.record(current, now: today)
        XCTAssertEqual(try JSONDecoder().decode([StorageSnapshot].self, from: Data(contentsOf: file)), [boundary, current])
    }

    func testStoreIgnoresCorruptFileAndReplacesItOnRecord() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("storage-snapshots.json")
        try Data("corrupt".utf8).write(to: file)
        let store = StorageSnapshotStore(directory: directory, calendar: calendar)
        let empty = await store.history(now: today)
        XCTAssertTrue(empty.isEmpty)

        let sample = StorageSnapshot(date: today, usedBytes: 42, categories: [])
        await store.record(sample, now: today)
        let reloaded = StorageSnapshotStore(directory: directory, calendar: calendar)
        let history = await reloaded.history(now: today)
        XCTAssertEqual(history, [sample])
    }

    func testComparisonFiltersNoiseAndRanksOnlyCompleteChanges() {
        let category = StorageCategory.yourFolders.rawValue
        func member(_ id: String, _ bytes: UInt64, partial: Bool = false) -> StorageSnapshot.Member {
            .init(id: "/" + id, name: id, bytes: bytes, partial: partial, folderPath: "/" + id)
        }
        let from = StorageSnapshot(date: daysAgo(1), usedBytes: 1_000, categories: [
            .init(key: category, bytes: 99_000_000_000, partial: false, members: [
                member("below byte threshold", 10),
                member("below percentage threshold", 30_000_000_000),
                member("on threshold", 10),
                member("shrink", 500_000_000),
                member("access changed", 1, partial: true),
                member("old", 1)
            ]),
            .init(key: StorageCategory.other.rawValue, bytes: 8, partial: true)
        ])
        let to = StorageSnapshot(date: today, usedBytes: 1_200, categories: [
            .init(key: category, bytes: 99_000_000_000, partial: false, members: [
                member("below byte threshold", 99_000_010),
                member("below percentage threshold", 30_200_000_000),
                member("on threshold", 100_000_010),
                member("shrink", 100_000_000),
                member("access changed", 8_000_000_000),
                member("new", 1)
            ]),
            .init(key: StorageCategory.other.rawValue, bytes: 8, partial: false)
        ])
        let result = StorageSnapshotComparison(from: from, to: to, cleanups: [
            .init(date: from.date, source: .smartCleanup, itemCount: 1, freedBytes: 99),
            .init(date: today, source: .smartCleanup, itemCount: 2, freedBytes: 100, trashedBytes: 200),
            .init(date: today.addingTimeInterval(1), source: .trash, itemCount: 1, freedBytes: 400)
        ])
        XCTAssertEqual(result.usedDelta, 200)
        XCTAssertEqual(result.freedBytes, 100)
        XCTAssertEqual(result.trashedBytes, 200)
        let known = result.changes.filter { !$0.uncertain }
        XCTAssertEqual(known.compactMap { $0.member?.name }, ["shrink", "on threshold", "new", "old"])
        XCTAssertEqual(known.map(\.delta), [-400_000_000, 100_000_000, 1, -1])
        XCTAssertEqual(known[2].presence, .added)
        XCTAssertEqual(known[2].folderPath, "/new")
        XCTAssertEqual(known[3].presence, .removed)
        XCTAssertNil(known[3].folderPath)
        let uncertain = result.changes.filter(\.uncertain)
        XCTAssertEqual(uncertain.count, 2)
        XCTAssertEqual(uncertain.compactMap { $0.member?.name }, ["access changed"])
        XCTAssertEqual(uncertain.last?.currentPartial, false)
    }

    func testPeriodUsesNearestEarlierSnapshotAndReportsShortHistory() {
        let history = [0, 3, 8, 20].map { StorageSnapshot(date: daysAgo($0), usedBytes: 0, categories: []) }
        XCTAssertNil(StorageSnapshotPeriod.week.select(Array(history.prefix(1)), calendar: calendar))
        let previous = StorageSnapshotPeriod.previous.select(history, calendar: calendar)
        XCTAssertEqual(previous?.from.date, daysAgo(3))
        XCTAssertEqual(previous?.to.date, today)
        let week = StorageSnapshotPeriod.week.select(history, calendar: calendar)
        XCTAssertEqual(week?.from.date, daysAgo(8))
        XCTAssertEqual(week?.shortHistory, false)
        let month = StorageSnapshotPeriod.month.select(history, calendar: calendar)
        XCTAssertEqual(month?.from.date, daysAgo(20))
        XCTAssertEqual(month?.shortHistory, true)
    }

    func testPartialAPFSGroupDoesNotRankMeasuredPrebootAsExact() throws {
        let category = StorageCategory.serviceVolumes.rawValue
        func snapshot(date: Date, prebootBytes: UInt64, isPartial: Bool) -> StorageSnapshot {
            let volumes = StorageAPFSVolumes(members: [
                .init(device: "disk3s3", name: "Preboot", roles: ["Preboot"], bytes: prebootBytes)
            ], isPartial: isPartial)
            let used: UInt64 = 20_000_000_000
            let rows = StorageClassification.breakdown(targets: [], measurement: .init(), volumes: volumes,
                                                       total: used, used: used)
            return StorageSnapshot(date: date, usedBytes: used, breakdown: rows)
        }

        let from = snapshot(date: daysAgo(1), prebootBytes: 10_000_000_000, isPartial: false)
        let to = snapshot(date: today, prebootBytes: 2_000_000_000, isPartial: true)
        let preboot = try XCTUnwrap(to.categories.first { $0.key == category }?.members.first)
        XCTAssertTrue(preboot.partial)
        let comparison = StorageSnapshotComparison(from: from, to: to)
        let change = try XCTUnwrap(comparison.changes.first { $0.member?.id == "Preboot" })
        XCTAssertTrue(change.uncertain)
        XCTAssertTrue(change.currentPartial)

        let saved = StorageSnapshot(date: today, usedBytes: to.usedBytes, categories: [
            .init(key: category, bytes: preboot.bytes, partial: true, members: [
                .init(id: preboot.id, name: preboot.name, bytes: preboot.bytes, partial: false)
            ])
        ])
        let savedComparison = StorageSnapshotComparison(from: from, to: saved)
        XCTAssertTrue(try XCTUnwrap(savedComparison.changes.first { $0.member?.id == "Preboot" }).uncertain)
    }

    func testBackgroundDecisionRespectsAgePowerToggleAndDailyAttempt() {
        func shouldMeasure(latest: Date? = nil, lastAttempt: Date? = nil, enabled: Bool = true,
                           running: Bool = false, lowPower: Bool = false) -> Bool {
            StorageBackgroundDecision.shouldMeasure(now: today, latest: latest, lastAttempt: lastAttempt,
                                                    enabled: enabled, isRunning: running, lowPower: lowPower,
                                                    calendar: calendar)
        }
        XCTAssertTrue(shouldMeasure())
        XCTAssertFalse(shouldMeasure(latest: daysAgo(1)))
        XCTAssertTrue(shouldMeasure(latest: daysAgo(1).addingTimeInterval(-1)))
        XCTAssertFalse(shouldMeasure(lastAttempt: today.addingTimeInterval(-60)))
        XCTAssertTrue(shouldMeasure(lastAttempt: daysAgo(1)))
        XCTAssertFalse(shouldMeasure(enabled: false))
        XCTAssertFalse(shouldMeasure(running: true))
        XCTAssertFalse(shouldMeasure(lowPower: true))
    }
}
