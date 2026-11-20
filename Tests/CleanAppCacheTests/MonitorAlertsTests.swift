import XCTest
@testable import CleanAppCacheLib

final class MonitorAlertsTests: XCTestCase {
    @MainActor
    func testTemperatureStreakCountsDistinctMeasurementsAndResetsOnMissingReading() throws {
        let suite = "MonitorAlertsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: MonitorAlerts.enabledKey)

        var delivered: [String] = []
        let notifications = NotificationManager(defaults: defaults) { request, completion in
            delivered.append(request.identifier)
            completion(true)
        }
        let alerts = MonitorAlerts(defaults: defaults, notifications: notifications)
        func tick(temperature: Double?, time: TimeInterval) {
            alerts.check(.init(cpu: 0, perCore: [], memPercent: 0, memPressure: .normal,
                               gpu: nil, cpuTemp: temperature, gpuTemp: nil, cpuTempSampleTime: time))
        }

        tick(temperature: 91, time: 1)
        tick(temperature: 91, time: 1)
        XCTAssertTrue(delivered.isEmpty)
        tick(temperature: nil, time: 2)
        tick(temperature: 91, time: 3)
        XCTAssertTrue(delivered.isEmpty)
        tick(temperature: 91, time: 4)
        XCTAssertEqual(delivered, ["com.cleanappcache.alert.temp"])
    }
}
