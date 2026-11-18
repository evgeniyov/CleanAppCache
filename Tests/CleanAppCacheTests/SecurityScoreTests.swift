import XCTest
@testable import CleanAppCacheLib

@MainActor
final class SecurityScoreTests: XCTestCase {

    private func check(_ id: String, _ status: SecurityCheck.Status) -> SecurityCheck {
        SecurityCheck(id: id, icon: "lock", titleKey: "t", detailKey: "d",
                      fixHintKey: nil, status: status, settingsURL: nil)
    }

    /// 100 − 16 per critical − 6 per warning, floored at 0. Unknowns cost
    /// nothing and — unlike a pass ratio would — do not inflate the rest.
    func testScoreFormula() {
        let cases: [(fails: Int, warns: Int, unknowns: Int, passes: Int, score: Int)] = [
            (0, 0, 0, 8, 100),
            (1, 0, 0, 7, 84),
            (0, 1, 0, 7, 94),
            (2, 3, 0, 3, 50),
            (0, 0, 8, 0, 100),   // eight unknowns are free
            (2, 3, 5, 0, 50),    // …and do not dilute the penalties
            (6, 1, 0, 0, 0),     // 100 − 96 − 6 → clamped
            (7, 0, 0, 0, 0),
        ]
        for c in cases {
            let vm = SecurityViewModel()
            vm.checks = (0..<c.fails).map { check("f\($0)", .fail) }
                + (0..<c.warns).map { check("w\($0)", .warn) }
                + (0..<c.unknowns).map { check("u\($0)", .unknown) }
                + (0..<c.passes).map { check("p\($0)", .pass) }
            XCTAssertEqual(vm.score, c.score, "\(c)")
            XCTAssertEqual(vm.failCount, c.fails)
            XCTAssertEqual(vm.warnCount, c.warns)
            XCTAssertEqual(vm.passCount, c.passes)
        }
    }
}
