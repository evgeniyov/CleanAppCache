import XCTest
@testable import CleanAppCacheLib

final class ThermalStatusTests: XCTestCase {
    func testTemperatureWarningBoundaries() {
        XCTAssertEqual(ThermalStatus(cpu: 69.9, gpu: nil, thermalState: .nominal).tone, .success)
        XCTAssertEqual(ThermalStatus(cpu: 70, gpu: nil, thermalState: .nominal).tone, .warning)
        XCTAssertEqual(ThermalStatus(cpu: 89.9, gpu: nil, thermalState: .nominal).tone, .warning)
        XCTAssertEqual(ThermalStatus(cpu: 90, gpu: nil, thermalState: .nominal).tone, .danger)
    }

    func testTemperatureAloneDoesNotClaimThrottling() {
        let normal = ThermalStatus(cpu: 69, gpu: nil, thermalState: .nominal)
        XCTAssertEqual(normal.tone, .success)
        XCTAssertEqual(normal.labelKey, "monitor.thermal.nominal")

        let warm = ThermalStatus(cpu: 85, gpu: nil, thermalState: .nominal)
        XCTAssertEqual(warm.tone, .warning)
        XCTAssertEqual(warm.labelKey, "monitor.thermal.fair")

        let hot = ThermalStatus(cpu: 100, gpu: nil, thermalState: .nominal)
        XCTAssertEqual(hot.tone, .danger)
        XCTAssertEqual(hot.labelKey, "monitor.thermal.hot")
    }

    func testSystemPressureIsNotHiddenByLowerOrMissingSensors() {
        for temperature in [Double?.none, 45, 69] {
            let serious = ThermalStatus(cpu: temperature, gpu: nil, thermalState: .serious)
            XCTAssertEqual(serious.tone, .warning)
            XCTAssertEqual(serious.labelKey, "monitor.thermal.serious")

            let critical = ThermalStatus(cpu: temperature, gpu: nil, thermalState: .critical)
            XCTAssertEqual(critical.tone, .danger)
            XCTAssertEqual(critical.labelKey, "monitor.thermal.critical")
        }
    }

    func testHottestSensorStillControlsHeatSeverity() {
        let gpuHot = ThermalStatus(cpu: 60, gpu: 95, thermalState: .nominal)
        XCTAssertEqual(gpuHot.tone, .danger)
        XCTAssertEqual(gpuHot.labelKey, "monitor.thermal.hot")

        let pressureAndHeat = ThermalStatus(cpu: 95, gpu: nil, thermalState: .serious)
        XCTAssertEqual(pressureAndHeat.tone, .danger)
        XCTAssertEqual(pressureAndHeat.labelKey, "monitor.thermal.serious")
    }

    func testFairPressureDoesNotClaimNormalEvenWithoutSensors() {
        for temperature in [Double?.none, 45, 69] {
            let status = ThermalStatus(cpu: temperature, gpu: nil, thermalState: .fair)
            XCTAssertEqual(status.tone, .warning)
            XCTAssertEqual(status.labelKey, "monitor.thermal.fair")
        }
    }
}
