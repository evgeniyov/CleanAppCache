import XCTest
import UserNotifications
@testable import CleanAppCacheLib

final class NotificationSettingsTests: XCTestCase {
    @MainActor
    func testLowDiskIsOptInAndDoesNotConsumeCooldownWhileDisabled() throws {
        let suite = "NotificationSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var requests: [UNNotificationRequest] = []
        let manager = NotificationManager(defaults: defaults) { request, completion in
            requests.append(request)
            completion(true)
        }
        manager.checkLowDisk(freeBytes: 5, totalBytes: 100)
        XCTAssertTrue(requests.isEmpty)
        defaults.set(true, forKey: NotificationManager.lowDiskEnabledKey)
        manager.checkLowDisk(freeBytes: 5, totalBytes: 100)
        XCTAssertEqual(requests.count, 1)
        manager.checkLowDisk(freeBytes: 4, totalBytes: 100)
        XCTAssertEqual(requests.count, 1, "Repeated low-space readings respect the cooldown")
        defaults.set(false, forKey: NotificationManager.lowDiskEnabledKey)
        defaults.removeObject(forKey: "NotificationManager.lastLowDisk")
        manager.checkLowDisk(freeBytes: 1, totalBytes: 100)
        XCTAssertEqual(requests.count, 1)
    }

    @MainActor
    func testHealthyOrUnknownCapacityDoesNotNotify() throws {
        let suite = "NotificationSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: NotificationManager.lowDiskEnabledKey)
        var requests: [UNNotificationRequest] = []
        let manager = NotificationManager(defaults: defaults) { request, completion in
            requests.append(request)
            completion(true)
        }
        manager.checkLowDisk(freeBytes: 0, totalBytes: 0)
        manager.checkLowDisk(freeBytes: 10, totalBytes: 100)
        manager.checkLowDisk(freeBytes: 100, totalBytes: 100)
        XCTAssertTrue(requests.isEmpty)
        manager.checkLowDisk(freeBytes: 9, totalBytes: 100)
        XCTAssertEqual(requests.count, 1)
    }

    @MainActor
    func testLowDiskDeduplicatesPendingRequestsAndRetriesAfterRejection() throws {
        let suite = "NotificationSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: NotificationManager.lowDiskEnabledKey)

        var completions: [@MainActor @Sendable (Bool) -> Void] = []
        let manager = NotificationManager(defaults: defaults) { _, completion in
            completions.append(completion)
        }
        let key = "NotificationManager.lastLowDisk"
        manager.checkLowDisk(freeBytes: 5, totalBytes: 100)
        manager.checkLowDisk(freeBytes: 5, totalBytes: 100)
        XCTAssertEqual(completions.count, 1)
        XCTAssertNil(defaults.object(forKey: key))
        try XCTUnwrap(completions.last)(false)
        XCTAssertNil(defaults.object(forKey: key))

        manager.checkLowDisk(freeBytes: 4, totalBytes: 100)
        XCTAssertEqual(completions.count, 2)
        try XCTUnwrap(completions.last)(true)
        XCTAssertNotNil(defaults.object(forKey: key) as? Date)
        manager.checkLowDisk(freeBytes: 4, totalBytes: 100)
        XCTAssertEqual(completions.count, 2)
    }
}
