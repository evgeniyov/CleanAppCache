import XCTest
import Combine
@testable import CleanAppCacheLib

private actor StorageProbeTrace {
    var calls = 0
    func measure(_ urls: [URL], _ timeout: TimeInterval) async -> [String: UInt64] {
        calls += 1
        return await DirectorySizeProbe.measure(urls, timeout: timeout)
    }
    func count() -> Int { calls }
}

@MainActor
final class StoragePerformanceTests: XCTestCase {
    private var scratch: URL!
    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("storage-performance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: scratch) }
    private func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
    private func collect(_ manager: StorageManager, _ root: URL) async -> (values: [String: UInt64], first: Double, total: Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        var values: [String: UInt64] = [:]
        var first: Double?
        for await item in manager.streamDirectory(path: root.path) {
            if first == nil { first = milliseconds(since: start) }
            XCTAssertTrue(item.sizeKnown, item.name)
            values[item.name] = item.size
        }
        return (values, first ?? 0, milliseconds(since: start))
    }
    func testBenchmarkColdAndWarmSyntheticAndInstalledBundle() async throws {
        let fixture: URL
        if let path = ProcessInfo.processInfo.environment["CAC_STORAGE_BENCHMARK_ROOT"] {
            // The benchmark writes 1,800 files into this folder, so it accepts
            // only a folder named for the purpose, never an arbitrary path.
            guard URL(fileURLWithPath: path).lastPathComponent == "benchmark-fixture" else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            fixture = URL(fileURLWithPath: path)
        } else { fixture = scratch.appendingPathComponent("fixture") }
        let fm = FileManager.default
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        for index in 0..<1200 {
            let file = fixture.appendingPathComponent(String(format: "file-%04d.bin", index))
            if !fm.fileExists(atPath: file.path) { try Data(repeating: 65, count: 1024).write(to: file) }
        }
        for index in 0..<12 {
            let directory = fixture.appendingPathComponent("folder-\(index)")
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            for child in 0..<50 {
                let file = directory.appendingPathComponent("sample-\(child)")
                if !fm.fileExists(atPath: file.path) { try Data(repeating: 66, count: 1024).write(to: file) }
            }
        }
        let trace = StorageProbeTrace()
        let manager = StorageManager(diskCache: DiskCacheManager(directory: scratch.appendingPathComponent("cache")),
                                     measure: { await trace.measure($0, $1) })
        let cold = await collect(manager, fixture)
        let coldCalls = await trace.count()
        let warm = await collect(manager, fixture)
        let warmCalls = await trace.count() - coldCalls
        XCTAssertEqual(cold.values, warm.values)
        XCTAssertEqual(cold.values.count, 1212)
        print("STORAGE_BENCH synthetic entries=\(cold.values.count) sum=\(cold.values.values.reduce(0,+)) coldFirstMS=\(cold.first) coldTotalMS=\(cold.total) coldProbes=\(coldCalls) warmFirstMS=\(warm.first) warmTotalMS=\(warm.total) warmProbes=\(warmCalls)")
        if ProcessInfo.processInfo.environment["CAC_STORAGE_BENCHMARK_ROOT"] != nil {
            let installed = URL(fileURLWithPath: "/Applications/CleanAppCache.app/Contents")
            let appCold = await collect(manager, installed)
            let appWarm = await collect(manager, installed)
            XCTAssertEqual(appCold.values, appWarm.values)
            print("STORAGE_BENCH installedBundleContents entries=\(appCold.values.count) sum=\(appCold.values.values.reduce(0,+)) coldFirstMS=\(appCold.first) coldTotalMS=\(appCold.total) warmFirstMS=\(appWarm.first) warmTotalMS=\(appWarm.total)")
        }
    }
    func testReadySmallFileAppearsBeforeSlowSiblingAndKeepsPendingRows() async throws {
        let file = scratch.appendingPathComponent(".localized")
        try Data().write(to: file)
        for name in ["fast", "slow"] {
            try FileManager.default.createDirectory(at: scratch.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        // Cache state lives outside the directory being listed.
        let cacheRoot = scratch.appendingPathExtension("cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let manager = StorageManager(diskCache: DiskCacheManager(directory: cacheRoot), measure: { _, _ in [:] })
        let explorer = StorageExplorer(home: scratch, roots: [scratch], excluded: [], volumes: [scratch], readDirectory: { url in
            if url.lastPathComponent == "slow" { Thread.sleep(forTimeInterval: 0.35) }
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        })
        let model = StorageViewModel(manager: manager, explorer: explorer)
        let start = DispatchTime.now().uptimeNanoseconds
        var firstVisible: Double?
        let observation = model.$detailItems.sink { items in
            if firstVisible == nil, items.contains(where: { $0.name == ".localized" && $0.sizeKnown }) {
                firstVisible = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }
        }
        model.loadDetail(for: StorageBreakdown(name: "fixture", icon: "folder", bytes: 0, path: scratch.path, percentOfTotal: 0))
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNotNil(firstVisible, "an already measurable file must not wait for a slow sibling")
        XCTAssertEqual(model.detailItems.count, 3, "pending rows must remain visible")
        XCTAssertTrue(model.detailItems.contains { $0.name == "fast" && $0.sizeKnown })
        model.selectedDetailItem = model.detailItems.first { $0.name == "slow" }
        for _ in 0..<400 where model.isLoadingDetail || model.isSizingDetail { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(model.isSizingDetail)
        XCTAssertEqual(model.detailItems.count, 3)
        XCTAssertTrue(model.selectedDetailItem?.sizeKnown == true)
        print("STORAGE_BENCH controlledSlowSiblingMS=350 firstVisibleMS=\(firstVisible ?? -1) totalMS=\(milliseconds(since: start))")
        withExtendedLifetime(observation) {}
    }
    func testOrdinaryFilesDoNotStartRecursiveSizeProcesses() async throws {
        for index in 0..<60 { try Data(repeating: 65, count: 8192).write(to: scratch.appendingPathComponent("file-\(index)")) }
        let trace = StorageProbeTrace()
        let cacheRoot = scratch.appendingPathExtension("cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let manager = StorageManager(diskCache: DiskCacheManager(directory: cacheRoot), measure: { await trace.measure($0, $1) })
        let values = await collect(manager, scratch)
        let calls = await trace.count()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(values.values.count, 60)
        for size in values.values.values { XCTAssertEqual(size, 8192) }
    }
    func testCancellationAndTimeoutStopOnlyTheOwnedProbePromptly() async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        let work = Task { await DirectorySizeProbe.capture(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 10) }
        try await Task.sleep(nanoseconds: 40_000_000)
        work.cancel()
        let cancelled = await work.value
        XCTAssertNil(cancelled)
        XCTAssertLessThan(milliseconds(since: start), 500)
        let timeoutStart = DispatchTime.now().uptimeNanoseconds
        let timedOut = await DirectorySizeProbe.capture(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.04)
        XCTAssertNil(timedOut)
        XCTAssertLessThan(milliseconds(since: timeoutStart), 500)
    }
    func testProbeDrainsLargeOutputAndRejectsFailureAndMissingPaths() async {
        let bytes = await DirectorySizeProbe.capture(executable: URL(fileURLWithPath: "/usr/bin/head"), arguments: ["-c", "131072", "/dev/zero"], timeout: 2)
        XCTAssertEqual(bytes?.count, 131072)
        let failed = await DirectorySizeProbe.capture(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], timeout: 2)
        XCTAssertNil(failed)
        let missing = await DirectorySizeProbe.measure([scratch.appendingPathComponent("missing")], timeout: 2)
        XCTAssertTrue(missing.isEmpty)
    }
    func testLeafAllocationMatchesDUForSparseEmptyLinkedAndUnusualNames() throws {
        let fm = FileManager.default
        let ordinary = scratch.appendingPathComponent("line\nbreak\tfile")
        try Data(repeating: 65, count: 8192).write(to: ordinary)
        let empty = scratch.appendingPathComponent("empty");try Data().write(to: empty)
        let sparse = scratch.appendingPathComponent("sparse")
        XCTAssertTrue(fm.createFile(atPath: sparse.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.seek(toOffset: 8_000_000);try handle.write(contentsOf: Data([65]));try handle.close()
        let symlink = scratch.appendingPathComponent("symlink");try fm.createSymbolicLink(at: symlink, withDestinationURL: ordinary)
        let hardlink = scratch.appendingPathComponent("hardlink");try fm.linkItem(at: ordinary, to: hardlink)
        for file in [ordinary,empty,sparse,symlink,hardlink] {
            let du = Scanner.shared.calculateSizes(at: [file])
            XCTAssertEqual(StorageManager.allocatedLeafSize(at: file), du[file.path], file.lastPathComponent)
        }
        XCTAssertNil(StorageManager.allocatedLeafSize(at: scratch))
    }
    func testStreamReusesIdentitiesAndCachesCompletedEmptyDirectories() async throws {
        let empty = scratch.appendingPathComponent("empty");try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let trace = StorageProbeTrace();let cacheRoot = scratch.appendingPathExtension("cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let manager = StorageManager(diskCache: DiskCacheManager(directory: cacheRoot), measure: { await trace.measure($0, $1) })
        let listing = await manager.getDirectoryListing(for: scratch.path)
        var seen: [StorageItemDetail] = []
        for await item in manager.streamDirectory(path: scratch.path, listing: listing) { seen.append(item) }
        XCTAssertEqual(seen.map(\.id), listing.map(\.id))
        XCTAssertEqual(seen.first?.size, 0)
        XCTAssertTrue(seen.first?.sizeKnown == true)
        let before = await trace.count()
        _ = await collect(manager, scratch)
        let after = await trace.count()
        XCTAssertEqual(before, after, "a measured empty directory is a valid cache hit")
    }

    func testWideDirectoryPublishesReadyRowsWhileSlowWorkRemainsAndRescanWins() async throws {
        for index in 0..<25 {
            try FileManager.default.createDirectory(at: scratch.appendingPathComponent(String(format: "dir-%02d", index)), withIntermediateDirectories: true)
        }
        let cacheRoot = scratch.appendingPathExtension("cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let manager = StorageManager(diskCache: DiskCacheManager(directory: cacheRoot), measure: { _, _ in [:] })
        let releaseSlowRead = DispatchSemaphore(value: 0)
        let explorer = StorageExplorer(home: scratch, roots: [scratch], excluded: [], volumes: [scratch], readDirectory: { url in
            if url.lastPathComponent == "dir-02" {
                _ = releaseSlowRead.wait(timeout: .now() + 5)
            }
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        })
        let model = StorageViewModel(manager: manager, explorer: explorer)
        model.loadDetail(for: StorageBreakdown(name: "old", icon: "folder", bytes: 0, path: scratch.path, percentOfTotal: 0))
        defer { releaseSlowRead.signal() }
        for _ in 0..<300 where model.detailItems.filter(\.sizeKnown).count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.detailItems.count, 25)
        XCTAssertGreaterThanOrEqual(model.detailItems.filter(\.sizeKnown).count, 2)
        XCTAssertFalse(model.detailItems.contains { $0.name == "dir-02" && $0.sizeKnown })
        XCTAssertTrue(model.isSizingDetail)
        let next = scratch.appendingPathComponent("next")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        model.loadDetail(for: StorageBreakdown(name: "new", icon: "folder", bytes: 0, path: next.path, percentOfTotal: 0))
        releaseSlowRead.signal()
        for _ in 0..<300 where model.isLoadingDetail || model.isSizingDetail {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.currentDetailPath, next.path)
        XCTAssertTrue(model.detailItems.isEmpty)
        XCTAssertFalse(model.isSizingDetail)
    }
    func testFailedDirectoryMeasurementsRemainUnknownAndRetryable() async throws {
        let folder = scratch.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cacheRoot = scratch.appendingPathExtension("cache")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let manager = StorageManager(diskCache: DiskCacheManager(directory: cacheRoot), measure: { _,_ in [:] })
        for _ in 0..<2 {
            var rows: [StorageItemDetail] = []
            for await item in manager.streamDirectory(path: scratch.path) { rows.append(item) }
            XCTAssertEqual(rows.count, 1)
            XCTAssertFalse(rows[0].sizeKnown)
        }
    }

}
