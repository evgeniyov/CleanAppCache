import Foundation
import IOKit.ps

enum StorageBackgroundDecision {
    static let enabledKey = "storage.dailyBackgroundMeasurement"
    static let lastAttemptKey = "storage.dailyBackgroundAttempt"

    static func shouldMeasure(now: Date, latest: Date?, lastAttempt: Date?,
                              enabled: Bool, isRunning: Bool, lowPower: Bool,
                              calendar: Calendar = .current) -> Bool {
        guard enabled, !isRunning, !lowPower else { return false }
        if let latest, now.timeIntervalSince(latest) <= 86_400 { return false }
        if let lastAttempt, calendar.isDate(lastAttempt, inSameDayAs: now) { return false }
        return true
    }

    static func isPowerConstrained() -> Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sources.contains { source in
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let current = description[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = description[kIOPSMaxCapacityKey] as? NSNumber,
                  maximum.doubleValue > 0 else { return false }
            return current.doubleValue / maximum.doubleValue <= 0.20
        }
    }
}

@MainActor
public final class StorageBackgroundMeasurement {
    public static let shared = StorageBackgroundMeasurement()
    private var task: Task<Void, Never>?

    private init() {}

    public func start() {
        guard task == nil else { return }
        task = Task(priority: .background) {
            // Let an opening Storage window start its interactive measurement first.
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                await StorageManager.shared.measureDailyIfNeeded()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
