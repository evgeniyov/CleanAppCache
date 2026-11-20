import XCTest
@testable import CleanAppCacheLib

@MainActor
final class SystemDataViewModelTests: XCTestCase {
    private let snapshot = TMSnapshot(id: "fixture", dateToken: "2026-10-01-120000", date: nil)

    @MainActor
    private final class ScanProbe {
        var pending: CheckedContinuation<SystemDataManager.ScanOutcome, Never>?

        func scan() async -> SystemDataManager.ScanOutcome {
            await withCheckedContinuation { pending = $0 }
        }

        func finish(snapshots: [TMSnapshot]) {
            pending?.resume(returning: .init(components: [], snapshots: snapshots))
            pending = nil
        }
    }

    func testScanAndSingleDeletionCannotOverlap() async throws {
        let probe = ScanProbe()
        let dateToken = snapshot.dateToken
        let manager = SystemDataManager(runner: { _, args in
            XCTAssertEqual(args, ["deletelocalsnapshots", dateToken])
            return .init(stdout: "", stderr: "", status: 0)
        })
        let vm = SystemDataViewModel(manager: manager, scan: { await probe.scan() })
        vm.snapshots = [snapshot]

        vm.scan()
        try await waitUntil { probe.pending != nil }
        XCTAssertFalse(vm.deleteSnapshot(snapshot))
        vm.thinAllSnapshots()
        XCTAssertFalse(vm.isDeletingSnapshot)

        probe.finish(snapshots: [snapshot])
        try await waitUntil { !vm.isBusy }
        XCTAssertTrue(vm.deleteSnapshot(snapshot))
        vm.scan()
        XCTAssertFalse(vm.isScanning)
        try await waitUntil { !vm.isBusy }
        XCTAssertTrue(vm.snapshots.isEmpty)
        XCTAssertFalse(vm.deleteSnapshot(snapshot))
    }

    func testThinKeepsEditsDisabledUntilItsRefreshFinishes() async throws {
        let probe = ScanProbe()
        let manager = SystemDataManager(runner: { _, args in
            XCTAssertEqual(args.first, "thinlocalsnapshots")
            return .init(stdout: "", stderr: "", status: 0)
        })
        let vm = SystemDataViewModel(manager: manager, scan: { await probe.scan() })
        vm.snapshots = [snapshot]

        vm.thinAllSnapshots()
        try await waitUntil { probe.pending != nil }
        XCTAssertTrue(vm.isBusy)
        XCTAssertFalse(vm.deleteSnapshot(snapshot))
        probe.finish(snapshots: [])
        try await waitUntil { !vm.isBusy }
        XCTAssertTrue(vm.snapshots.isEmpty)
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
