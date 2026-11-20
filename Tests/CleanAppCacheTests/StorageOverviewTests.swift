import XCTest
@testable import CleanAppCacheLib

@MainActor
final class StorageOverviewTests: XCTestCase {
    @MainActor
    private final class Probe {
        var pending: CheckedContinuation<StorageViewModel.Overview?, Never>?

        func measure() async -> StorageViewModel.Overview? {
            await withCheckedContinuation { pending = $0 }
        }

        func finish(used: UInt64) {
            let info = StorageInfo(totalBytes: 10_000, freeBytes: 10_000 - used, usedBytes: used)
            let category = StorageBreakdown(name: "Fixture", icon: "folder", bytes: used,
                                            path: "/fixture", percentOfTotal: info.usedPercent)
            pending?.resume(returning: (info, [category]))
            pending = nil
        }
    }

    func testInvalidationRefreshesOnAppearanceAndRejectsAnOverlappingMeasurement() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("storage-overview-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let manager = StorageManager(diskCache: DiskCacheManager(directory: scratch), measure: { _, _ in [:] })
        let probe = Probe()
        let vm = StorageViewModel(manager: manager, explorer: .live, measureOverview: { await probe.measure() })

        vm.loadStorageInfoIfNeeded()
        try await waitUntil { probe.pending != nil }
        probe.finish(used: 5_000)
        try await waitUntil { !vm.isLoading }
        XCTAssertEqual(vm.storageInfo?.usedBytes, 5_000)
        vm.loadStorageInfoIfNeeded()
        XCTAssertFalse(vm.isLoading)

        await manager.invalidate(deleted: [scratch.appendingPathComponent("first")])
        vm.loadStorageInfoIfNeeded()
        try await waitUntil { probe.pending != nil }
        await manager.invalidate(deleted: [scratch.appendingPathComponent("second")])
        probe.finish(used: 4_000)
        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(vm.storageInfo?.usedBytes, 5_000)
        XCTAssertEqual(vm.breakdown.first?.bytes, 5_000)

        vm.loadStorageInfoIfNeeded()
        try await waitUntil { probe.pending != nil }
        XCTAssertEqual(vm.storageInfo?.usedBytes, 5_000)
        probe.finish(used: 3_000)
        try await waitUntil { !vm.isLoading }
        XCTAssertEqual(vm.storageInfo?.usedBytes, 3_000)
        XCTAssertEqual(vm.breakdown.first?.bytes, 3_000)
    }

    private enum FixtureError: Error { case timeout }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw FixtureError.timeout
    }
}
