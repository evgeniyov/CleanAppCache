import Foundation
import SwiftUI

@MainActor
public final class MonitorViewModel: ObservableObject {
    @Published public var snapshot: SystemSnapshot?

    // Rolling histories for sparklines (most-recent last).
    @Published public var cpuHistory: [Double] = []
    @Published public var memHistory: [Double] = []
    @Published public var netDownHistory: [Double] = []
    @Published public var netUpHistory: [Double] = []
    @Published public var diskHistory: [Double] = []
    @Published public var gpuHistory: [Double] = []

    /// Processes pre-grouped once per sample. Views read this instead of calling
    /// `groupProcesses` inside `body` (which re-bucketed on every SwiftUI render).
    @Published public var processGroups: [ProcessGroup] = []

    /// System thermal pressure (public API): shows whether macOS is throttling.
    @Published public var thermalState: ProcessInfo.ThermalState = .nominal

    /// Static machine facts, resolved once on the main actor at init. The view
    /// reads THIS instead of calling `SystemMonitor.shared.machineInfo()` from its
    /// body: that shared instance is mutated by `sample()` on a background queue,
    /// so touching it from the MainActor render path is a data race.
    public let machineInfo: MachineInfo

    /// Whether this Mac exposes a GPU temperature sensor (false on base Apple
    /// Silicon). Drives the "sensor unavailable" hint in the temperatures panel.
    ///
    /// Probed on the sample queue, not in `init`: on its own the probe
    /// enumerates the SMC keys, about 40 ms of main-thread time. Asked right
    /// after a sample, it is answered from that sample's temperature reading,
    /// and it arrives with the first snapshot, before any temperature is on
    /// screen.
    @Published public private(set) var gpuTempSupported = true

    /// How many points to keep — 300 @ 2 s ≈ the last 10 minutes. The sparkline
    /// paths handle a few hundred points without breaking a sweat.
    private let historyLength = 300
    private let interval: TimeInterval = 2.0
    /// Persist histories every N ticks so graphs survive relaunches.
    private var ticksSinceSave = 0

    private let monitor = SystemMonitor.shared
    private var timer: Timer?
    /// Started by the screen: between its `start()` and `stop()`.
    private var isRunning = false
    /// Whether the window showing the screen can be seen. Sampling runs only
    /// while this and `isRunning` both hold; a minimized, hidden or fully
    /// covered window draws nothing, so sampling for it is pure cost.
    private var isVisible = true
    /// `processListID` of the list `processGroups` was built from.
    private var groupedListID: Int?

    /// Dedicated background queue so the (blocking) `ps` + IOKit walks never
    /// touch the main thread — the UI stays smooth and CPU cost is contained.
    private let sampleQueue = DispatchQueue(label: "cleanappcache.monitor.sample", qos: .utility)
    private var sampling = false
    private var samplingGeneration = UUID()
    private let persistHistory: Bool

    private let sampleOverride: (@Sendable () -> (SystemSnapshot, Bool))?

    public convenience init() {
        self.init(machineInfo: SystemMonitor.shared.machineInfo(), sample: nil, loadHistory: true)
    }

    init(machineInfo: MachineInfo, sample: (@Sendable () -> (SystemSnapshot, Bool))?, loadHistory: Bool = false) {
        self.sampleOverride = sample
        self.persistHistory = loadHistory
        // Resolve static facts once, before the background sampler starts, so the
        // shared monitor is never read from the MainActor and the background queue
        // at the same time.
        self.machineInfo = machineInfo
        if loadHistory { loadHistories() }
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        resumeIfNeeded()
    }

    public func stop() {
        isRunning = false
        pause()
        saveHistories()    // graphs survive tab switches and relaunches
    }

