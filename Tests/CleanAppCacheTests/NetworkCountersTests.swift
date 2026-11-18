import XCTest
@testable import CleanAppCacheLib

final class NetworkCountersTests: XCTestCase {
    private typealias Counters = SystemMonitor.NetworkCounters
    private let wifi = Counters.Interface(name: "en0", index: 1)
    private let ethernet = Counters.Interface(name: "en7", index: 8)

    func testFirstReadingPrimesAndQuietReadingsRemainZero() {
        var counters = Counters()
        let reading = [wifi: Counters.Bytes(received: 100, sent: 200),
                       ethernet: Counters.Bytes(received: 300, sent: 400)]
        XCTAssertNil(counters.update(reading))
        XCTAssertEqual(counters.update(reading), Counters.Delta(received: 0, sent: 0))
        XCTAssertEqual(counters.update(reading), Counters.Delta(received: 0, sent: 0))
    }

    func testStableInterfacesSumTheirRealTraffic() {
        var counters = Counters()
        _ = counters.update([wifi: .init(received: 100, sent: 200),
                             ethernet: .init(received: 300, sent: 400)])
        XCTAssertEqual(counters.update([wifi: .init(received: 110, sent: 205),
                                        ethernet: .init(received: 320, sent: 430)]),
                       Counters.Delta(received: 30, sent: 35))
    }

    func testUnpluggedInterfaceCannotInventWrappedTraffic() {
        var counters = Counters()
        _ = counters.update([wifi: .init(received: 100, sent: 200),
                             ethernet: .init(received: 1_000_000, sent: 2_000_000)])
        XCTAssertEqual(counters.update([wifi: .init(received: 110, sent: 205)]),
                       Counters.Delta(received: 10, sent: 5))
    }

    func testNewInterfacePrimesWithoutAddingItsLifetimeTraffic() {
        var counters = Counters()
        _ = counters.update([wifi: .init(received: 100, sent: 200)])
        XCTAssertEqual(counters.update([wifi: .init(received: 110, sent: 205),
                                        ethernet: .init(received: 1_000_000, sent: 2_000_000)]),
                       Counters.Delta(received: 10, sent: 5))
        XCTAssertEqual(counters.update([wifi: .init(received: 110, sent: 205),
                                        ethernet: .init(received: 1_000_025, sent: 2_000_050)]),
                       Counters.Delta(received: 25, sent: 50))
    }

    func testAllLinksCanDisappearAndReturnWithoutReusingOldBaselines() {
        var counters = Counters()
        _ = counters.update([wifi: .init(received: 100, sent: 200)])
        XCTAssertEqual(counters.update([:]), Counters.Delta(received: 0, sent: 0))
        XCTAssertEqual(counters.update([:]), Counters.Delta(received: 0, sent: 0))
        XCTAssertEqual(counters.update([wifi: .init(received: 10, sent: 20)]),
                       Counters.Delta(received: 0, sent: 0))
        XCTAssertEqual(counters.update([wifi: .init(received: 15, sent: 30)]),
                       Counters.Delta(received: 5, sent: 10))
    }

    func testReusedInterfaceNameWithNewIndexGetsANewBaseline() {
        var counters = Counters()
        _ = counters.update([ethernet: .init(received: 1_000_000, sent: 2_000_000)])
        let replacement = Counters.Interface(name: ethernet.name, index: 9)
        XCTAssertEqual(counters.update([replacement: .init(received: 100, sent: 200)]),
                       Counters.Delta(received: 0, sent: 0))
        XCTAssertEqual(counters.update([replacement: .init(received: 110, sent: 220)]),
                       Counters.Delta(received: 10, sent: 20))
    }

    func testCountersWrapIndependentlyWithoutLosingOtherLinkTraffic() {
        var counters = Counters()
        _ = counters.update([wifi: .init(received: UInt32.max - 5, sent: 200),
                             ethernet: .init(received: 300, sent: UInt32.max - 10)])
        XCTAssertEqual(counters.update([wifi: .init(received: 4, sent: 220),
                                        ethernet: .init(received: 330, sent: 9)]),
                       Counters.Delta(received: 40, sent: 40))
    }

    func testAggregateTrafficCanExceedOne32BitCounter() {
        var counters = Counters()
        _ = counters.update([wifi: .init(received: 0, sent: 0),
                             ethernet: .init(received: 0, sent: 0)])
        XCTAssertEqual(counters.update([wifi: .init(received: 3_000_000_000, sent: 3_000_000_000),
                                        ethernet: .init(received: 3_000_000_000, sent: 3_000_000_000)]),
                       Counters.Delta(received: 6_000_000_000, sent: 6_000_000_000))
    }

    func testUnreadableIntervalResetsInsteadOfCompressingOldTrafficIntoNextTick() {
        var counters = Counters()
        _ = counters.update([wifi: .init(received: 100, sent: 200)])
        counters.reset()
        XCTAssertNil(counters.update([wifi: .init(received: 1_000, sent: 2_000)]))
        XCTAssertEqual(counters.update([wifi: .init(received: 1_010, sent: 2_020)]),
                       Counters.Delta(received: 10, sent: 20))
    }
}
