import XCTest
@testable import CleanAppCacheLib

private func waitForStorageInvalidationRead(_ signal: DispatchSemaphore) -> Bool {
    signal.wait(timeout: .now() + 3) == .success
}

private actor SuspendedSizeProbe {
    private var continuation: CheckedContinuation<[String: UInt64], Never>?
    private(set) var started = false

    func measure() async -> [String: UInt64] {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish(_ result: [String: UInt64]) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
final class StorageInvalidationTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("storage-invalidation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Match StorageExplorer's realpath spelling; Foundation can abbreviate
        // /private/var back to /var when resolving the temporary directory.
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

    func testExactInvalidationSurvivesRestartWithoutAnotherScan() async throws {
        let cacheRoot = try folder("cache")
        let cache = DiskCacheManager(directory: cacheRoot)
        await cache.setSize(8192, for: "/fixture/deleted", isDirectory: true)
        await cache.setSize(4096, for: "/fixture/retained", isDirectory: true)
        await cache.saveToDisk()
        await cache.invalidate(paths: ["/fixture/deleted"])

        let restarted = DiskCacheManager(directory: cacheRoot)
        let deleted = await restarted.getSize(for: "/fixture/deleted")
        let retained = await restarted.getSize(for: "/fixture/retained")
        XCTAssertNil(deleted)
        XCTAssertEqual(retained, 4096)
    }

    func testDeletedDirectoryExpiresItsDescendantsButNotPrefixNeighbors() async throws {
        let cacheRoot = try folder("cache")
        let cache = DiskCacheManager(directory: cacheRoot)
        for path in ["/fixture", "/fixture/gone", "/fixture/gone/child", "/fixture/gone-other/child"] {
            await cache.setSize(8192, for: path, isDirectory: true)
        }
        await cache.saveToDisk()
        let manager = StorageManager(diskCache: cache, measure: { _, _ in [:] })
        await manager.invalidate(deleted: [URL(fileURLWithPath: "/fixture/gone")])

        let restarted = DiskCacheManager(directory: cacheRoot)
        for path in ["/fixture", "/fixture/gone", "/fixture/gone/child"] {
            let stale = await restarted.getSize(for: path)
            XCTAssertNil(stale, path)
        }
        let neighbor = await restarted.getSize(for: "/fixture/gone-other/child")
        XCTAssertEqual(neighbor, 8192)
    }

    func testProbeFinishingAfterDeletionCannotRestoreOldCacheOrPublishOldSize() async throws {
        try await checkSuspendedProbe(clearAll: false)
    }

    func testProbeFinishingAfterCacheResetCannotRestoreOldCacheOrPublishOldSize() async throws {
        try await checkSuspendedProbe(clearAll: true)
    }

    private func checkSuspendedProbe(clearAll: Bool) async throws {
        let cacheRoot = try folder("cache"), target = try folder("target")
        let cache = DiskCacheManager(directory: cacheRoot)
        let probe = SuspendedSizeProbe()
        let manager = StorageManager(diskCache: cache, measure: { _, _ in await probe.measure() })
        let work = Task { await manager.bulkDirectorySizes(urls: [target], timeout: 1) }
        for _ in 0..<200 {
            if await probe.started { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let started = await probe.started
        XCTAssertTrue(started)
        if clearAll { await manager.invalidateAll() }
        else { await manager.invalidate(deleted: [target.appendingPathComponent("deleted")]) }
        await probe.finish([target.path: 8192])
        let result = await work.value
        let cached = await cache.getSize(for: target.path)
        XCTAssertNil(result[target.path], "a measurement spanning a deletion has no coherent size")
        XCTAssertNil(cached)
        await cache.saveToDisk()
        let restarted = DiskCacheManager(directory: cacheRoot)
        let persisted = await restarted.getSize(for: target.path)
        XCTAssertNil(persisted)
    }

    func testVisibleDetailBecomesStaleAndRefreshReadsChangedDirectory() async throws {
        let target = try folder("target")
        try Data(repeating: 65, count: 4096).write(to: target.appendingPathComponent("first"))
        let cacheDirectory = try folder("cache")
        let cache = DiskCacheManager(directory: cacheDirectory)
        let manager = StorageManager(diskCache: cache, measure: { _, _ in [:] })
        let explorer = StorageExplorer(home: scratch, roots: [target], excluded: [], volumes: [scratch])
        let model = StorageViewModel(manager: manager, explorer: explorer)
        model.openDiskBrowser(path: target.path)
        try await settle(model)
        XCTAssertTrue(model.canCompareDetailSizes)
        let saved = await DiskCacheManager(directory: cacheDirectory).browserSnapshot(for: "disk:\(target.path)").snapshot
        XCTAssertNotNil(saved)
        try Data(repeating: 66, count: 8192).write(to: target.appendingPathComponent("new"))
        await manager.invalidate(deleted: [target.appendingPathComponent("first")])
        let invalidated = await DiskCacheManager(directory: cacheDirectory).browserSnapshot(for: "disk:\(target.path)").snapshot
        XCTAssertNil(invalidated)
        for _ in 0..<200 where !model.isDetailSnapshotStale { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(model.isDetailSnapshotStale)
        XCTAssertFalse(model.canCompareDetailSizes)
        model.cancelDetailSizing()
        model.openDiskBrowser(path: target.path)
        try await settle(model)
        XCTAssertEqual(Set(model.detailItems.map(\.name)), ["first", "new"])
        XCTAssertFalse(model.isDetailSnapshotStale)
        XCTAssertTrue(model.canCompareDetailSizes)
    }

    func testInvalidationCancelsOpenMeasurementAndCannotCacheItsLateResult() async throws {
        let target = try folder("target"), child = try folder("target/child")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let cache = DiskCacheManager(directory: try folder("cache"))
        let manager = StorageManager(diskCache: cache, measure: { _, _ in [:] })
        let explorer = StorageExplorer(home: scratch, roots: [target], excluded: [], volumes: [scratch], readDirectory: { url in
            if url.path == child.path {
                entered.signal()
                _ = release.wait(timeout: .now() + 3)
            }
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        })
        let model = StorageViewModel(manager: manager, explorer: explorer)
        model.openDiskBrowser(path: target.path)
        let started = await Task.detached { waitForStorageInvalidationRead(entered) }.value
        XCTAssertTrue(started)
        let originalID = model.detailItems.first?.id
        await manager.invalidate(deleted: [child.appendingPathComponent("changed")])
        for _ in 0..<200 where !model.isDetailSnapshotStale { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(model.isDetailSnapshotStale)
        XCTAssertFalse(model.isSizingDetail)
        release.signal()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(model.isDetailSnapshotStale, "late work must not make an invalidated snapshot fresh")
        // A cancelled snapshot must not return to the shared navigation cache.
        model.cancelDetailSizing()
        release.signal()
        model.openDiskBrowser(path: target.path)
        try await settle(model)
        XCTAssertNotEqual(model.detailItems.first?.id, originalID)
        XCTAssertFalse(model.isDetailSnapshotStale)
    }

    func testRestartHidesExternallyDeletedRowsAndRetainsSavedMeasurements() async throws {
        let target = try folder("target")
        let deleted = try folder("target/deleted")
        let retained = try folder("target/retained")
        let other = try folder("other")
        let otherFile = other.appendingPathComponent("file")
        try Data(repeating: 65, count: 4096).write(to: deleted.appendingPathComponent("file"))
        try Data(repeating: 66, count: 8192).write(to: retained.appendingPathComponent("file"))
        try Data(repeating: 67, count: 4096).write(to: otherFile)
        let cacheRoot = try folder("cache")
        let explorer = StorageExplorer(home: scratch, roots: [target], excluded: [], volumes: [scratch])
        let manager = StorageManager(diskCache: DiskCacheManager(directory: cacheRoot), measure: { _, _ in [:] })
        let model = StorageViewModel(manager: manager, explorer: explorer)
        model.openDiskBrowser(path: target.path)
        try await settle(model)
        let original = try XCTUnwrap(model.detailItems.first { $0.name == "retained" })
        let originalDate = try XCTUnwrap(model.detailMeasuredAt)
        model.openDiskBrowser(path: other.path)
        try await settle(model)
        let otherDate = try XCTUnwrap(model.detailMeasuredAt)
        let otherSize = try XCTUnwrap(model.detailItems.first?.size)

        try FileManager.default.removeItem(at: deleted)
        try Data(repeating: 68, count: 16_384).write(to: retained.appendingPathComponent("added"))
        _ = try folder("target/new")

        let restartedManager = StorageManager(diskCache: DiskCacheManager(directory: cacheRoot), measure: { _, _ in [:] })
        let restarted = StorageViewModel(manager: restartedManager, explorer: explorer)
        restarted.openDiskBrowser(path: target.path)
        try await settle(restarted)
        XCTAssertEqual(restarted.detailItems.map(\.name), ["retained"])
        XCTAssertEqual(restarted.detailItems.first?.size, original.size)
        XCTAssertEqual(restarted.detailMeasuredAt, originalDate)
        XCTAssertEqual(restarted.sizingCount, 1)
        XCTAssertTrue(restarted.isDetailSnapshotStale)

        restarted.openDiskBrowser(path: other.path)
        try await settle(restarted)
        XCTAssertEqual(restarted.detailItems.first?.size, otherSize)
        XCTAssertEqual(restarted.detailMeasuredAt, otherDate)
        XCTAssertTrue(restarted.isDetailSnapshotStale)
    }

    func testExternalBrowserDoesNotRestoreAnotherVolumesMeasurementAtTheSamePath() async throws {
        let target = try folder("external")
        let child = try folder("external/data")
        try Data(repeating: 65, count: 4096).write(to: child.appendingPathComponent("file"))
        let uuid = try XCTUnwrap(try target.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        var metadata = stat()
        XCTAssertEqual(lstat(target.path, &metadata), 0)
        let volume = StorageVolume(url: target, name: "External", uuid: uuid, device: metadata.st_dev)
        let cache = DiskCacheManager(directory: try folder("cache"))
        let manager = StorageManager(diskCache: cache, measure: { _, _ in [:] })
        let browser = StorageViewModel(manager: manager, explorer: StorageExplorer(volume: volume, home: scratch))
        let old = StorageItemDetail(url: child, size: 8192, isDirectory: true)
        let previous = StorageBrowserSnapshot(
            listing: .init(items: [old], directoryIdentity: StorageDirectoryIdentity(metadata)),
            measured: [child], date: Date(timeIntervalSince1970: 1))
        let unrelatedKey = "volume:\(UUID().uuidString):disk:\(target.path)"
        let generation = await cache.generation
        let saved = await cache.saveBrowserSnapshot(previous, for: unrelatedKey, ifGeneration: generation)
        XCTAssertTrue(saved)

        browser.openDiskBrowser(path: target.path)
        try await settle(browser)
        XCTAssertEqual(browser.detailItems.map(\.name), ["data"])
        XCTAssertNil(browser.detailMeasuredAt)
        XCTAssertEqual(browser.sizingCount, 0)

        browser.measureBrowserListing()
        try await settle(browser)
        let measured = try XCTUnwrap(browser.detailMeasuredAt)
        let reopened = StorageViewModel(manager: manager, explorer: StorageExplorer(volume: volume, home: scratch))
        reopened.openDiskBrowser(path: target.path)
        try await settle(reopened)
        XCTAssertEqual(reopened.detailMeasuredAt, measured)
        XCTAssertEqual(reopened.measuredDetailBytes, browser.measuredDetailBytes)
    }

    func testMeasureEmptyRestoredListingFindsRenamedOnlyChild() async throws {
        let target = try folder("target")
        let old = try folder("target/before")
        try Data(repeating: 65, count: 4096).write(to: old.appendingPathComponent("file"))
        let cacheRoot = try folder("cache")
        let explorer = StorageExplorer(home: scratch, roots: [target], excluded: [], volumes: [scratch])
        let manager = StorageManager(diskCache: DiskCacheManager(directory: cacheRoot), measure: { _, _ in [:] })
        let model = StorageViewModel(manager: manager, explorer: explorer)
        model.openDiskBrowser(path: target.path)
        try await settle(model)
        XCTAssertEqual(model.detailItems.map(\.name), ["before"])
        let originalBytes = model.measuredDetailBytes
        XCTAssertGreaterThan(originalBytes, 0)

        try FileManager.default.moveItem(at: old, to: target.appendingPathComponent("after"))
        let restartedManager = StorageManager(diskCache: DiskCacheManager(directory: cacheRoot), measure: { _, _ in [:] })
        let restarted = StorageViewModel(manager: restartedManager, explorer: explorer)
        restarted.openDiskBrowser(path: target.path)
        try await settle(restarted)
        XCTAssertTrue(restarted.detailItems.isEmpty)
        XCTAssertTrue(restarted.isDetailSnapshotStale)
        XCTAssertFalse(restarted.hasMeasuredEmptyListing)
        XCTAssertTrue(restarted.canMeasureBrowserListing)

        restarted.measureBrowserListing()
        try await settle(restarted)
        XCTAssertEqual(restarted.detailItems.map(\.name), ["after"])
        XCTAssertEqual(restarted.measuredDetailBytes, originalBytes)
        XCTAssertFalse(restarted.isDetailSnapshotStale)
    }

    func testMeasuredEmptyFolderRestoresItsZeroSizeAndTimestamp() async throws {
        let target = try folder("empty")
        let cacheRoot = try folder("cache")
        let explorer = StorageExplorer(home: scratch, roots: [target], excluded: [], volumes: [scratch])
        let manager = StorageManager(diskCache: DiskCacheManager(directory: cacheRoot), measure: { _, _ in [:] })
        let model = StorageViewModel(manager: manager, explorer: explorer)
        model.openDiskBrowser(path: target.path)
        try await settle(model)
        XCTAssertTrue(model.isBrowserAwaitingMeasurement)
        XCTAssertNil(model.detailMeasuredAt)

        model.measureBrowserListing()
        try await settle(model)
        let measuredAt = try XCTUnwrap(model.detailMeasuredAt)
        XCTAssertTrue(model.hasMeasuredEmptyListing)
        XCTAssertEqual(model.measuredDetailBytes, 0)
        XCTAssertFalse(model.isBrowserAwaitingMeasurement)

        let restartedManager = StorageManager(diskCache: DiskCacheManager(directory: cacheRoot), measure: { _, _ in [:] })
        let restarted = StorageViewModel(manager: restartedManager, explorer: explorer)
        restarted.openDiskBrowser(path: target.path)
        try await settle(restarted)
        XCTAssertTrue(restarted.hasMeasuredEmptyListing)
        XCTAssertEqual(restarted.measuredDetailBytes, 0)
        XCTAssertEqual(restarted.detailMeasuredAt, measuredAt)
        XCTAssertFalse(restarted.isBrowserAwaitingMeasurement)
        XCTAssertTrue(restarted.isDetailSnapshotStale)
    }

    func testRecreatedDirectoryDoesNotRestoreItsOldMeasurement() async throws {
        let target = try folder("target")
        let unchanged = try folder("unchanged")
        let cacheRoot = try folder("cache")
        let cache = DiskCacheManager(directory: cacheRoot)
        let explorer = StorageExplorer(home: scratch, roots: [target], excluded: [], volumes: [scratch])
        let manager = StorageManager(diskCache: cache, measure: { _, _ in [:] })
        let model = StorageViewModel(manager: manager, explorer: explorer)
        model.openDiskBrowser(path: target.path)
        try await settle(model)
        model.measureBrowserListing()
        try await settle(model)
        let originalDate = try XCTUnwrap(model.detailMeasuredAt)
        let key = "disk:\(target.path)"
        let (saved, generation) = await cache.browserSnapshot(for: key)
        let original = try XCTUnwrap(saved)
        XCTAssertNotNil(original.listing.directoryIdentity)

        let legacy = StorageBrowserSnapshot(listing: .init(items: []), measured: [], date: originalDate)
        let accepted = await cache.saveBrowserSnapshot(legacy, for: "disk:\(unchanged.path)", ifGeneration: generation)
        XCTAssertTrue(accepted)

        try FileManager.default.removeItem(at: target)
        _ = try folder("target")
        try Data(repeating: 65, count: 8192).write(to: target.appendingPathComponent("new"))
        XCTAssertFalse(original.matchesDirectory(at: target.path))
        XCTAssertFalse(legacy.matchesDirectory(at: target.path))

        let restartedManager = StorageManager(diskCache: DiskCacheManager(directory: cacheRoot), measure: { _, _ in [:] })
        let restarted = StorageViewModel(manager: restartedManager, explorer: explorer)
        restarted.openDiskBrowser(path: target.path)
        try await settle(restarted)
        XCTAssertEqual(restarted.detailItems.map(\.name), ["new"])
        XCTAssertFalse(restarted.hasMeasuredEmptyListing)
        XCTAssertFalse(restarted.isDetailSnapshotStale)
        XCTAssertGreaterThan(restarted.measuredDetailBytes, 0)

        restarted.openDiskBrowser(path: unchanged.path)
        try await settle(restarted)
        XCTAssertTrue(restarted.hasMeasuredEmptyListing)
        XCTAssertEqual(restarted.detailMeasuredAt, originalDate)
        XCTAssertTrue(restarted.isDetailSnapshotStale)
    }

    private func settle(_ model: StorageViewModel) async throws {
        for _ in 0..<600 where model.isLoadingDetail || model.isSizingDetail {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(model.isLoadingDetail)
        XCTAssertFalse(model.isSizingDetail)
    }
}