    /// Follows the visibility of the window the screen is in. Hiding pauses
    /// the sampler without saving; showing again takes a sample at once, so the
    /// screen does not sit on a reading from before it was covered.
    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible { resumeIfNeeded() } else { pause() }
    }

    private func resumeIfNeeded() {
        guard isRunning, isVisible, timer == nil else { return }
        tick()   // prime immediately
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard self?.isRunning == true else { return }
                self?.tick()
            }
        }
        // ~10% slop lets the kernel coalesce the wakeup with other timers.
        timer?.tolerance = interval * 0.1
    }

    private func pause() {
        timer?.invalidate()
        timer = nil
        samplingGeneration = UUID()   // in-flight work still owns the busy flag
    }

    private func tick() {
        // Skip if the previous sample is still running (avoids pile-up under load).
        guard isRunning, isVisible, !sampling else { return }
        sampling = true
        let generation = samplingGeneration
        sampleQueue.async { [weak self] in
            guard let self else { return }
            let (snap, gpuTemp) = self.sampleOverride?()
                ?? (self.monitor.sample(), self.monitor.probeGPUTempAvailable())
            // Cached after its first call, and that call is answered from the
            // temperature reading `sample()` has just taken.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sampling = false
                guard generation == self.samplingGeneration, self.isRunning, self.isVisible else {
                    if self.isRunning, self.isVisible { self.tick() }
                    return
                }
                self.apply(snap, gpuTempSupported: gpuTemp)
            }
        }
    }

    /// Assigns only what changed: every assignment to a published property
    /// invalidates the whole screen, whether or not the value moved.
    private func apply(_ snap: SystemSnapshot, gpuTempSupported gpuTemp: Bool) {
        snapshot = snap
        if gpuTempSupported != gpuTemp { gpuTempSupported = gpuTemp }
        // Group processes once here (not in the view body, which runs on every
        // render), and only for a freshly listed set: the sampler reuses its
        // list for several ticks, and regrouping it would rebuild the same
        // groups. Views sort/filter this cheap, already-bucketed list.
        if snap.processListID != groupedListID {
            groupedListID = snap.processListID
            processGroups = monitor.groupProcesses(snap.processes)
        }
        let thermal = ProcessInfo.processInfo.thermalState
        if thermalState != thermal { thermalState = thermal }
        push(&cpuHistory, snap.cpuPercent)
        push(&memHistory, snap.memPercent)
        push(&netDownHistory, snap.netDownBytesPerSec)
        push(&netUpHistory, snap.netUpBytesPerSec)
        push(&diskHistory, snap.diskReadBytesPerSec + snap.diskWriteBytesPerSec)
        if let gpu = snap.gpuPercent { push(&gpuHistory, gpu) }

        ticksSinceSave += 1
        if ticksSinceSave >= 30 {           // ~ once a minute
            ticksSinceSave = 0
            saveHistories()
        }
    }

    // MARK: - History persistence (graphs survive relaunches)

    private struct HistoryFile: Codable {
        var cpu: [Double]; var mem: [Double]
        var netDown: [Double]; var netUp: [Double]
        var disk: [Double]; var gpu: [Double]
        var savedAt: Date
    }

    private static var historyURL: URL? {
        let dir = AppPaths.support
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("monitor-history.json")
    }

    private func saveHistories() {
        guard persistHistory else { return }
        guard let url = Self.historyURL else { return }
        let file = HistoryFile(cpu: cpuHistory, mem: memHistory,
                               netDown: netDownHistory, netUp: netUpHistory,
                               disk: diskHistory, gpu: gpuHistory, savedAt: Date())
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadHistories() {
        guard let url = Self.historyURL,
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(HistoryFile.self, from: data),
              // Stale graphs are worse than empty ones — only restore recent data.
              Date().timeIntervalSince(file.savedAt) < 3600
        else { return }
        cpuHistory = Array(file.cpu.suffix(historyLength))
        memHistory = Array(file.mem.suffix(historyLength))
        netDownHistory = Array(file.netDown.suffix(historyLength))
        netUpHistory = Array(file.netUp.suffix(historyLength))
        diskHistory = Array(file.disk.suffix(historyLength))
        gpuHistory = Array(file.gpu.suffix(historyLength))
    }

    private func push(_ buffer: inout [Double], _ value: Double) {
        buffer.append(value)
        if buffer.count > historyLength {
            buffer.removeFirst(buffer.count - historyLength)
        }
    }

    // MARK: Formatting helpers

    /// An idle interface reads as an em dash, never a zero rate, and the "/s" comes
    /// from the localized unit rather than being glued on in Latin.
    public static func formatRate(_ bytesPerSec: Double) -> String {
        Fmt.speedString(bytesPerSec)
    }

    public static func formatBytes(_ bytes: UInt64) -> String {
        Fmt.bytes(Int64(bytes))
    }
}
