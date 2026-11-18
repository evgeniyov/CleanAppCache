import XCTest
@testable import CleanAppCacheLib

// The fixture blocks a utility thread at a known I/O boundary; it never blocks
// MainActor and always times out if a test exits before releasing the gate.
private func storageReviewWait(_ signal: DispatchSemaphore, seconds: Double = 5) -> Bool {
    signal.wait(timeout: .now() + seconds) == .success
}

private final class StorageReviewReads: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var denied = false
    func record() { lock.lock(); calls += 1; lock.unlock() }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return calls }
    func setDenied(_ value: Bool) { lock.lock(); denied = value; lock.unlock() }
    func isDenied() -> Bool { lock.lock(); defer { lock.unlock() }; return denied }
}

@MainActor
final class StorageReviewRegressionTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("storage-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let physical = try XCTUnwrap(realpath(scratch.path, nil))
        scratch = URL(fileURLWithPath: String(cString: physical))
        free(physical)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: scratch) }

    private func folder(_ name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func model(_ explorer: StorageExplorer) -> StorageViewModel {
        let cache = DiskCacheManager(directory: scratch.appendingPathComponent("isolated-cache"))
        return StorageViewModel(manager: StorageManager(diskCache: cache, measure: { _, _ in [:] }), explorer: explorer)
    }

    private func category(_ url: URL) -> StorageBreakdown {
        StorageBreakdown(name: "Documents", icon: "folder", bytes: 0, path: url.path, percentOfTotal: 0)
    }

    private func settle(_ model: StorageViewModel) async throws {
        for _ in 0..<600 where model.isLoadingDetail || model.isSizingDetail {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(model.isLoadingDetail)
        XCTAssertFalse(model.isSizingDetail)
    }

    func testDiskAndUnassignedSheetsCannotReplaceCategoryPreviewOrItsSelection() async throws {
        let docs = try folder("Documents"), disk = try folder("Disk"), nested = try folder("Disk/nested")
        try Data(repeating: 65, count: 8192).write(to: docs.appendingPathComponent("document"))
        try Data(repeating: 66, count: 4096).write(to: nested.appendingPathComponent("disk-file"))
        let explorer = StorageExplorer(home: scratch, roots: [disk], excluded: [docs], volumes: [scratch])
        let preview = model(explorer)
        let selected = category(docs)
        preview.loadDetail(for: selected)
        try await settle(preview)
        preview.selectedDetailItem = preview.detailItems.first
        preview.searchText = "document"
        let rowIDs = preview.detailItems.map(\.id)
        let total = preview.measuredDetailBytes

        let browser = preview.makeDetailBrowser()
        browser.openDiskBrowser(path: disk.path)
        try await settle(browser)
        browser.pushPath(nested.path)
        try await settle(browser)
        browser.cancelDetailSizing()
        XCTAssertEqual(preview.browserMode, .category)
        XCTAssertEqual(preview.selectedBreakdown?.id, selected.id)
        XCTAssertEqual(preview.currentDetailPath, docs.path)
        XCTAssertEqual(preview.detailItems.map(\.id), rowIDs)
        XCTAssertEqual(preview.selectedDetailItem?.id, rowIDs.first)
        XCTAssertEqual(preview.searchText, "document")
        XCTAssertEqual(preview.measuredDetailBytes, total)

        let unassigned = preview.makeDetailBrowser()
        unassigned.openUnassignedFolders()
        try await settle(unassigned)
        unassigned.cancelDetailSizing()
        let reopened = preview.makeDetailBrowser()
        reopened.loadDetail(for: selected)
        try await settle(reopened)
        XCTAssertEqual(reopened.browserMode, .category)
        XCTAssertEqual(reopened.currentDetailPath, docs.path)
        XCTAssertEqual(reopened.detailItems.map(\.id), rowIDs)
        XCTAssertEqual(preview.detailItems.map(\.id), rowIDs)
    }

    func testCategoryCountsHardLinkedLeavesOnceWithoutStartingDirectoryProbes() async throws {
        let docs = try folder("Documents")
        let original = docs.appendingPathComponent("original")
        try Data(repeating: 65, count: 65536).write(to: original)
        try FileManager.default.linkItem(at: original, to: docs.appendingPathComponent("link"))
        let explorer = StorageExplorer(home: scratch, roots: [docs], excluded: [], volumes: [scratch])
        let cache = DiskCacheManager(directory: scratch.appendingPathComponent("isolated-cache"))
        let calls = StorageReviewReads()
        let manager = StorageManager(diskCache: cache, measure: { _, _ in calls.record(); return [:] })
        let model = StorageViewModel(manager: manager, explorer: explorer)
        model.loadDetail(for: category(docs))
        try await settle(model)
        XCTAssertEqual(model.detailItems.count, 2)
        XCTAssertEqual(model.measuredDetailBytes, StorageManager.allocatedLeafSize(at: original))
        XCTAssertEqual(model.detailItems.reduce(0) { $0 + $1.size }, model.measuredDetailBytes)
        XCTAssertTrue(model.detailItems.allSatisfy(\.hasSharedAllocation), "both the attributed row and the zero row need the explanation")
        XCTAssertEqual(model.detailItems.filter { $0.size == 0 }.count, 1)
        XCTAssertFalse(model.hasPartialDetail)
        XCTAssertEqual(calls.count(), 0)
    }

    func testCategoryDeduplicatesAcrossLeavesAndSubfoldersIncludingWarmNavigation() async throws {
        let docs = try folder("Documents"), a = try folder("Documents/a"), b = try folder("Documents/b")
        let original = docs.appendingPathComponent("original")
        try Data(repeating: 65, count: 65536).write(to: original)
        try FileManager.default.linkItem(at: original, to: a.appendingPathComponent("link"))
        try FileManager.default.linkItem(at: original, to: b.appendingPathComponent("link"))
        let reads = StorageReviewReads()
        let explorer = StorageExplorer(home: scratch, roots: [docs], excluded: [], volumes: [scratch], readDirectory: { url in
            reads.record()
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        })
        let cache = DiskCacheManager(directory: scratch.appendingPathComponent("isolated-cache"))
        // Independent cached totals cannot be reused as shares in a new scope.
        await cache.setSize(131072, for: a.path, isDirectory: true)
        await cache.setSize(131072, for: b.path, isDirectory: true)
        let model = StorageViewModel(manager: StorageManager(diskCache: cache, measure: { _, _ in [:] }), explorer: explorer)
        model.loadDetail(for: category(docs))
        try await settle(model)
        let roots = model.detailItems.map(\.url)
        let output = await DirectorySizeProbe.capture(executable: URL(fileURLWithPath: "/usr/bin/du"),
                                                      arguments: ["-skx"] + roots.map(\.path), timeout: 3)
        let expected = StorageClassification.parse(try XCTUnwrap(output), roots: roots).values.reduce(0, +)
        XCTAssertEqual(model.measuredDetailBytes, expected)
        XCTAssertEqual(model.detailItems.reduce(0) { $0 + $1.size }, expected)
        XCTAssertTrue(model.detailItems.allSatisfy(\.hasSharedAllocation))
        XCTAssertFalse(model.hasPartialDetail)
        let ids = model.detailItems.map(\.id)
        model.pushPath(a.path)
        try await settle(model)
        XCTAssertEqual(model.measuredDetailBytes, StorageManager.allocatedLeafSize(at: original), "a new scope has its own inode accounting")
        let beforeBack = reads.count()
        model.popPath()
        try await settle(model)
        XCTAssertEqual(model.detailItems.map(\.id), ids)
        XCTAssertEqual(model.measuredDetailBytes, expected)
        XCTAssertEqual(reads.count(), beforeBack, "only a complete, coherent listing is reused")
    }

    func testPartialCategoryRemainsRetryableAndClosingSheetDoesNotCancelPreview() async throws {
        let docs = try folder("Documents"), child = try folder("Documents/child")
        try Data(repeating: 65, count: 8192).write(to: child.appendingPathComponent("file"))
        let state = StorageReviewReads()
        state.setDenied(true)
        let explorer = StorageExplorer(home: scratch, roots: [docs], excluded: [], volumes: [scratch], readDirectory: { url in
            state.record()
            if url.path == child.path && state.isDenied() { throw CocoaError(.fileReadNoPermission) }
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        })
        let preview = model(explorer)
        let selected = category(docs)
        preview.loadDetail(for: selected)
        try await settle(preview)
        XCTAssertTrue(preview.hasPartialDetail)
        state.setDenied(false)
        let before = state.count()
        preview.loadDetail(for: selected)
        let browser = preview.makeDetailBrowser()
        browser.openDiskBrowser(path: docs.path)
        browser.cancelDetailSizing()
        try await settle(preview)
        XCTAssertGreaterThan(state.count(), before)
        XCTAssertFalse(preview.hasPartialDetail)
        XCTAssertGreaterThanOrEqual(preview.measuredDetailBytes, 8192)
    }

    func testWideCategoryWarmListingAvoidsTraversalAndKeepsAllocationStable() async throws {
        let docs = try folder("Documents")
        for index in 0..<1200 {
            try Data(repeating: 65, count: 1024).write(to: docs.appendingPathComponent("file-\(index)"))
        }
        for index in 0..<8 { _ = try folder("Documents/folder-\(index)") }
        let reads = StorageReviewReads()
        let explorer = StorageExplorer(home: scratch, roots: [docs], excluded: [], volumes: [scratch], readDirectory: { url in
            reads.record()
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        })
        let model = model(explorer)
        let selected = category(docs)
        let start = DispatchTime.now().uptimeNanoseconds
        model.loadDetail(for: selected)
        try await settle(model)
        let coldMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let sizes = Dictionary(uniqueKeysWithValues: model.detailItems.map { ($0.url, $0.size) })
        let total = model.measuredDetailBytes
        let coldReads = reads.count()
        model.loadDetail(for: selected)
        XCTAssertFalse(model.isLoadingDetail)
        XCTAssertFalse(model.isSizingDetail)
        XCTAssertEqual(model.detailItems.count, 1208)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: model.detailItems.map { ($0.url, $0.size) }), sizes)
        XCTAssertEqual(model.measuredDetailBytes, total)
        XCTAssertEqual(reads.count(), coldReads)
        XCTAssertFalse(model.hasPartialDetail)
        print("STORAGE_REVIEW_BENCH categoryEntries=1208 coldMS=\(coldMS) warmDirectoryReads=0")
    }

    func testCancellationAfterDirectoryReadSkipsAllMetadataAndSorting() async throws {
        let docs = try folder("Documents")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let urls = (0..<10000).map { docs.appendingPathComponent("missing-\($0)") }
        let explorer = StorageExplorer(home: scratch, roots: [docs], excluded: [], volumes: [scratch], readDirectory: { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            return urls
        })
        let work = Task.detached { explorer.listing(path: docs.path, unassigned: false) }
        let started = await Task.detached { storageReviewWait(entered, seconds: 3) }.value
        XCTAssertTrue(started)
        work.cancel()
        release.signal()
        let result = await work.value
        XCTAssertTrue(result.items.isEmpty, "cancelled enumeration must not process the returned entries")
        XCTAssertEqual(result.errorKey, "detail.scanCancelled")
        XCTAssertTrue(result.limited)
    }

    func testCancelledListingDoesNotStartReadingDirectory() async throws {
        let docs = try folder("Documents")
        let release = DispatchSemaphore(value: 0)
        let reads = StorageReviewReads()
        let explorer = StorageExplorer(home: scratch, roots: [docs], excluded: [], volumes: [scratch], readDirectory: { _ in
            reads.record()
            return []
        })
        let work = Task.detached {
            _ = storageReviewWait(release)
            return explorer.listing(path: docs.path, unassigned: false)
        }
        work.cancel()
        release.signal()
        let result = await work.value
        XCTAssertEqual(reads.count(), 0)
        XCTAssertEqual(result.errorKey, "detail.scanCancelled")
    }

    func testPerFolderBudgetStillAttemptsLaterSiblings() async throws {
        let docs = try folder("Documents")
        for index in 0..<8 { _ = try folder("Documents/child-\(index)") }
        let explorer = StorageExplorer(home: scratch, roots: [docs], excluded: [], volumes: [scratch], readDirectory: { url in
            if url.lastPathComponent.hasPrefix("child-") { Thread.sleep(forTimeInterval: 0.03) }
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        })
        let listing = explorer.listing(path: docs.path, unassigned: false)
        var results: [StorageItemDetail] = []
        for await item in explorer.stream(listing.items, unassigned: false, budget: 0.01, perItemBudget: true) {
            results.append(item)
        }
        XCTAssertEqual(Set(results.map(\.url)), Set(listing.items.map(\.url)))
    }
}
