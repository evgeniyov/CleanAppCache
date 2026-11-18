import XCTest
@testable import CleanAppCacheLib

final class SystemJunkCoverageTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("system-junk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    func testUnreadableRootIsNotReportedAsEmptySuccess() {
        var summary = ScanSkipSummary()
        let root = URL(fileURLWithPath: "/synthetic/unreadable")
        let entries = SystemJunkManager.directoryContents(root, skipped: &summary) { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        }
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(summary.counts[.unreadable], 1)
        XCTAssertEqual(summary.paths.first?.path, root.path)
        XCTAssertTrue(summary.needsNotice)
    }

    func testAbsentOptionalRootIsNotAnAccessFailure() {
        var summary = ScanSkipSummary()
        let entries = SystemJunkManager.directoryContents(URL(fileURLWithPath: "/synthetic/absent"), skipped: &summary) { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        }
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(summary.totalCount, 0)
    }

    func testSuccessfulEmptyRootHasNoSkippedWarning() {
        var summary = ScanSkipSummary()
        let entries = SystemJunkManager.directoryContents(URL(fileURLWithPath: "/synthetic/empty"), skipped: &summary) { _ in [] }
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(summary.needsNotice)
    }

    func testCleanupLeavesRecentlyWrittenDownloadAndRecognizesMissingDownload() async throws {
        let root = try scratch()
        let recent = root.appendingPathComponent("recent.part")
        let gone = root.appendingPathComponent("gone.part")
        try Data("resumed".utf8).write(to: recent)
        let entry = SystemJunkEntry(category: .brokenDownloads, urls: [recent, gone], totalSize: 1)

        let result = await SystemJunkManager.shared.clean(entry)

        XCTAssertEqual(result.validationRejected, [recent])
        XCTAssertEqual(result.obstacles[recent], .inUse)
        XCTAssertEqual(result.alreadyGone, [gone])
        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertEqual(try String(contentsOf: recent), "resumed")
    }

    func testFinderRetryRejectsDownloadResumedAfterPermissionFailure() throws {
        let root = try scratch()
        let download = root.appendingPathComponent("resumed.download", isDirectory: true)
        try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
        let contents = download.appendingPathComponent("payload")
        try Data("old".utf8).write(to: contents)
        for path in [contents, download] {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: path.path)
        }
        XCTAssertTrue(SystemJunkManager.canMoveToTrash(download, category: .brokenDownloads))
        let initial = TrashService.Result(trashed: [], failed: [download],
                                          obstacles: [download: .needsAdmin], freedBytes: 0)
        try Data("resumed".utf8).write(to: contents)

        let result = TrashService.escalate(initial, knownSizes: [:], allowing: [], validation: { url in
            SystemJunkManager.canMoveToTrash(url, category: .brokenDownloads)
        }, dispatch: { _ in
            XCTFail("Finder must receive no request for an active download")
            return .init(status: 1, stdout: "", stderr: "", timedOut: false)
        })

        XCTAssertEqual(result.validationRejected, [download])
        XCTAssertEqual(result.obstacles[download], .inUse)
        XCTAssertEqual(try String(contentsOf: contents), "resumed")
    }
}
