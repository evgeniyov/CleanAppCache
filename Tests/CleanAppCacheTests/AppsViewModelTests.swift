import XCTest
import Combine
@testable import CleanAppCacheLib

final class AppsViewModelTests: XCTestCase {
    @MainActor
    func testCancelledScanCannotPublishProgressIntoItsReplacement() async {
        let starts = AsyncStream<(AppsViewModel.ScanProgress, CheckedContinuation<[InstalledApp], Never>)>.makeStream()
        let vm = AppsViewModel { progress in
            await withCheckedContinuation { continuation in
                starts.continuation.yield((progress, continuation))
            }
        }
        var scans = starts.stream.makeAsyncIterator()
        vm.loadApps()
        guard let (abandoned, finishAbandoned) = await scans.next() else { return XCTFail("First scan did not start") }
        defer { finishAbandoned.resume(returning: []) }
        vm.cancelScan()
        vm.loadApps()
        guard let (current, finishCurrent) = await scans.next() else { return XCTFail("Replacement scan did not start") }
        defer { finishCurrent.resume(returning: []) }

        let observed = AsyncStream<Double>.makeStream()
        let subscription = vm.$loadProgress.sink { observed.continuation.yield($0) }
        defer { subscription.cancel() }
        var progress = observed.stream.makeAsyncIterator()
        abandoned(9, 10, "")
        current(1, 4, "")
        let initial = await progress.next()
        let update = await progress.next()
        XCTAssertEqual(initial, 0)
        XCTAssertEqual(update, 0.25)
        XCTAssertEqual(vm.loadProgress, 0.25)
    }
}
