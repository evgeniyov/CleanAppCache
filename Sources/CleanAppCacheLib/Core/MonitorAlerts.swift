import Foundation

// MARK: - Threshold alerts
//
// Watches the metrics the menu-bar sampler already collects (every 5 s, even
// with the main window closed) and posts a notification when a threshold is
// crossed. Spike-resistant: CPU/temperature must stay above the threshold for
// several consecutive ticks before alerting. Each alert type has a cooldown so
// a sustained condition doesn't spam.

@MainActor
public final class MonitorAlerts {
    public static let shared = MonitorAlerts(defaults: .standard, notifications: .shared)

    // UserDefaults keys (bound from SettingsView via @AppStorage).
    public static let enabledKey        = "alerts.enabled"
    public static let cpuEnabledKey     = "alerts.cpuEnabled"
    public static let cpuThresholdKey   = "alerts.cpuThreshold"      // %
    public static let tempEnabledKey    = "alerts.tempEnabled"
    public static let tempThresholdKey  = "alerts.tempThreshold"     // °C
    public static let pressureEnabledKey = "alerts.pressureEnabled"

    private let d: UserDefaults
    private let notifications: NotificationManager

    init(defaults: UserDefaults, notifications: NotificationManager) {
        d = defaults
        self.notifications = notifications
    }

    public var isEnabled: Bool { d.bool(forKey: Self.enabledKey) }
    private var cpuOn: Bool { d.object(forKey: Self.cpuEnabledKey) == nil ? true : d.bool(forKey: Self.cpuEnabledKey) }
    private var tempOn: Bool { d.object(forKey: Self.tempEnabledKey) == nil ? true : d.bool(forKey: Self.tempEnabledKey) }
    private var pressureOn: Bool { d.object(forKey: Self.pressureEnabledKey) == nil ? true : d.bool(forKey: Self.pressureEnabledKey) }
    private var cpuThreshold: Double { d.object(forKey: Self.cpuThresholdKey) == nil ? 90 : d.double(forKey: Self.cpuThresholdKey) }
    private var tempThreshold: Double { d.object(forKey: Self.tempThresholdKey) == nil ? 85 : d.double(forKey: Self.tempThresholdKey) }

    /// The sampler should pay for a temperature read even when no temp metric
    /// is pinned to the bar, so the alert can actually fire.
    public var wantsTemperature: Bool { isEnabled && tempOn }

    // Consecutive-ticks-over-threshold counters (5 s per tick).
    private var cpuStreak = 0
    private var tempStreak = 0
    private var lastTempSample: TimeInterval?

    /// Called after a scheduled menu-bar sample.
    func check(_ reading: SystemMonitor.MenuReading) {
        guard isEnabled else { cpuStreak = 0; tempStreak = 0; return }
        let loc = Localizer.shared
        let cpu = reading.cpu

        // CPU: sustained load for ≥3 ticks (~15 s) — ignores momentary spikes.
        // Every tick past the streak asks to post and the cooldown drops the
        // repeats. Posting only on the tick the streak reaches 3 lost a long
        // episode whose third tick fell inside an earlier episode's cooldown.
        if cpuOn, cpu >= cpuThreshold {
            cpuStreak += 1
            if cpuStreak >= 3 {
                notifications.post(
                    id: "com.cleanappcache.alert.cpu",
                    title: loc.s("alert.cpu.title"),
                    body: loc.f("alert.cpu.bodyFmt", Int(cpu), Int(cpuThreshold)),
                    cooldownKey: "alerts.cooldown.cpu")
            }
        } else {
            cpuStreak = 0
        }

        // Reusing a cached value cannot extend or break a streak.
        if !tempOn {
            tempStreak = 0
        } else if let time = reading.cpuTempSampleTime, time != lastTempSample {
            lastTempSample = time
            if let temp = reading.cpuTemp, temp >= tempThreshold {
                tempStreak += 1
                if tempStreak >= 2 {
                    notifications.post(
                        id: "com.cleanappcache.alert.temp",
                        title: loc.s("alert.temp.title"),
                        body: loc.f("alert.temp.bodyFmt", Int(temp), Int(tempThreshold)),
                        cooldownKey: "alerts.cooldown.temp")
                }
            } else {
                tempStreak = 0
            }
        }

        // Memory pressure critical: the kernel signal itself is already damped.
        if pressureOn, reading.memPressure == .critical {
            notifications.post(
                id: "com.cleanappcache.alert.pressure",
                title: loc.s("alert.pressure.title"),
                body: loc.s("alert.pressure.body"),
                cooldownKey: "alerts.cooldown.pressure")
        }
    }
}
