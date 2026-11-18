import XCTest
@testable import CleanAppCacheLib

final class DiskCountersTests: XCTestCase {
    private typealias Counters = SystemMonitor.DiskCounters
    private typealias Sample = SystemMonitor.DiskSample

    func testConnectedDriveDoesNotAddLifetimeCounters() {
        var counters = Counters()
        XCTAssertEqual(counters.update([1: .init(read: 100, write: 200, ops: 50)], interval: 2), Sample())
        XCTAssertEqual(counters.update([
            1: .init(read: 120, write: 240, ops: 56),
            2: .init(read: 4_000_000, write: 2_000_000, ops: 100_000)
        ], interval: 2), Sample(read: 10, write: 20, ops: 3))
        XCTAssertEqual(counters.update([
            1: .init(read: 140, write: 280, ops: 62),
            2: .init(read: 4_000_030, write: 2_000_050, ops: 100_004)
        ], interval: 2), Sample(read: 25, write: 45, ops: 5))
    }

    func testDisconnectKeepsActivityOnRemainingDrive() {
        var counters = Counters()
        _ = counters.update([
            1: .init(read: 100, write: 200, ops: 50),
            2: .init(read: 4_000_000, write: 2_000_000, ops: 100_000)
        ], interval: 2)
        XCTAssertEqual(counters.update([1: .init(read: 120, write: 240, ops: 56)], interval: 2),
                       Sample(read: 10, write: 20, ops: 3))
    }

    func testResetDriverStartsNewBaselineWithoutDistortingOtherDrive() {
        var counters = Counters()
        _ = counters.update([
            1: .init(read: 100, write: 200, ops: 50),
            2: .init(read: 4_000_000, write: 2_000_000, ops: 100_000)
        ], interval: 2)
        XCTAssertEqual(counters.update([
            1: .init(read: 120, write: 240, ops: 56),
            2: .init(read: 1, write: 2, ops: 3)
        ], interval: 2), Sample(read: 10, write: 20, ops: 3))
    }

    func testWakeAndFailedEnumerationDiscardStaleDeltas() {
        var counters = Counters()
        _ = counters.update([1: .init(read: 100, write: 200, ops: 50)], interval: 2)
        XCTAssertEqual(counters.update([1: .init(read: 300, write: 400, ops: 70)], interval: 2,
                                       resetBaseline: true), Sample())
        XCTAssertEqual(counters.update([1: .init(read: 320, write: 440, ops: 76)], interval: 2),
                       Sample(read: 10, write: 20, ops: 3))
        XCTAssertEqual(counters.update([:], interval: 2), Sample())
        XCTAssertEqual(counters.update([1: .init(read: 800, write: 900, ops: 120)], interval: 2), Sample())
    }
}
