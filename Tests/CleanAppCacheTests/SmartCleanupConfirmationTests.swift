import XCTest
@testable import CleanAppCacheLib

private struct ConfirmationScanner: ScannerProtocol {
    func performFullScan(progressHandler: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult {
        ScanResult(items: [], totalSize: 0, duration: 0, categorySizes: [:])
    }
    func cancel() async {}
}

private final class CleanupCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
    func record(_ url: URL) { lock.lock(); defer { lock.unlock() }; storage.append(url) }
}

@MainActor
final class SmartCleanupConfirmationTests: XCTestCase {
    private func fixture() throws -> (DashboardViewModel, [CleanableItem]) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cleanup-confirmation-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let items = try ["first.log", "second.log"].map { name in
            let url = root.appendingPathComponent(name)
            try Data(repeating: 65, count: 4096).write(to: url)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86400 * 30)],
                                 ofItemAtPath: url.path)
            return CleanableItem(url: url, category: .logs, size: 4096, itemCount: 1)
        }
        let vm = DashboardViewModel(scanner: ConfirmationScanner(), loadCache: false,
                                    cacheDirectory: root.appendingPathComponent("cache"))
        vm.scanResult = ScanResult(items: items, totalSize: 8192, duration: 0, categorySizes: [.logs: 8192])
        vm.selectedItems = [items[0].id]
        return (vm, items)
    }

    func testConfirmationKeepsItsSelectionAfterAnotherSurfaceChangesIt() async throws {
        let (vm, items) = try fixture()
        let selection = try XCTUnwrap(vm.prepareCleanup())
        vm.selectedItems = [items[1].id]
        let calls = CleanupCalls()
        let ran = await vm.cleanSelectedItems(selection: selection, trash: { url in
            calls.record(url)
            return .init(trashed: [], failed: [], alreadyGone: [url], freedBytes: 0)
        }, retryTrash: { _ in XCTFail("No escalation expected"); return .init(trashed: [], failed: [], freedBytes: 0) })
        vm.cancelScan()
        XCTAssertTrue(ran)
        XCTAssertEqual(calls.urls, [items[0].url])
        XCTAssertEqual(selection.count, 1)
        XCTAssertEqual(selection.size, 4096)
    }

    func testQuickCleanupPreparationDoesNotChangeWindowSelection() throws {
        let (vm, items) = try fixture()
        let selection = try XCTUnwrap(vm.prepareCleanup(safeOnly: true))
        XCTAssertEqual(selection.count, 2)
        XCTAssertEqual(vm.selectedItems, [items[0].id])
        XCTAssertFalse(selection.includesTrash)
    }

    func testPersistentExclusionProtectsItsParentAndRejectsOldConfirmation() async throws {
        let suite = "SmartCleanupExclusions-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
        let parent = root.appendingPathComponent("sample")
        let excluded = parent.appendingPathComponent("keep")
        let neighbor = root.appendingPathComponent("sample-neighbor")
        let items = [parent, excluded, neighbor].map {
            CleanableItem(url: $0, category: .logs, size: 4096, itemCount: 1)
        }
        let result = ScanResult(items: items, totalSize: 12288, duration: 0, categorySizes: [.logs: 12288])
        let vm = DashboardViewModel(loadCache: false, defaults: defaults)
        vm.scanResult = result
        vm.selectAll()
        let staleConfirmation = try XCTUnwrap(vm.prepareCleanup())
        vm.alwaysSkip(excluded)

        let ran = await vm.cleanSelectedItems(selection: staleConfirmation, trash: { _ in
            XCTFail("A protected item must invalidate the previous confirmation")
            return .init(trashed: [], failed: [], freedBytes: 0)
        }, retryTrash: { _ in
            XCTFail("No escalation expected")
            return .init(trashed: [], failed: [], freedBytes: 0)
        })
        XCTAssertFalse(ran)

        let reopened = DashboardViewModel(loadCache: false, defaults: defaults)
        reopened.scanResult = result
        reopened.selectAll()
        XCTAssertEqual(reopened.selectedItems, [items[2].id])
        XCTAssertEqual(reopened.prepareCleanup(safeOnly: true)?.count, 1)
        XCTAssertEqual(reopened.displayedSkipSummary.counts[.userExcluded], 2)
        reopened.removeExclusion(try XCTUnwrap(reopened.excludedPaths.first))
        reopened.selectAll()
        XCTAssertEqual(reopened.selectedItems.count, 3)
    }

    func testConfirmationBreakdownUsesOnlyItemsInTheFrozenSelection() throws {
        let (vm, logs) = try fixture()
        let trashed = CleanableItem(url: logs[0].url.appendingPathExtension("trashed"),
                                   category: .trash, size: 2048, itemCount: 1)
        vm.scanResult = ScanResult(items: logs + [trashed], totalSize: 10240, duration: 0,
                                   categorySizes: [.logs: 8192, .trash: 2048])
        vm.selectedItems = [logs[0].id, logs[1].id, trashed.id]
        vm.toggleSelection(for: logs[1])
        let selection = try XCTUnwrap(vm.prepareCleanup())
        vm.selectedItems = [logs[1].id]

        let summaries = selection.categorySummaries
        XCTAssertEqual(summaries.map(\.category), [.logs, .trash])
        XCTAssertEqual(summaries.map(\.count), [1, 1])
        XCTAssertEqual(summaries.map(\.bytes), [4096, 2048])
        XCTAssertEqual(selection.size, 6144)
    }

    func testHistoryCapturesActualCleanupOutcomeAndFailureReason() async throws {
        let (vm, items) = try fixture()
        let first = items[0].url
        vm.selectAll()
        let ran = await vm.cleanSelectedItems(trash: { url in
            if url == first {
                let moved = TrashService.Trashed(original: url, trashed: url.appendingPathExtension("moved"),
                                                 movedBytes: 2048)
                return .init(trashed: [moved], failed: [], freedBytes: 2048)
            }
            return .init(trashed: [], failed: [url], obstacles: [url: .locked], freedBytes: 0)
        }, retryTrash: { _ in
            XCTFail("No escalation expected")
            return .init(trashed: [], failed: [], freedBytes: 0)
        })
        vm.cancelScan()

        XCTAssertTrue(ran)
        let id = try XCTUnwrap(vm.lastCleanReport?.historyRecord)
        let report = try XCTUnwrap(CleanupHistory.shared.records.first { $0.id == id }?.report)
        XCTAssertEqual(report.categories.first?.selected, 2)
        XCTAssertEqual(report.categories.first?.removed, 1)
        XCTAssertEqual(report.categories.first?.bytes, 2048)
        XCTAssertEqual(report.failed, [.locked: 1])
        XCTAssertEqual(report.notAttempted, 0)
    }

    func testConfirmationRefusesReplacementScanAtTheSamePaths() async throws {
        let (vm, items) = try fixture()
        let selection = try XCTUnwrap(vm.prepareCleanup())
        let replacement = items.map { CleanableItem(url: $0.url, category: $0.category, size: $0.size, itemCount: 1) }
        vm.scanResult = ScanResult(items: replacement, totalSize: 8192, duration: 0, categorySizes: [:])
        let ran = await vm.cleanSelectedItems(selection: selection, trash: { _ in
            XCTFail("An old confirmation must not delete a new scan"); return .init(trashed: [], failed: [], freedBytes: 0)
        }, retryTrash: { _ in XCTFail("No escalation expected"); return .init(trashed: [], failed: [], freedBytes: 0) })
        XCTAssertFalse(ran)
        XCTAssertFalse(vm.isCleaning)
        XCTAssertNil(vm.lastCleanReport)
    }

    func testCancellationInvalidatesOutstandingConfirmation() async throws {
        let (vm, _) = try fixture()
        let selection = try XCTUnwrap(vm.prepareCleanup())
        vm.cancelScan()
        let ran = await vm.cleanSelectedItems(selection: selection, trash: { _ in
            XCTFail("Invalidated confirmation reached Trash"); return .init(trashed: [], failed: [], freedBytes: 0)
        }, retryTrash: { _ in XCTFail("No escalation expected"); return .init(trashed: [], failed: [], freedBytes: 0) })
        XCTAssertFalse(ran)
    }

    func testCachedResultsRequireFreshScanBeforeConfirmation() throws {
        let (vm, _) = try fixture()
        vm.showingCachedResult = true
        XCTAssertNil(vm.prepareCleanup())
        XCTAssertTrue(vm.isScanning)
        XCTAssertNil(vm.scanResult)
        vm.cancelScan()
    }

    func testChangedCacheCannotReachTheTrashMover() async throws {
        let (vm, items) = try fixture()
        let selected = items[0].url
        try FileManager.default.moveItem(at: selected, to: selected.appendingPathExtension("held"))
        let replacement = Data("new cache at the same path".utf8)
        try replacement.write(to: selected)
        let ran = await vm.cleanSelectedItems(trash: { _ in
            XCTFail("Replacement reached the mover"); return .init(trashed: [], failed: [], freedBytes: 0)
        }, retryTrash: { _ in XCTFail("Replacement reached Finder"); return .init(trashed: [], failed: [], freedBytes: 0) })
        vm.cancelScan()
        XCTAssertTrue(ran)
        XCTAssertEqual(vm.lastCleanReport?.failedCount, 1)
        XCTAssertEqual(vm.lastCleanReport?.cleanedCount, 0)
        XCTAssertEqual(try Data(contentsOf: selected), replacement)
    }

    func testChangedCacheCannotReachTheFinderRetry() async throws {
        let (vm, items) = try fixture()
        let selected = items[0].url
        let ran = await vm.cleanSelectedItems(trash: { url in
            try! FileManager.default.moveItem(at: url, to: url.appendingPathExtension("held"))
            try! Data("replacement".utf8).write(to: url)
            return .init(trashed: [], failed: [url], obstacles: [url: .needsAdmin], freedBytes: 0)
        }, retryTrash: { _ in XCTFail("Replacement reached Finder"); return .init(trashed: [], failed: [], freedBytes: 0) })
        vm.cancelScan()
        XCTAssertTrue(ran)
        XCTAssertEqual(vm.lastCleanReport?.failedCount, 1)
        XCTAssertEqual(vm.lastCleanReport?.cleanedCount, 0)
        XCTAssertEqual(try Data(contentsOf: selected), Data("replacement".utf8))
    }
}
