import XCTest
@testable import CleanAppCacheLib

private struct IdleScanner: ScannerProtocol {
    func performFullScan(progressHandler: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult {
        ScanResult(items: [], totalSize: 0, duration: 0, categorySizes: [:])
    }
    func cancel() async {}
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return stored }
    func record(_ url: URL) { lock.lock(); stored.append(url); lock.unlock() }
}

/// Smart Cleanup beyond the Trash move itself: the password retry for items
/// this account may not move, items that changed before that retry, items
/// written to recently, and a second clean racing the first.
@MainActor
final class SmartCleanupEscalationTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("cleanup-escalation-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func item(_ name: String, age: TimeInterval = 86400 * 30) throws -> CleanableItem {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 65, count: 4096).write(to: url)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
        return CleanableItem(url: url, category: .logs, size: 4096, itemCount: 1)
    }

    private func viewModel(_ items: [CleanableItem]) -> DashboardViewModel {
        let vm = DashboardViewModel(scanner: IdleScanner(), loadCache: false,
                                    cacheDirectory: root.appendingPathComponent("state"))
        vm.scanResult = ScanResult(items: items, totalSize: UInt64(items.count) * 4096, duration: 0,
                                   categorySizes: [.logs: UInt64(items.count) * 4096])
        vm.selectAll()
        return vm
    }

    private func settle(_ vm: DashboardViewModel) async throws {
        for _ in 0..<200 where vm.isScanning { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(vm.isScanning)
    }

    private nonisolated static func moved(_ url: URL, bytes: UInt64 = 4096) -> TrashService.Trashed {
        TrashService.Trashed(original: url, trashed: url.appendingPathExtension("moved"), movedBytes: bytes)
    }

    private nonisolated static func refusedForRights(_ url: URL) -> TrashService.Result {
        .init(trashed: [], failed: [url], obstacles: [url: .needsAdmin], freedBytes: 0)
    }

    func testRefusedItemsAreRetriedTogetherAndCountedOnceTheyMove() async throws {
        let protected = [try item("a.log"), try item("b.log")]
        let vm = viewModel(protected)
        let retries = Calls()
        let urls = protected.map(\.url)

        let ran = await vm.cleanSelectedItems(trash: { Self.refusedForRights($0) }, retryTrash: { candidates in
            candidates.forEach(retries.record)
            return .init(trashed: candidates.map { Self.moved($0) }, failed: [],
                         freedBytes: 4096 * UInt64(candidates.count))
        })
        try await settle(vm)

        XCTAssertTrue(ran)
        XCTAssertEqual(retries.urls, urls, "one request, so one password covers the batch")
        let report = try XCTUnwrap(vm.lastCleanReport)
        XCTAssertEqual(report.cleanedCount, 2)
        XCTAssertEqual(report.trashedBytes, 8192)
        XCTAssertEqual(report.failedCount, 0)
        XCTAssertEqual(report.trashed.map(\.original), urls)
        XCTAssertEqual(vm.cleanupOutcome, DashboardViewModel.CleanupOutcome(freedBytes: 0, trashedBytes: 8192))
    }

    func testItemReplacedAfterTheRefusalNeverReachesTheRetry() async throws {
        let swapped = try item("swapped.log")
        let steady = try item("steady.log")
        let vm = viewModel([swapped, steady])
        let retries = Calls()

        let ran = await vm.cleanSelectedItems(trash: { url in
            if url == swapped.url {
                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("held"))
                try? Data("new content".utf8).write(to: url)
            }
            return Self.refusedForRights(url)
        }, retryTrash: { candidates in
            candidates.forEach(retries.record)
            return .init(trashed: candidates.map { Self.moved($0) }, failed: [], freedBytes: 4096)
        })
        try await settle(vm)

        XCTAssertTrue(ran)
        XCTAssertEqual(retries.urls, [steady.url], "the replacement must not be handed to Finder")
        XCTAssertEqual(try String(contentsOf: swapped.url), "new content")
        let report = try XCTUnwrap(vm.lastCleanReport)
        XCTAssertEqual(report.cleanedCount, 1)
        XCTAssertEqual(report.failedCount, 1)
    }

    func testItemRemovedAfterTheRefusalIsCountedGoneAndNotRetried() async throws {
        let vanished = try item("vanished.log")
        let vm = viewModel([vanished])

        let ran = await vm.cleanSelectedItems(trash: { url in
            try? FileManager.default.removeItem(at: url)
            return Self.refusedForRights(url)
        }, retryTrash: { _ in
            XCTFail("nothing is left to ask Finder about")
            return .init(trashed: [], failed: [], freedBytes: 0)
        })
        try await settle(vm)

        XCTAssertTrue(ran)
        let report = try XCTUnwrap(vm.lastCleanReport)
        XCTAssertEqual(report.alreadyGoneCount, 1)
        XCTAssertEqual(report.cleanedCount, 0)
        XCTAssertEqual(report.failedCount, 0)
    }

    func testRecentlyWrittenItemIsLeftAloneAndOldOnesStillMove() async throws {
        let live = try item("live.log", age: 5)
        let old = try item("old.log")
        let vm = viewModel([live, old])
        let attempted = Calls()

        let ran = await vm.cleanSelectedItems(trash: { url in
            attempted.record(url)
            return .init(trashed: [Self.moved(url)], failed: [], freedBytes: 4096)
        }, retryTrash: { _ in .init(trashed: [], failed: [], freedBytes: 0) })
        try await settle(vm)

        XCTAssertTrue(ran)
        XCTAssertEqual(attempted.urls, [old.url], "a log written in the last hour may be in use")
        XCTAssertTrue(fm.fileExists(atPath: live.url.path))
        let report = try XCTUnwrap(vm.lastCleanReport)
        XCTAssertEqual(report.cleanedCount, 1)
        XCTAssertEqual(report.failedCount, 1, "the skipped item is reported, not silently dropped")
        XCTAssertEqual(vm.cleanupSkipped.counts[.recent], 1)
    }

    func testSecondCleanWhileOneIsRunningDoesNothing() async throws {
        let only = try item("only.log")
        let vm = viewModel([only])
        vm.isCleaning = true

        let ran = await vm.cleanSelectedItems(trash: { _ in
            XCTFail("a clean already in progress must not start another")
            return .init(trashed: [], failed: [], freedBytes: 0)
        }, retryTrash: { _ in .init(trashed: [], failed: [], freedBytes: 0) })

        XCTAssertFalse(ran)
        XCTAssertTrue(fm.fileExists(atPath: only.url.path))
        XCTAssertTrue(vm.isCleaning, "the running clean's flag is not cleared by the refused one")
    }

    func testNothingSelectedRunsNothing() async throws {
        let only = try item("only.log")
        let vm = viewModel([only])
        vm.deselectAll()

        let ran = await vm.cleanSelectedItems(trash: { _ in
            XCTFail("an empty selection must not move anything")
            return .init(trashed: [], failed: [], freedBytes: 0)
        }, retryTrash: { _ in .init(trashed: [], failed: [], freedBytes: 0) })

        XCTAssertFalse(ran)
        XCTAssertNil(vm.lastCleanReport)
        XCTAssertFalse(vm.isCleaning)
    }
}
