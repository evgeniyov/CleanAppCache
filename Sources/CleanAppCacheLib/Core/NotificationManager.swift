import Foundation
import UserNotifications

// MARK: - Notification Manager
//
// Handles macOS user notifications for CleanAppCache.
// Throttles monitor and low-disk-space alerts.

@MainActor
public final class NotificationManager {
    public static let shared = NotificationManager()
    public static let lowDiskEnabledKey = "notifications.lowDiskEnabled"
    private let defaults: UserDefaults
    typealias Submission = (UNNotificationRequest, @escaping @MainActor @Sendable (Bool) -> Void) -> Void
    private let deliver: Submission
    private var pending: Set<String> = []

    init(defaults: UserDefaults = .standard,
         deliver: @escaping Submission = { request, completion in
             UNUserNotificationCenter.current().add(request) { error in
                 let succeeded = error == nil
                 Task { @MainActor in completion(succeeded) }
             }
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
        guard !pending.contains(cooldownKey) else { return }
        if let last = defaults.object(forKey: cooldownKey) as? Date,
           Date().timeIntervalSince(last) < cooldown { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        pending.insert(cooldownKey)
        deliver(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { [weak self] succeeded in
            guard let self else { return }
            self.pending.remove(cooldownKey)
            if succeeded { self.defaults.set(Date(), forKey: cooldownKey) }
        }
    }

    // MARK: - Low disk

    /// Call from a background timer. Posts a notification when free space drops
    /// below 10 % of total capacity, at most once per 24 h.
    public func checkLowDisk(freeBytes: UInt64, totalBytes: UInt64) {
        guard defaults.bool(forKey: Self.lowDiskEnabledKey), totalBytes > 0 else { return }
        let freePercent = Double(freeBytes) / Double(totalBytes)
        guard freePercent < 0.10 else { return }

        let freeFormatted = Fmt.bytes(Int64(freeBytes))
        let loc = Localizer.shared
        post(id: "com.cleanappcache.lowdisk",
             title: loc.s("notification.lowDisk.title"),
             body: loc.f("notification.lowDisk.body", Int(freePercent * 100), freeFormatted),
             cooldownKey: Self.lowDiskCooldownKey, cooldown: Self.cooldownInterval)
    }
}
