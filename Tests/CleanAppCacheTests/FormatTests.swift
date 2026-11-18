import XCTest
@testable import CleanAppCacheLib

/// Number formatting is one rule set for every screen, so it gets one table. The context is
/// pinned explicitly: `Fmt` otherwise follows `Locale.current`, which is en_US
/// on CI and whatever the developer runs at home.
final class FormatTests: XCTestCase {

    private static let ru: [String: String] = [
        "unit.b": "Б", "unit.kb": "КБ", "unit.mb": "МБ", "unit.gb": "ГБ",
        "unit.tb": "ТБ", "unit.perSec": "%@/с"
    ]
    private static let en: [String: String] = [
        "unit.b": "B", "unit.kb": "KB", "unit.mb": "MB", "unit.gb": "GB",
        "unit.tb": "TB", "unit.perSec": "%@/s"
    ]
    private func useRussian() { Fmt.setContext(locale: Locale(identifier: "ru"), units: Self.ru) }
    private func useEnglish() { Fmt.setContext(locale: Locale(identifier: "en"), units: Self.en) }

    override func tearDown() {
        // Fresh-process state, so AppManagerTests/ScannerTests see what they saw before.
        Fmt.setContext(locale: .current, units: [:])
        super.tearDown()
    }

    // MARK: Volume ladder

    func testSizeLadderFollowsSection10_2() {
        useRussian()
        let nnbsp = "\u{202F}"
        let cases: [(UInt64, String)] = [
            (0,                     "—"),
            (1,                     "1 Б"),
            (999,                   "999 Б"),
            (1_000,                 "1,00 КБ"),
            (1_800,                 "1,80 КБ"),          // keeps the trailing zero: "1,80", not "1,8"
            (9_990,                 "9,99 КБ"),
            (10_000,                "10,0 КБ"),
            (999_949,               "999,9 КБ"),
            (1_000_000,             "1,00 МБ"),
            (104_857_600,           "104,9 МБ"),         // 100 MiB through a decimal formatter
            (1_000_000_000,         "1,00 ГБ"),
            (12_400_000_000,        "12,4 ГБ"),
            (57_910_000_000,        "57,9 ГБ"),
            (245_100_000_000,       "245,1 ГБ"),
            (1_000_000_000_000,     "1,00 ТБ"),
            (1_234_000_000_000_000, "1\(nnbsp)234,0 ТБ"),
        ]
        for (bytes, expected) in cases {
            XCTAssertEqual(Fmt.bytes(bytes), expected, "\(bytes) bytes")
        }
        XCTAssertNil(Fmt.size(0).unit, "— carries no unit")
        XCTAssertEqual(Fmt.size(1_800).number, "1,80")
        XCTAssertEqual(Fmt.size(1_800).unit, "КБ")
    }

    func testSignedAndZeroInputs() {
        useRussian()
        XCTAssertEqual(Fmt.bytes(Int64(-5)), "—")
        XCTAssertEqual(Fmt.bytes(Int64(1_800)), "1,80 КБ")
        XCTAssertEqual(Fmt.delta(0), "—")
        XCTAssertEqual(Fmt.delta(7_330_000_000), "+7,33")
        XCTAssertEqual(Fmt.delta(250_000_000), "+250,0")
    }

    func testGroupingSeparatorPerLocale() {
        useRussian()
        XCTAssertEqual(Fmt.count(8_412), "8\u{202F}412")
        XCTAssertEqual(Fmt.percent(22.44), "22,4%")
        useEnglish()
        XCTAssertEqual(Fmt.count(8_412), "8,412")
        XCTAssertEqual(Fmt.percent(22.44), "22.4%")
        XCTAssertEqual(Fmt.bytes(UInt64(12_400_000_000)), "12.4 GB")
    }

    // MARK: Pairs

    func testBytesPairScalesBothSidesToTheLargerUnit() {
        useRussian()
        XCTAssertEqual(Fmt.bytesPair(187_200_000_000, 245_100_000_000), "187,2 / 245,1 ГБ")
        // Alone the left side would be MB; in a ratio it borrows the right side's unit.
        XCTAssertEqual(Fmt.bytesPair(500_000_000, 2_000_000_000), "0,50 / 2,00 ГБ")
        // A zero numerator is still a figure: the ratio is the measurement, not the zero.
        XCTAssertEqual(Fmt.bytesPair(0, 2_000_000_000), "0,00 / 2,00 ГБ")
        XCTAssertEqual(Fmt.bytesPair(1_500, 9_000), "1,50 / 9,00 КБ")
        XCTAssertEqual(Fmt.bytesPair(1, 0), "—")
    }

    // MARK: Speed

    func testSpeedLadderAndIdle() {
        useRussian()
        XCTAssertEqual(Fmt.speedString(0), "—")
        XCTAssertEqual(Fmt.speedString(0.9), "—")          // below 1 B/s is idle
        XCTAssertEqual(Fmt.speedString(1), "1,00 Б/с")
        XCTAssertEqual(Fmt.speedString(999.6), "999,6 Б/с")
        XCTAssertEqual(Fmt.speed(1_500).number, "1,50")
        XCTAssertEqual(Fmt.speed(1_500).unit, "КБ/с")
        XCTAssertEqual(Fmt.speedString(2_500_000), "2,50 МБ/с")
        XCTAssertEqual(Fmt.speedString(125_000_000), "125,0 МБ/с")
    }

    // MARK: Unit seeding

    /// A background scanner can format before `Localizer` has published a
    /// context. The unit table must seed itself from the bundle rather than
    /// print a bare figure.
    func testUnitsSeedFromBundleWhenContextIsEmpty() {
        Fmt.setContext(locale: Locale(identifier: "en"), units: [:])
        let v = Fmt.size(1_800)
        XCTAssertEqual(v.number, "1.80")
        XCTAssertFalse(v.unit?.isEmpty ?? true, "unit table did not seed: \(v.joined)")
        let speed = Fmt.speedString(1_500)
        XCTAssertTrue(speed.hasSuffix("/s") || speed.hasSuffix("/с"),
                      "per-second suffix did not seed: \(speed)")
    }
}
