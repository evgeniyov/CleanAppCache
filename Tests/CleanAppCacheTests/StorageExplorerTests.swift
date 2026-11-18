import XCTest
@testable import CleanAppCacheLib

private final class ExplorerReads: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return paths }
}

@MainActor
final class StorageExplorerTests: XCTestCase {
    private var scratch: URL!
    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("explorer-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let physical = try XCTUnwrap(realpath(scratch.path, nil))
        scratch = URL(fileURLWithPath: String(cString: physical))
        free(physical)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: scratch) }
    private func folder(_ name: String) throws -> URL {
        let p = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        return p
    }
    private func model(_ explorer: StorageExplorer) -> StorageViewModel {
        let manager = StorageManager(diskCache: DiskCacheManager(directory: scratch.appendingPathComponent("isolated-cache")), measure: { _, _ in [:] })
        return StorageViewModel(manager: manager, explorer: explorer)
    }
    private func settle(_ model: StorageViewModel) async throws {
        for _ in 0..<300 where model.isLoadingDetail || model.isSizingDetail { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(model.isLoadingDetail)
        XCTAssertFalse(model.isSizingDetail)
    }

    func testUnassignedFrontierShowsHiddenTreesWithoutReadingTheirContents() throws {
        let home = try folder("Users/me")
        let docs = try folder("Users/me/Documents/Codex")
        let docsRoot = docs.deletingLastPathComponent()
        let caches = try folder("Users/me/Library/Caches")
        let support = try folder("Users/me/Library/Application Support")
        let projects = try folder("Users/me/Projects")
        let hidden = try folder("Users/me/.private/history")
        let apps = try folder("Applications")
        let reads = ExplorerReads()
        let alias = URL(fileURLWithPath: scratch.path.replacingOccurrences(of: "/private/var/", with: "/var/") + "/Users")
        let explorer = StorageExplorer(home: home, roots: [alias, apps],
                                       excluded: [docsRoot, caches, apps], volumes: [scratch], readDirectory: { url in
            reads.add(url.path)
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        })
        let listing = explorer.listing(path: "", unassigned: true)
        XCTAssertNil(listing.errorKey)
        XCTAssertTrue(listing.items.contains { $0.path == support.path })
        XCTAssertTrue(listing.items.contains { $0.path == projects.path })
        XCTAssertFalse(listing.items.contains { explorer.isExcluded($0.path) })
        XCTAssertTrue(listing.items.contains { $0.path == hidden.deletingLastPathComponent().path })
        XCTAssertFalse(reads.snapshot().contains { $0.hasPrefix(docsRoot.path) || $0.hasPrefix(hidden.deletingLastPathComponent().path) })
        XCTAssertFalse(listing.items.contains { explorer.containsCategories($0.path) })
    }

    func testPermissionFailureIsDistinctFromAnEmptyDirectoryAndCannotBeMeasuredAsZero() async throws {
        let blocked = try folder("blocked"), empty = try folder("empty")
        let explorer = StorageExplorer(home: scratch, roots: [blocked, empty], excluded: [], volumes: [scratch], readDirectory: { url in
            if url.path == blocked.path { throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError) }
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        })
        XCTAssertEqual(explorer.listing(path: blocked.path, unassigned: false).errorKey, "detail.accessDenied")
        XCTAssertNil(explorer.listing(path: empty.path, unassigned: false).errorKey)
        let listing = explorer.listing(path: scratch.path, unassigned: false)
        var results: [StorageItemDetail] = []
        for await value in explorer.stream(listing.items, unassigned: false) { results.append(value) }
        let denied = try XCTUnwrap(results.first { $0.path == blocked.path })
        XCTAssertTrue(denied.isPartial)
        XCTAssertEqual(denied.unavailableReason, "detail.accessDenied")
        XCTAssertEqual(denied.accessIssues.first?.path, blocked.path)
        XCTAssertEqual(denied.accessIssues.first?.reasonKey, "detail.accessDenied")
        XCTAssertTrue(!denied.sizeKnown || denied.isPartial)
        XCTAssertTrue(try XCTUnwrap(results.first { $0.path == empty.path }).sizeKnown)
    }

    func testPartiallyMeasuredParentStillOpensWhilePrivateChildStaysBlocked() async throws {
        let home = try folder("home")
        let privateStore = try folder("home/.ssh")
        let publicFolder = try folder("home/Projects")
        let reads = ExplorerReads()
        let explorer = StorageExplorer(home: home, roots: [scratch], excluded: [], volumes: [scratch],
                                       readDirectory: { url in
            reads.add(url.path)
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        })
        let model = model(explorer)
        model.openDiskBrowser(path: scratch.path)
        try await settle(model)

        let measuredHome = try XCTUnwrap(model.detailItems.first { $0.path == home.path })
        XCTAssertTrue(measuredHome.isPartial)
        XCTAssertNil(measuredHome.unavailableReason)
        XCTAssertEqual(measuredHome.accessIssues.first?.reasonKey, "detail.privateMetadata")
        XCTAssertTrue(measuredHome.canBrowseInStorage)

        model.pushPath(measuredHome.path)
        try await settle(model)
        XCTAssertNil(model.detailErrorKey)
        XCTAssertTrue(model.detailItems.contains { $0.path == publicFolder.path && $0.canBrowseInStorage })
        let privateItem = try XCTUnwrap(model.detailItems.first { $0.path == privateStore.path })
        XCTAssertEqual(privateItem.unavailableReason, "detail.privateMetadata")
        XCTAssertFalse(privateItem.canBrowseInStorage)
        XCTAssertFalse(reads.snapshot().contains(privateStore.path))
    }

    func testMeasureAgainRefreshesListingAndRetriesPreviouslyUnreadableFolder() async throws {
        let candidate = try folder("listing/candidate")
        let listingFolder = candidate.deletingLastPathComponent()
        let oldFile = listingFolder.appendingPathComponent("old")
        try Data().write(to: oldFile)
        let reads = ExplorerReads()
        let explorer = StorageExplorer(home: scratch, roots: [scratch], excluded: [], volumes: [scratch],
                                       readDirectory: { url in
            reads.add(url.path)
            if url.path == candidate.path, reads.snapshot().filter({ $0 == candidate.path }).count == 1 {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
            }
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        })
        let model = model(explorer)
        model.openDiskBrowser(path: listingFolder.path)
        try await settle(model)
        let first = try XCTUnwrap(model.detailItems.first { $0.path == candidate.path })
        XCTAssertEqual(first.unavailableReason, "detail.accessDenied")

        try FileManager.default.moveItem(at: oldFile, to: listingFolder.appendingPathComponent("new"))
        try Data(repeating: 65, count: 65536).write(to: candidate.appendingPathComponent("payload"))
        model.measureBrowserListing()
        try await settle(model)

        XCTAssertEqual(reads.snapshot().filter { $0 == listingFolder.path }.count, 2)
        XCTAssertEqual(reads.snapshot().filter { $0 == candidate.path }.count, 2)
        XCTAssertEqual(Set(model.detailItems.map(\.name)), ["candidate", "new"])
        let second = try XCTUnwrap(model.detailItems.first { $0.path == candidate.path })
        XCTAssertNil(second.unavailableReason)
        XCTAssertFalse(second.isPartial)
        XCTAssertGreaterThanOrEqual(second.size, 65536)
    }

    func testSeparateMeasurementOnlyReadsSelectedFolderAndDoesNotChangeListingTotal() async throws {
        let chosen = try folder("chosen")
        let excluded = try folder("excluded")
        let sibling = try folder("sibling")
        try Data(repeating: 65, count: 65536).write(to: chosen.appendingPathComponent("payload"))
        let reads = ExplorerReads()
        let explorer = StorageExplorer(home: scratch, roots: [scratch], excluded: [excluded], volumes: [scratch],
                                       readDirectory: { url in
            reads.add(url.path)
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        })
        let model = model(explorer)
        model.openDiskBrowser(path: scratch.path)
        try await settle(model)
        model.selectedDetailItem = try XCTUnwrap(model.detailItems.first { $0.path == chosen.path })
        model.measureSelectedFolder()
        for _ in 0..<300 where model.isMeasuringFolder { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(model.isMeasuringFolder)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(model.folderMeasurement).size, 65536)
        XCTAssertEqual(model.measuredDetailBytes, 0)
        XCTAssertFalse(reads.snapshot().contains(sibling.path))

        model.measureSelectedFolder()
        model.selectedDetailItem = model.detailItems.first { $0.path == sibling.path }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(model.isMeasuringFolder)
        XCTAssertNil(model.folderMeasurement)
    }

    func testHardLinksAcrossSiblingsAreCountedOnceAndSymlinkTargetsAreNotWalked() async throws {
        let a = try folder("a"), b = try folder("b"), outside = try folder("outside")
        let file = a.appendingPathComponent("original")
        try Data(repeating: 65, count: 65536).write(to: file)
        try FileManager.default.linkItem(at: file, to: b.appendingPathComponent("hard-link"))
        try Data(repeating: 66, count: 262144).write(to: outside.appendingPathComponent("unrelated"))
        try FileManager.default.createSymbolicLink(at: a.appendingPathComponent("symlink"), withDestinationURL: outside)
        let explorer = StorageExplorer(home: scratch, roots: [a, b], excluded: [], volumes: [scratch])
        let items = explorer.listing(path: scratch.path, unassigned: false).items.filter { $0.path == a.path || $0.path == b.path }
        var total: UInt64 = 0
        for await result in explorer.stream(items, unassigned: false) { XCTAssertTrue(result.sizeKnown); XCTAssertFalse(result.isPartial); total += result.size }
        let du = await DirectorySizeProbe.capture(executable: URL(fileURLWithPath: "/usr/bin/du"), arguments: ["-skx", a.path, b.path], timeout: 3)
        let expected = StorageClassification.parse(try XCTUnwrap(du), roots: [a, b]).values.reduce(0, +)
        XCTAssertEqual(total, expected)
        XCTAssertLessThan(total, 131072)
        let link = a.appendingPathComponent("symlink")
        XCTAssertEqual(explorer.listing(path: link.path, unassigned: false).errorKey, "detail.notDirectory")
    }

    func testBrowserAggregateUsesOnePassInsteadOfAddingIndependentHardLinkMetadata() async throws {
        let docs = try folder("listing/Documents")
        let listing = docs.deletingLastPathComponent()
        let file = listing.appendingPathComponent("a-original")
        try Data(repeating: 65, count: 65536).write(to: file)
        try FileManager.default.linkItem(at: file, to: listing.appendingPathComponent("b-link"))
        let explorer = StorageExplorer(home: scratch, roots: [scratch], excluded: [docs], volumes: [scratch])
        let model = model(explorer)
        model.openDiskBrowser(path: listing.path)
        try await settle(model)
        XCTAssertTrue(model.isBrowserAwaitingMeasurement)
        XCTAssertEqual(model.measuredDetailBytes, 0, "independent leaf metadata is not a deduplicated aggregate")
        XCTAssertTrue(model.hasPartialDetail)
        model.measureBrowserListing()
        try await settle(model)
        let roots = model.detailItems.map(\.url)
        let output = await DirectorySizeProbe.capture(executable: URL(fileURLWithPath: "/usr/bin/du"),
                                                      arguments: ["-skx"] + roots.map(\.path), timeout: 3)
        let expected = StorageClassification.parse(try XCTUnwrap(output), roots: roots).values.reduce(0, +)
        XCTAssertEqual(model.measuredDetailBytes, expected)
        XCTAssertFalse(model.hasPartialDetail)
        XCTAssertFalse(model.isBrowserAwaitingMeasurement)
    }

    func testOtherVolumesAreReportedBeforeEnumeratingTheirContents() throws {
        let reads = ExplorerReads()
        let explorer = StorageExplorer(home: scratch, roots: [scratch], excluded: [], volumes: [], readDirectory: { url in
            reads.add(url.path); return []
        })
        XCTAssertEqual(explorer.listing(path: scratch.path, unassigned: false).errorKey, "detail.externalVolume")
        XCTAssertTrue(reads.snapshot().isEmpty)
    }

    func testDiskRootPrioritizesVisibleFoldersWithoutMeasuringTheirContents() async throws {
        let folder = try folder("Projects")
        let hiddenFolder = try self.folder(".system")
        let file = scratch.appendingPathComponent("file")
        try Data().write(to: file)
        let explorer = StorageExplorer(home: scratch, roots: [], excluded: [],
                                       volumes: [URL(fileURLWithPath: "/"), scratch],
                                       readDirectory: { _ in [file, hiddenFolder, folder] })
        let model = model(explorer)
        model.openDiskBrowser()
        try await settle(model)

        XCTAssertEqual(model.sortMode, .nameAsc)
        XCTAssertEqual(model.filteredDetailItems.map(\.url.path), [folder.path, file.path, hiddenFolder.path])
        XCTAssertEqual(model.sizingCount, 0)
        XCTAssertFalse(try XCTUnwrap(model.filteredDetailItems.first).sizeKnown)
    }

    func testBrowseBackBreadcrumbRescanAndSortingKeepCategoryTotalsUnchanged() async throws {
        let docs = try folder("Documents"), data = try folder("Data")
        try Data(repeating: 65, count: 8192).write(to: data.appendingPathComponent("z-big"))
        try Data(repeating: 66, count: 4096).write(to: data.appendingPathComponent("a-small"))
        let explorer = StorageExplorer(home: scratch, roots: [scratch], excluded: [docs], volumes: [scratch])
        let model = model(explorer)
        model.breakdown = [.init(name: "Other", icon: "folder", bytes: 1000, path: "", percentOfTotal: 0.5, isResidual: true)]
        let categoryIDs = model.breakdown.map(\.id)
        model.openDiskBrowser(path: scratch.path)
        try await settle(model)
        XCTAssertEqual(model.browserMode, .disk)
        XCTAssertFalse(model.canGoBack)
        XCTAssertTrue(model.detailItems.contains { $0.path == data.path && !$0.sizeKnown }, "the overview must not recursively walk broad roots")
        model.pushPath(data.path)
        try await settle(model)
        XCTAssertEqual(model.filteredDetailItems.first?.name, "z-big")
        model.sortMode = .nameAsc
        XCTAssertEqual(model.filteredDetailItems.first?.name, "a-small")
        model.selectedDetailItem = model.detailItems.first
        try Data().write(to: data.appendingPathComponent("new"))
        model.reloadCurrentDetail()
        try await settle(model)
        XCTAssertEqual(model.detailItems.count, 3)
        XCTAssertEqual(model.detailPathStack.count, 2)
        XCTAssertNil(model.selectedDetailItem)
        model.popToDetailPath(0)
        try await settle(model)
        XCTAssertEqual(model.currentDetailPath, scratch.path)
        XCTAssertFalse(model.canGoBack)
        model.pushPath(data.path)
        try await settle(model)
        model.popPath()
        try await settle(model)
        XCTAssertEqual(model.currentDetailPath, scratch.path)
        XCTAssertEqual(model.breakdown.map(\.id), categoryIDs)
        XCTAssertEqual(model.breakdown.map(\.bytes), [1000])
    }

    func testBudgetAndCancellationLeaveUnknownOrPartialResultsAndDoNotPublishOldNavigation() async throws {
        let slow = try folder("slow"), fast = try folder("fast")
        for i in 0..<8 { _ = try folder("slow/child-\(i)") }
        try Data().write(to: fast.appendingPathComponent("ready"))
        let explorer = StorageExplorer(home: scratch, roots: [scratch], excluded: [], volumes: [scratch], readDirectory: { url in
            if url.path.hasPrefix(slow.path) { Thread.sleep(forTimeInterval: 0.04) }
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        })
        let listing = explorer.listing(path: scratch.path, unassigned: false).items.filter { $0.path == slow.path }
        var partial: [StorageItemDetail] = []
        for await value in explorer.stream(listing, unassigned: false, budget: 0.015) { partial.append(value) }
        XCTAssertTrue(try XCTUnwrap(partial.first).isPartial)
        XCTAssertEqual(partial.first?.accessIssues.last?.reasonKey, "detail.timeBudget")
        let model = model(explorer)
        model.openDiskBrowser(path: slow.path)
        model.cancelDetailSizing()
        XCTAssertEqual(model.currentDetailPath, slow.path)
        XCTAssertEqual(model.detailErrorKey, "detail.scanCancelled")
        model.openDiskBrowser(path: fast.path)
        try await settle(model)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(model.currentDetailPath, fast.path)
        XCTAssertEqual(model.detailItems.map(\.name), ["ready"])
        XCTAssertFalse(model.isSizingDetail)
        let start = DispatchTime.now().uptimeNanoseconds
        let work = Task { for await _ in explorer.stream(listing, unassigned: false) {} }
        try await Task.sleep(nanoseconds: 5_000_000)
        work.cancel()
        await work.value
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000, 0.5)
    }
}
