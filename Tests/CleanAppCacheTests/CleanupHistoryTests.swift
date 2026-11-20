import XCTest
@testable import CleanAppCacheLib

@MainActor
final class CleanupHistoryTests: XCTestCase {

    /// A `let` of a Sendable type, so the nonisolated `tearDown` can read it.
    private let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cleanup_history_\(UUID().uuidString)", isDirectory: true)

    private var fileURL: URL { dir.appendingPathComponent("cleanup-history.json") }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testMissingFileStartsEmpty() {
        let history = CleanupHistory(directory: dir)
        XCTAssertTrue(history.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.corruptFileURL.path))
    }

    func testCorruptFileIsPreservedAndHistoryStartsEmpty() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let garbage = Data("{ not a history".utf8)
        try garbage.write(to: fileURL)

        let history = CleanupHistory(directory: dir)

        XCTAssertTrue(history.records.isEmpty)
        XCTAssertEqual(history.corruptFileURL.lastPathComponent, "cleanup-history.json.corrupt")
        XCTAssertEqual(try Data(contentsOf: history.corruptFileURL), garbage)
        XCTAssertFalse(fm.fileExists(atPath: fileURL.path))

        // A later save writes a fresh file and leaves the corrupt copy intact.
        history.log(.trash, items: 1, freedBytes:10)
        XCTAssertTrue(fm.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try Data(contentsOf: history.corruptFileURL), garbage)
    }

    func testCorruptFileReplacesOlderCorruptCopy() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: fileURL.appendingPathExtension("corrupt"))
        let garbage = Data("new".utf8)
        try garbage.write(to: fileURL)

        let history = CleanupHistory(directory: dir)

        XCTAssertTrue(history.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: history.corruptFileURL), garbage)
    }

    func testRecordsRoundTripThroughSaveAndLoad() {
        let first = CleanupHistory(directory: dir)
        first.log(.systemJunk, items: 3, freedBytes:1_024)
        first.log(.duplicates, items: 2, freedBytes:4_096)
        first.log(.developer, items: 0, freedBytes:0)   // no-op, not recorded
        XCTAssertEqual(first.records.count, 2)

        let second = CleanupHistory(directory: dir)
        XCTAssertEqual(second.records.map(\.id), first.records.map(\.id))
        XCTAssertEqual(second.records.map(\.source), [.duplicates, .systemJunk])
        XCTAssertEqual(second.records.map(\.itemCount), [2, 3])
        XCTAssertEqual(second.records.map(\.freedBytes), [4_096, 1_024])
        for (a, b) in zip(second.records, first.records) {
            // ISO 8601 keeps whole seconds only.
            XCTAssertEqual(a.date.timeIntervalSince1970, b.date.timeIntervalSince1970, accuracy: 1)
        }
        XCTAssertEqual(second.totalFreedBytes, 5_120)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.corruptFileURL.path))
    }

    func testTrashMovesAreKeptApartFromFreedSpace() {
        let first = CleanupHistory(directory: dir)
        first.log(.largeFiles, items: 2, trashedBytes: 2_048)
        first.log(.smartCleanup, items: 5, freedBytes: 1_000, trashedBytes: 3_000)
        XCTAssertEqual(first.totalFreedBytes, 1_000)
        XCTAssertEqual(first.totalTrashedBytes, 5_048)

        let second = CleanupHistory(directory: dir)
        XCTAssertEqual(second.records.map(\.freedBytes), [1_000, 0])
        XCTAssertEqual(second.records.map(\.trashedBytes), [3_000, 2_048])
        XCTAssertEqual(second.totalFreedBytes, 1_000)
    }

    func testTrashOnlyCleanupIsRecorded() {
        let history = CleanupHistory(directory: dir)
        history.log(.duplicates, items: 0, trashedBytes: 512)
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.totalFreedBytes, 0)
    }

    func testRecordWithoutTrashedBytesStillDecodes() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = """
        [{"itemCount":107,"date":"2026-09-15T11:13:20Z","freedBytes":9465106432,\
        "id":"5020455C-0DB2-4E06-908F-5C059127AA3C","source":"smartCleanup"}]
        """
        try Data(legacy.utf8).write(to: fileURL)

        let history = CleanupHistory(directory: dir)

        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records.first?.freedBytes, 9_465_106_432)
        XCTAssertEqual(history.records.first?.trashedBytes, 0)
        XCTAssertNil(history.records.first?.report)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.corruptFileURL.path))
    }

    func testClearPersists() {
        let first = CleanupHistory(directory: dir)
        first.log(.trash, items: 1, freedBytes:1)
        first.clear()
        XCTAssertTrue(CleanupHistory(directory: dir).records.isEmpty)
    }

    func testDetailedReportSurvivesReloadAndPartialUndo() throws {
        let history = CleanupHistory(directory: dir)
        let report = CleanupRecord.Report(
            categories: [.init(category: .logs, selected: 4, removed: 2, bytes: 500)],
            skipped: [.recent: 1], failed: [.locked: 1], alreadyGone: 0, notAttempted: 0)
        let id = history.log(.smartCleanup, items: 2, trashedBytes: 500, report: report)
        history.undoTrashMoves(id, restoredBytes: 100)

        let reloaded = CleanupHistory(directory: dir)
        let record = try XCTUnwrap(reloaded.records.first)
        XCTAssertEqual(record.trashedBytes, 400)
        XCTAssertEqual(record.report?.categories.first?.bytes, 500)
        XCTAssertEqual(record.report?.skipped, [.recent: 1])
        XCTAssertEqual(record.report?.failed, [.locked: 1])
    }

    func testUndoTakesBackOnlyTheTrashMoves() {
        let history = CleanupHistory(directory: dir)
        let trashOnly = history.log(.largeFiles, items: 2, trashedBytes: 500)
        let mixed = history.log(.smartCleanup, items: 3, freedBytes: 100, trashedBytes: 700)

        history.undoTrashMoves(trashOnly)
        history.undoTrashMoves(mixed)

        XCTAssertEqual(history.records.count, 1, "a record that only moved files to the Trash goes")
        XCTAssertEqual(history.records.first?.freedBytes, 100, "what was erased for good stays")
        XCTAssertEqual(history.records.first?.trashedBytes, 0)
        XCTAssertEqual(CleanupHistory(directory: dir).records.count, 1, "the change is saved")
    }

    func testPartialUndoKeepsZeroByteMoveInHistoryUntilItIsRestored() throws {
        let history = CleanupHistory(directory: dir)
        let original = dir.appendingPathComponent("regular")
        let zeroOriginal = dir.appendingPathComponent("empty")
        let trashed = dir.appendingPathComponent("trashed-regular")
        let zeroTrashed = dir.appendingPathComponent("trashed-empty")
        try Data("regular".utf8).write(to: trashed)
        try Data().write(to: zeroTrashed)
        try Data("collision".utf8).write(to: zeroOriginal)
        let zero = TrashService.Trashed(original: zeroOriginal, trashed: zeroTrashed)
        let regular = TrashService.Trashed(original: original, trashed: trashed, movedBytes: 4096)
        let id = history.log(.leftovers, items: 2, trashedBytes: 4096)

        XCTAssertEqual(TrashService.restore([regular, zero], recordingUndoOf: id, history: history), 1)
        let remaining = try XCTUnwrap(CleanupHistory(directory: dir).records.first)
        XCTAssertEqual(remaining.itemCount, 1)
        XCTAssertEqual(remaining.trashedBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zeroTrashed.path))

        try FileManager.default.removeItem(at: zeroOriginal)
        XCTAssertEqual(TrashService.restore([zero], recordingUndoOf: id, history: history), 1)
        XCTAssertTrue(CleanupHistory(directory: dir).records.isEmpty)
    }

    func testOneUnreadableRecordCostsOnlyItself() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        [{"id":"\(UUID().uuidString)","date":"2026-09-01T10:00:00Z","source":"largeFiles","itemCount":1,"freedBytes":0,"trashedBytes":10},
         {"id":"\(UUID().uuidString)","date":"2026-09-02T10:00:00Z","source":"fromTheFuture","itemCount":1,"freedBytes":5}]
        """
        try Data(json.utf8).write(to: fileURL)

        let history = CleanupHistory(directory: dir)

        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records.first?.source, .largeFiles)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.corruptFileURL.path))
    }
}
