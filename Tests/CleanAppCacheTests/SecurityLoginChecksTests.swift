import XCTest
@testable import CleanAppCacheLib

final class SecurityLoginChecksTests: XCTestCase {
    private func plist(_ values: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }

    func testFailedCommandAndMalformedDomainRemainUnknown() throws {
        let wrongRoot = try PropertyListSerialization.data(fromPropertyList: ["not", "a", "dictionary"], format: .xml, options: 0)
        for data in [nil, Data(), Data("permission denied".utf8), wrongRoot] {
            let checks = SecurityAuditManager.loginChecks(propertyList: data)
            XCTAssertEqual(checks.automaticLogin.status, .unknown)
            XCTAssertEqual(checks.automaticLogin.detailKey, "sec.autologin.unknown")
            XCTAssertNil(checks.automaticLogin.fixHintKey)
            XCTAssertEqual(checks.guest.status, .unknown)
            XCTAssertEqual(checks.guest.detailKey, "sec.guest.unknown")
            XCTAssertNil(checks.guest.fixHintKey)
        }
    }

    func testAbsentKeysInReadableDomainEstablishDisabledSettings() throws {
        let checks = SecurityAuditManager.loginChecks(propertyList: try plist([:]))
        XCTAssertEqual(checks.automaticLogin.status, .pass)
        XCTAssertEqual(checks.automaticLogin.detailKey, "sec.autologin.off")
        XCTAssertEqual(checks.guest.status, .pass)
        XCTAssertEqual(checks.guest.detailKey, "sec.guest.off")
    }

    func testExplicitEnabledAndDisabledSettings() throws {
        let enabled = SecurityAuditManager.loginChecks(propertyList: try plist(["autoLoginUser": "fixture-user", "GuestEnabled": true]))
        XCTAssertEqual(enabled.automaticLogin.status, .fail)
        XCTAssertEqual(enabled.automaticLogin.detailKey, "sec.autologin.on")
        XCTAssertEqual(enabled.automaticLogin.fixHintKey, "sec.autologin.fix")
        XCTAssertEqual(enabled.guest.status, .warn)
        XCTAssertEqual(enabled.guest.detailKey, "sec.guest.on")
        XCTAssertEqual(enabled.guest.fixHintKey, "sec.guest.fix")

        let disabled = SecurityAuditManager.loginChecks(propertyList: try plist(["autoLoginUser": "", "GuestEnabled": false]))
        XCTAssertEqual(disabled.automaticLogin.status, .pass)
        XCTAssertEqual(disabled.guest.status, .pass)
    }

    func testLegacyIntegerGuestValuesRemainRecognized() throws {
        for value in [0, 1] {
            let checks = SecurityAuditManager.loginChecks(propertyList: try plist(["GuestEnabled": value]))
            XCTAssertEqual(checks.guest.status, value == 0 ? .pass : .warn)
        }
    }

    func testUnexpectedTypesDoNotClaimSettingsAreOff() throws {
        let invalidValues: [Any] = [2, -1, "1", ["enabled": true], [true]]
        for value in invalidValues {
            let checks = SecurityAuditManager.loginChecks(propertyList: try plist(["autoLoginUser": value, "GuestEnabled": value]))
            XCTAssertEqual(checks.automaticLogin.status, value is String ? .fail : .unknown)
            XCTAssertEqual(checks.guest.status, .unknown)
            XCTAssertEqual(checks.guest.detailKey, "sec.guest.unknown")
        }
    }
}
