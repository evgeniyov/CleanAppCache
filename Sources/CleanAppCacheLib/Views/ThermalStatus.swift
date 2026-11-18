import Foundation

/// A readable sensor does not override the system's thermal-pressure warning.
/// Temperature alone describes heat; only macOS can report thermal throttling.
struct ThermalStatus: Equatable, Sendable {
    let tone: Tone
    let labelKey: String

    init(cpu: Double?, gpu: Double?, thermalState: ProcessInfo.ThermalState) {
        let peak = [cpu, gpu].compactMap { $0 }.max()
        let sensorTone: Tone
        if let peak {
            sensorTone = peak < 70 ? .success : (peak < 90 ? .warning : .danger)
        } else {
            sensorTone = .neutral
        }

        switch thermalState {
        case .critical:
            tone = .danger
            labelKey = "monitor.thermal.critical"
        case .serious:
            tone = sensorTone == .danger ? .danger : .warning
            labelKey = "monitor.thermal.serious"
        case .fair:
            tone = sensorTone == .danger ? .danger : .warning
            labelKey = sensorTone == .danger ? "monitor.thermal.hot" : "monitor.thermal.fair"
        case .nominal:
            tone = peak == nil ? .success : sensorTone
            switch tone {
            case .warning: labelKey = "monitor.thermal.fair"
            case .danger: labelKey = "monitor.thermal.hot"
            default: labelKey = "monitor.thermal.nominal"
            }
        @unknown default:
            tone = sensorTone
            switch sensorTone {
            case .success: labelKey = "monitor.thermal.nominal"
            case .warning: labelKey = "monitor.thermal.fair"
            case .danger: labelKey = "monitor.thermal.hot"
            default: labelKey = "monitor.thermal.unavailable"
            }
        }
    }
}
