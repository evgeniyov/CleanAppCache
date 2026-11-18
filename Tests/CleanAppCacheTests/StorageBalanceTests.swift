import XCTest
@testable import CleanAppCacheLib

private final class BalanceReads: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    private var denied = true
    func record(_ path: String) { lock.lock(); values.append(path); lock.unlock() }
    func paths() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
    func blocked() -> Bool { lock.lock(); defer { lock.unlock() }; return denied }
    func allow() { lock.lock(); denied = false; lock.unlock() }
}

@MainActor
final class StorageBalanceTests: XCTestCase {
    private var scratch: URL!
    override func setUpWithError() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("balance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let physical = try XCTUnwrap(realpath(path.path, nil))
        scratch = URL(fileURLWithPath: String(cString: physical)); free(physical)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: scratch) }
    private func folder(_ name: String) throws -> URL {
        let path = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    private func model(_ explorer: StorageExplorer) -> StorageViewModel {
        StorageViewModel(manager: StorageManager(diskCache: DiskCacheManager(directory: scratch.appendingPathComponent("cache")),
                                                measure: { _, _ in [:] }), explorer: explorer)
    }
    private func settle(_ model: StorageViewModel) async throws {
        for _ in 0..<600 where model.isLoadingDetail || model.isSizingDetail {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(model.isLoadingDetail); XCTAssertFalse(model.isSizingDetail)
    }

    func testHiddenModelCacheIsVisibleWhilePrivateHistoryNeverGetsEnumerated() async throws {
        let home = try folder("Users/me"), docs = try folder("Users/me/Documents")
        let cache = try folder("Users/me/.cache/models"), secrets = try folder("Users/me/.codex/sessions")
        try Data(repeating: 65, count: 8192).write(to: cache.appendingPathComponent("model"))
        let reads = BalanceReads()
        let explorer = StorageExplorer(home: home, roots: [home], excluded: [docs], volumes: [scratch], readDirectory: { url in
            reads.record(url.path)
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        })
        let listing = explorer.listing(path: "", unassigned: true)
        XCTAssertTrue(listing.items.contains { $0.path == cache.deletingLastPathComponent().path })
        XCTAssertEqual(listing.items.first { $0.name == ".codex" }?.unavailableReason, "detail.privateMetadata")
        var measured: [StorageItemDetail] = []
        for await value in explorer.stream(listing.items, unassigned: true) { measured.append(value) }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(measured.first { $0.name == ".cache" }).size, 8192)
        XCTAssertFalse(reads.paths().contains { $0.hasPrefix(secrets.deletingLastPathComponent().path) })
        XCTAssertEqual(explorer.listing(path: secrets.path, unassigned: false).errorKey, "detail.privateMetadata")
    }

    func testPartialSnapshotSurvivesClosingReopeningAndExplicitRefreshRetries() async throws {
        let docs = try folder("Documents"), data = try folder("Data"), blocked = try folder("Data/blocked")
        try Data(repeating: 65, count: 8192).write(to: data.appendingPathComponent("ready"))
        try Data(repeating: 66, count: 16384).write(to: blocked.appendingPathComponent("later"))
        let reads = BalanceReads()
        let explorer = StorageExplorer(home: scratch, roots: [scratch], excluded: [docs], volumes: [scratch], readDirectory: { url in
            reads.record(url.path)
            if url.path == blocked.path && reads.blocked() { throw CocoaError(.fileReadNoPermission) }
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        })
        let owner = model(explorer)
        let first = owner.makeDetailBrowser()
        first.openDiskBrowser(path: data.path)
        try await settle(first)
        XCTAssertTrue(first.hasPartialDetail)
        let total = first.measuredDetailBytes
        let timestamp = try XCTUnwrap(first.detailMeasuredAt)
        XCTAssertGreaterThanOrEqual(total, 8192)
        let blockedItem = try XCTUnwrap(first.detailItems.first { $0.path == blocked.path })
        XCTAssertEqual(blockedItem.accessIssues.first?.path, blocked.path)
        first.cancelDetailSizing()
        let before = reads.paths().count
        let reopened = owner.makeDetailBrowser()
        reopened.openDiskBrowser(path: data.path)
        try await settle(reopened)
        XCTAssertEqual(reopened.measuredDetailBytes, total)
        XCTAssertEqual(reopened.detailMeasuredAt, timestamp)
        XCTAssertTrue(reopened.detailScanLimited)
        XCTAssertEqual(reads.paths().count, before)

        // A new owner and disk-cache actor simulate a process restart.
        let restarted = model(explorer).makeDetailBrowser()
        restarted.openDiskBrowser(path: data.path)
        try await settle(restarted)
        XCTAssertEqual(restarted.measuredDetailBytes, total)
        XCTAssertEqual(restarted.detailMeasuredAt, timestamp)
        XCTAssertTrue(restarted.isDetailSnapshotStale)
        XCTAssertTrue(restarted.detailScanLimited)
        XCTAssertEqual(restarted.detailItems.first { $0.path == blocked.path }?.accessIssues.first?.path, blocked.path)
        XCTAssertEqual(reads.paths().count, before, "Restoring the saved list must not walk the filesystem")

        reads.allow()
        restarted.measureBrowserListing()
        try await settle(restarted)
        XCTAssertFalse(restarted.hasPartialDetail)
        XCTAssertGreaterThan(restarted.measuredDetailBytes, total)
        XCTAssertNotEqual(restarted.detailMeasuredAt, timestamp)
        let refreshed = model(explorer).makeDetailBrowser()
        refreshed.openDiskBrowser(path: data.path)
        try await settle(refreshed)
        XCTAssertEqual(refreshed.detailMeasuredAt, restarted.detailMeasuredAt)
        XCTAssertEqual(refreshed.measuredDetailBytes, restarted.measuredDetailBytes)
    }

    func testUnknownAndPartialRowsRemainVisibleThroughSizeFilterAndDoNotDrawComparisons() throws {
        let explorer = StorageExplorer(home: scratch, roots: [scratch], excluded: [], volumes: [scratch])
        let viewModel = model(explorer)
        viewModel.detailItems = [
            .init(url: scratch.appendingPathComponent("unknown"), size: 0, isDirectory: true, sizeKnown: false),
            .init(url: scratch.appendingPathComponent("partial"), size: 1, isDirectory: true, isPartial: true),
            .init(url: scratch.appendingPathComponent("tiny"), size: 1, isDirectory: false)
        ]
        viewModel.minSizeMB = 100
        XCTAssertEqual(Set(viewModel.filteredDetailItems.map(\.name)), ["unknown", "partial"])
        XCTAssertFalse(viewModel.canCompareDetailSizes)
        viewModel.sortMode = .sizeAsc
        XCTAssertEqual(viewModel.filteredDetailItems.last?.name, "unknown")
        XCTAssertEqual(viewModel.pendingDetailCount, 3)
    }

    func testTimeoutRetainsCompletedProbeOutputAndDrainsLargeSeparateDiagnostics() async throws {
        let response = await DirectorySizeProbe.captureResponse(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '12\\t/synthetic\\n'; i=0; while [ $i -lt 5000 ]; do printf 'unreadable diagnostic line\\n' >&2; i=$((i+1)); done; while :; do :; done"], timeout: 0.2)
        let value = try XCTUnwrap(response)
        XCTAssertTrue(value.timedOut)
        XCTAssertFalse(value.succeeded)
        XCTAssertEqual(StorageClassification.parse(value.data, roots: [URL(fileURLWithPath: "/synthetic")]), ["/synthetic": 12288])
        XCTAssertFalse(value.diagnostics.isEmpty)
        XCTAssertLessThanOrEqual(value.diagnostics.count, 65536)
        XCTAssertFalse(String(decoding: value.data, as: UTF8.self).contains("unreadable"))
    }
}
