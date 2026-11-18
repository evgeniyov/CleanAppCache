import Foundation
import UserNotifications

// MARK: - Notification Manager
//
// Handles macOS user notifications for CleanAppCache.
// Currently supports: low-disk-space alert (throttled to once per 24 h).

@MainActor
public final class NotificationManager {
    public static let shared = NotificationManager()
    public static let lowDiskEnabledKey = "notifications.lowDiskEnabled"
    private let defaults: UserDefaults
    private let deliver: (UNNotificationRequest) -> Void

    init(defaults: UserDefaults = .standard,
         deliver: @escaping (UNNotificationRequest) -> Void = {
             UNUserNotificationCenter.current().add($0, withCompletionHandler: nil)
         }) {
        self.defaults = defaults
        self.deliver = deliver
    }

    private static let lowDiskCooldownKey   = "NotificationManager.lastLowDisk"
    private static let cooldownInterval: TimeInterval = 86_400   // 24 h

    // MARK: - Authorization

    /// Request permission when an alert is enabled explicitly in Settings.
    public func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    // MARK: - Generic throttled notification

    /// Posts a notification unless the same `cooldownKey` fired within
    /// `cooldown` seconds. Used by the monitor threshold alerts.
    public func post(id: String, title: String, body: String,
                     cooldownKey: String, cooldown: TimeInterval = 1800) {
        if let last = defaults.object(forKey: cooldownKey) as? Date,
           Date().timeIntervalSince(last) < cooldown { return }
        defaults.set(Date(), forKey: cooldownKey)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        deliver(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: - Low disk

    /// Call from a background timer. Posts a notification when free space drops
    /// below 10 % of total capacity, at most once per 24 h.
    public func checkLowDisk(freeBytes: UInt64, totalBytes: UInt64) {
        guard defaults.bool(forKey: Self.lowDiskEnabledKey), totalBytes > 0 else { return }
        let freePercent = Double(freeBytes) / Double(totalBytes)
        guard freePercent < 0.10 else { return }

        // Throttle
        if let last = defaults.object(forKey: Self.lowDiskCooldownKey) as? Date,
           Date().timeIntervalSince(last) < Self.cooldownInterval { return }
        defaults.set(Date(), forKey: Self.lowDiskCooldownKey)

        let freeFormatted = Fmt.bytes(Int64(freeBytes))
        let loc = Localizer.shared

        let content        = UNMutableNotificationContent()
        content.title      = loc.s("notification.lowDisk.title")
        content.body       = loc.f("notification.lowDisk.body", Int(freePercent * 100), freeFormatted)
        content.sound      = .default

        let request = UNNotificationRequest(
            identifier: "com.cleanappcache.lowdisk",
            content: content,
            trigger: nil    // deliver immediately
        )
        deliver(request)
    }
}
