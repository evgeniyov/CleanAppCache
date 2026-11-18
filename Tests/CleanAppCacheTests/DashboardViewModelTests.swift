import XCTest
@testable import CleanAppCacheLib

private struct EmptyDashboardScanner: ScannerProtocol {
    func performFullScan(progressHandler: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult {
        ScanResult(items: [], totalSize: 0, duration: 0, categorySizes: [:])
    }

    func cancel() async {}
}

@MainActor
final class DashboardViewModelTests: XCTestCase {
    
    func testInitialState() {
        let vm = DashboardViewModel(loadCache: false)
        XCTAssertNil(vm.scanResult)
        XCTAssertFalse(vm.isScanning)
        XCTAssertTrue(vm.selectedItems.isEmpty)
        XCTAssertFalse(vm.isCleaning)
        XCTAssertEqual(vm.cleaningProgress, 0)
    }
    
    func testSelectionToggling() {
        let vm = DashboardViewModel(loadCache: false)
        let item = CleanableItem(
            url: URL(fileURLWithPath: "/tmp/test"),
            category: .tempFiles,
            size: 100,
            itemCount: 1
        )
        
        vm.toggleSelection(for: item)
        XCTAssertTrue(vm.selectedItems.contains(item.id))
        
        vm.toggleSelection(for: item)
        XCTAssertFalse(vm.selectedItems.contains(item.id))
    }
    
    func testSelectAllAndDeselectAll() {
        let vm = DashboardViewModel(loadCache: false)
        let items = [
            CleanableItem(url: URL(fileURLWithPath: "/tmp/1"), category: .userCache, size: 100, itemCount: 1),
            CleanableItem(url: URL(fileURLWithPath: "/tmp/2"), category: .logs, size: 200, itemCount: 1)
        ]

        vm.scanResult = ScanResult(
            items: items,
            totalSize: 300,
            duration: 0.5,
            categorySizes: [.userCache: 100, .logs: 200]
        )
        
        vm.selectAll()
        XCTAssertEqual(vm.selectedItems.count, 2)
        XCTAssertEqual(vm.selectedSize, 300)
        
        vm.deselectAll()
        XCTAssertTrue(vm.selectedItems.isEmpty)
        XCTAssertEqual(vm.selectedSize, 0)
    }

    func testEmptyTrashKeepsReplacementAtScannedPath() async throws {
        try await checkPermanentTrash(replaceAfterScan: true)
    }

    func testEmptyTrashErasesUnchangedScannedItem() async throws {
        try await checkPermanentTrash(replaceAfterScan: false)
    }

    private func checkPermanentTrash(replaceAfterScan: Bool) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cac-trash-identity-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let url = root.appendingPathComponent("item")
        let original = Data("scanned item".utf8)
        let replacement = Data("replacement item".utf8)
        try original.write(to: url)
        let scan = await Scanner.shared.scanCategory(
            category: .trash, source: .children(roots: [.init(root.path)], excluding: []))
        let item = try XCTUnwrap(scan.items.first)
        let vm = DashboardViewModel(scanner: EmptyDashboardScanner(), loadCache: false,
                                    cacheDirectory: root.appendingPathComponent("cache"))
        vm.scanResult = ScanResult(items: [item], totalSize: item.size, duration: 0,
                                   categorySizes: [.trash: item.size])
        vm.selectAll()

        let originalURL = root.appendingPathComponent("original")
        if replaceAfterScan {
            try fm.moveItem(at: url, to: originalURL)
            try replacement.write(to: url)
        }
        let ran = await vm.cleanSelectedItems()
        XCTAssertTrue(ran)
        let report = try XCTUnwrap(vm.lastCleanReport)
        vm.cancelScan()

        if replaceAfterScan {
            XCTAssertEqual(report.cleanedCount, 0)
            XCTAssertEqual(report.failedCount, 1)
            XCTAssertEqual(report.erasedBytes, 0)
            XCTAssertEqual(try Data(contentsOf: url), replacement)
            XCTAssertEqual(try Data(contentsOf: originalURL), original)
        } else {
            XCTAssertEqual(report.cleanedCount, 1)
            XCTAssertEqual(report.failedCount, 0)
            XCTAssertFalse(fm.fileExists(atPath: url.path))
        }
    }
}
