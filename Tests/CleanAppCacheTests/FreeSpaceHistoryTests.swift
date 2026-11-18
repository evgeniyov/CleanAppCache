import Foundation
import XCTest
@testable import CleanAppCacheLib

@MainActor
final class FreeSpaceHistoryTests: XCTestCase {
    func testKeepsLatestReadingPerHourAndRestoresHistory() throws {
        let suite = "FreeSpaceHistoryTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = FreeSpaceHistory(defaults: defaults)
        let today = Date(timeIntervalSinceReferenceDate: 3600 * 1000)
        history.record(bytes: 100, at: today.addingTimeInterval(-32 * 86_400))
        history.record(bytes: 200, at: today.addingTimeInterval(-3600))
        history.record(bytes: 300, at: today)
        history.record(bytes: 0, at: today.addingTimeInterval(60))

        let reopened = FreeSpaceHistory(defaults: defaults)
        XCTAssertEqual(reopened.samples.map(\.bytes), [200, 0])
        XCTAssertEqual(reopened.samples.last?.date, today.addingTimeInterval(60))
    }
}
