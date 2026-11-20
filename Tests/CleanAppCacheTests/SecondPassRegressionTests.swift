import XCTest
import Combine
@testable import CleanAppCacheLib

private actor ScanHarness: ScannerProtocol {
    var callbacks: [@Sendable (ScanProgress) -> Void] = []
    var pending: [CheckedContinuation<ScanResult, Error>] = []
    func performFullScan(progressHandler: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult {
        callbacks.append(progressHandler)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func cancel() async {}
    func count() -> Int { callbacks.count }
    func emit(_ index: Int, _ path: String) {
        callbacks[index](ScanProgress(currentCategory: .userCache, categoriesDone: 0,
                                     totalCategories: 1, currentPath: path, partialSize: 0))
    }
    func fail() {
        for continuation in pending { continuation.resume(throwing: CocoaError(.fileReadNoPermission)) }
        pending = []
    }
    func finish() {
        let result = ScanResult(items: [], totalSize: 0, duration: 0, categorySizes: [:])
        for continuation in pending { continuation.resume(returning: result) }
        pending = []
    }
}

private actor MoveGate {
    var calls = 0
    var pending: [CheckedContinuation<TrashService.Result, Never>] = []
    func run() async -> TrashService.Result {
        calls += 1
        return await withCheckedContinuation { pending.append($0) }
    }
    func count() -> Int { calls }
    func finish() {
        for continuation in pending { continuation.resume(returning: .init(trashed: [], failed: [], freedBytes: 0)) }
        pending = []
    }
}

@MainActor
final class SecondPassRegressionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("second-pass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ name: String, _ content: String = "synthetic") throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return url
    }
    private func waitUntil(_ predicate: () async -> Bool) async {
        for _ in 0..<200 {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for controlled operation")
    }
    func testLargeFileDeleteCannotReenterOrChangeScope() async throws {
        let gate = MoveGate()
        let vm = LargeFilesViewModel(trash: { _, _ in await gate.run() }, history: CleanupHistory(directory: root))
        let file = LargeFile(url: try write("large"), size: 8192, modified: nil, accessed: nil, isDeletable: true)
        vm.files = [file]; vm.selected = [file.id]
        let first = Task { await vm.deleteSelected() }
        await waitUntil { await gate.count() == 1 }
        let second = Task { await vm.deleteSelected() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        vm.setSearchScope(.entireDisk)
        let count = await gate.count()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(vm.searchScope, .home)
        await gate.finish()
        await first.value; await second.value
        XCTAssertFalse(vm.isDeleting)
    }
    func testPartialUndoUpdatesHistoryAndOnlyRestoredRows() async throws {
        let a = try write("a", String(repeating: "a", count: 8192))
        let b = try write("b", String(repeating: "b", count: 16384))
        let bin = root.appendingPathComponent("synthetic-trash")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let history = CleanupHistory(directory: root.appendingPathComponent("state"))
        let vm = LargeFilesViewModel(trash: { urls, validation in
            TrashService.trash(urls, validation: validation, mover: { source in
                let dest = bin.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.moveItem(at: source, to: dest)
                return dest
            })
        }, history: history)
        vm.files = [a,b].map { LargeFile(url: $0, size: 1, modified: nil, accessed: nil, isDeletable: true) }
        vm.selected = Set(vm.files.map(\.id))
        await vm.deleteSelected()
        let before = history.totalTrashedBytes
        let sizeA = try FileManager.default.allocatedSize(of: bin.appendingPathComponent("a"))
        // Simulate one item no longer being available to Undo, solely in the scratch Trash.
        try FileManager.default.removeItem(at: bin.appendingPathComponent("b"))
        let undo = try XCTUnwrap(ToastCenter.shared.toasts.last(where: { $0.action != nil })?.action)
        undo()
        XCTAssertEqual(history.totalTrashedBytes, before - sizeA)
        XCTAssertEqual(vm.files.map(\.url), [a])
        undo() // a repeated/stale callback must not subtract the restored bytes twice.
        XCTAssertEqual(history.totalTrashedBytes, before - sizeA)

        vm.selected = Set(vm.files.map(\.id))
        await vm.deleteSelected()
        XCTAssertTrue(vm.files.isEmpty)
        XCTAssertTrue(RemovalCheck.isMissing(a))
        XCTAssertEqual(history.totalTrashedBytes, before)
    }
    func testCancelledScanCannotPublishProgressIntoReplacement() async {
        let scanner = ScanHarness()
        let vm = DashboardViewModel(scanner: scanner, loadCache: false)
        vm.startScan()
        await waitUntil { await scanner.count() == 1 }
        vm.cancelScan(); vm.startScan()
        await waitUntil { await scanner.count() == 2 }
        await scanner.emit(1, "new")
        try? await Task.sleep(nanoseconds: 20_000_000)
        await scanner.emit(0, "old")
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(vm.scanProgress?.currentPath, "new")
        await scanner.finish()
        await waitUntil { !vm.isScanning }
        await scanner.emit(1, "late")
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(vm.scanProgress)
    }
    func testScanFailureStopsBusyStateAndAllowsRetry() async {
        let scanner = ScanHarness()
        let vm = DashboardViewModel(scanner: scanner, loadCache: false)
        vm.startScan()
        await waitUntil { await scanner.count() == 1 }
        await scanner.fail()
        await waitUntil { !vm.isScanning }
        XCTAssertNil(vm.scanResult)
        XCTAssertNil(vm.scanProgress)
        vm.startScan()
        await waitUntil { await scanner.count() == 2 }
        await scanner.finish()
        await waitUntil { !vm.isScanning }
        XCTAssertNotNil(vm.scanResult)
    }
    func testDuplicatesUseSelectionCapturedBeforeAwait() async throws {
        for (name, text) in [("a1","a"),("a2","a"),("b1","b"),("b2","b")] {
            _ = try write(name, String(repeating: text, count: 8192))
        }
        let scan = await DuplicateFinder.shared.findDuplicates(in: root, minSize: 1, progress: { _, _ in })
        XCTAssertEqual(scan.groups.count, 2)
        let gate = MoveGate()
        let bin = root.appendingPathComponent("synthetic-trash")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let vm = DuplicatesViewModel(preflight: { file in
            if file.url.lastPathComponent == scan.groups[0].files[0].url.lastPathComponent { _ = await gate.run() }
            return DuplicateFinder.isUnchanged(file)
        }, mover: { source in
            let dest = bin.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: dest)
            return dest
        }, history: CleanupHistory(directory: root.appendingPathComponent("state")))
        vm.groups = scan.groups; vm.result = scan
        let chosen = scan.groups.map { $0.files[1] }
        vm.selectedForDeletion = Set(chosen.map(\.id))
        let work = Task { await vm.deleteSelected() }
        await waitUntil { await gate.count() == 1 }
        vm.selectedForDeletion = [] // a bound UI property changes while validation is suspended.
        await gate.finish(); await work.value
        for file in chosen { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
        for group in scan.groups { XCTAssertTrue(FileManager.default.fileExists(atPath: group.files[0].path)) }
    }
    func testAlreadyGoneLargeFilesLeaveTheListWithoutInventedBytes() async throws {
        let file = LargeFile(url: root.appendingPathComponent("gone"), size: 9999, modified: nil,
                             accessed: nil, isDeletable: true)
        let history = CleanupHistory(directory: root)
        let vm = LargeFilesViewModel(trash: { urls, _ in
            .init(trashed: [], failed: [], alreadyGone: urls, freedBytes: 0)
        }, history: history)
        vm.files = [file]; vm.selected = [file.id]
        await vm.deleteSelected()
        XCTAssertTrue(vm.files.isEmpty)
        XCTAssertTrue(history.records.isEmpty)
    }
    func testMissingDeveloperArtifactIsReportedAsCleanedWithZeroBytes() async {
        let item = DevJunkItem(definitionID: "simulatorCaches", url: root.appendingPathComponent("gone"),
                               size: 9999, safe: true)
        let result = await DevCleanManager.shared.clean(items: [item])
        XCTAssertEqual(result.cleaned, [item.id])
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.freedBytes, 0)
    }
    func testUndoOfRecoverableSubsetRetainsFinderBytesAndPermanentBytes() throws {
        let original = try write("normal")
        let bin = root.appendingPathComponent("synthetic-trash")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let result = TrashService.trash([original], mover: { source in
            let dest = bin.appendingPathComponent("normal")
            try FileManager.default.moveItem(at: source, to: dest)
            return dest
        })
        let history = CleanupHistory(directory: root.appendingPathComponent("state"))
        let record = history.log(.smartCleanup, items: 3, freedBytes: 123, trashedBytes: result.freedBytes + 456)
        XCTAssertEqual(TrashService.restore(result.trashed, recordingUndoOf: record, history: history), 1)
        XCTAssertEqual(history.totalTrashedBytes, 456)
        XCTAssertEqual(history.totalFreedBytes, 123)
        XCTAssertEqual(CleanupHistory(directory: root.appendingPathComponent("state")).records.first?.id, record)
    }
    func testPartialDuplicateUndoDoesNotResurrectMissingRows() async throws {
        for name in ["one", "two", "three"] { _ = try write(name, String(repeating: "x", count: 8192)) }
        let scan = await DuplicateFinder.shared.findDuplicates(in: root, minSize: 1, progress: { _, _ in })
        let group = try XCTUnwrap(scan.groups.first)
        let bin = root.appendingPathComponent("synthetic-trash")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let vm = DuplicatesViewModel(preflight: { DuplicateFinder.isUnchanged($0) }, mover: { source in
            let dest = bin.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: dest)
            return dest
        }, history: CleanupHistory(directory: root.appendingPathComponent("state")))
        vm.groups = scan.groups; vm.result = scan
        vm.selectedForDeletion = Set(group.files.dropFirst().map(\.id))
        await vm.deleteSelected()
        try FileManager.default.removeItem(at: bin.appendingPathComponent(group.files[2].url.lastPathComponent))
        let undo = try XCTUnwrap(ToastCenter.shared.toasts.last(where: { $0.action != nil })?.action)
        undo()
        // Undo refreshes the restored snapshots off the main actor.
        for _ in 0..<100 where vm.isDeleting { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(vm.isDeleting)
        XCTAssertEqual(vm.groups.first?.files.count, 2)
        XCTAssertTrue(vm.groups.flatMap(\.files).allSatisfy { !RemovalCheck.isMissing($0.url) })
    }

}

private final class MonitorHarness: @unchecked Sendable {
    let started = XCTestExpectation(description: "first sample started")
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    func sample() -> (SystemSnapshot, Bool) {
        lock.lock(); calls += 1; let index = calls; lock.unlock()
        if index == 1 { started.fulfill(); _ = release.wait(timeout: .now() + 5) }
        let cpu: Double = index == 1 ? 99 : 42
        return (SystemSnapshot(
            cpuPercent: cpu,
            perCorePercent: [],
            memUsedBytes: 0,
            memTotalBytes: 0,
            memPressure: .normal,
            memPressurePercent: 0,
            memAppBytes: 0,
            memFileCacheBytes: 0,
            memWiredBytes: 0,
            memCompressedBytes: 0,
            swapUsedBytes: 0,
            netDownBytesPerSec: 0,
            netUpBytesPerSec: 0,
            netInterfaceBSDName: nil,
            netInterfaceName: nil,
            netLocalAddress: nil,
            netSessionDownBytes: 0,
            netSessionUpBytes: 0,
            netIdleSeconds: nil,
            diskReadBytesPerSec: 0,
            diskWriteBytesPerSec: 0,
            diskOpsPerSec: 0,
            storageDeviceName: nil,
            ssdEndurance: nil,
            processes: [],
            processListID: 0,
            uptimeSeconds: 0,
            threadCount: nil,
            loadAverage1m: nil,
            displayCount: nil,
            batteryPercent: nil,
            batteryCharging: nil,
            batteryCycleCount: nil,
            batteryHealthPercent: nil,
            batteryCapacityMAh: nil,
            batteryDesignCapacityMAh: nil,
            powerAdapterWatts: nil,
            gpuPercent: nil,
            tempCPU: nil,
            tempGPU: nil,
            tempBattery: nil,
            tempOrigin: TempOrigin(),
            freqECluster: nil,
            freqPCluster: nil,
            freqGPU: nil), false)
    }
}

extension SecondPassRegressionTests {
    func testMonitorDiscardsSampleFromStoppedSession() async {
        let source = MonitorHarness()
        let vm = MonitorViewModel(machineInfo: MachineInfo(model: "fixture", chip: "fixture", totalCores: 1,
                                                          perfCores: 1, effCores: 0, clusterMap: nil),
                                  sample: { source.sample() })
        let fresh = expectation(description: "fresh session sample")
        let subscription = vm.$snapshot.compactMap { $0 }.filter { $0.cpuPercent == 42 }.prefix(1)
            .sink { _ in fresh.fulfill() }
        vm.start()
        await fulfillment(of: [source.started], timeout: 2)
        vm.stop(); vm.start()
        source.release.signal()
        await fulfillment(of: [fresh], timeout: 3)
        XCTAssertEqual(vm.cpuHistory, [42])
        vm.stop()
        withExtendedLifetime(subscription) {}
    }
}
