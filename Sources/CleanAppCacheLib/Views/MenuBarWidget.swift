import SwiftUI
import AppKit
import Combine

// MARK: - Menu-bar widget
//
// The label is the app's smallest surface and the popover its only surface
// while the window is closed, so both follow the token set: flat fills,
// hairline separators, monospaced figures, and colour that means risk.
//
// Structure of the popover (280pt): header with the sampling cadence,
// a metre block per load, a reading row per sensor, then the menu — open,
// **quick cleanup with its size**, choose metrics, quit. The quick-cleanup item
// keeps the app's main action reachable without opening the window.
//
// Sampling runs on a 5 s tick; the persisted metric list, the GPU-temp probe
// and the low-disk check live below alongside their presentation.

public extension Notification.Name {
    /// Ask whatever SwiftUI scene is alive to bring the main window back.
    ///
    /// The app keeps running after its window closes so the menu-bar readout
    /// stays live, and it drops to `.accessory` so there is no stale Dock icon.
    /// The cost is that a relaunch can come up with no window and no Dock icon —
    /// which is what happens after macOS quits and reopens the app to apply Full
    /// Disk Access. The process is there, the menu-bar item is there, and the
    /// user sees nothing.
    static let cacShowMainWindow = Notification.Name("cac.showMainWindow")
}

// MARK: - Selectable menu-bar metrics

public enum MenuBarMetric: String, CaseIterable, Identifiable, Sendable {
    case cpuLoad, memLoad, gpuLoad, cpuTemp, gpuTemp
    public var id: String { rawValue }

    var labelKey: String { "menubar.metric.\(rawValue)" }

    /// The temperature that shares this load's column in the stacked layout;
    /// nil for metrics that have no paired reading.
    var companionTemperature: MenuBarMetric? {
        switch self {
        case .cpuLoad: return .cpuTemp
        case .gpuLoad: return .gpuTemp
        default:       return nil
        }
    }

    /// The load whose column this temperature folds into when stacked.
    var pairedLoad: MenuBarMetric? {
        switch self {
        case .cpuTemp: return .cpuLoad
        case .gpuTemp: return .gpuLoad
        default:       return nil
        }
    }

    var icon: String {
        switch self {
        case .cpuLoad: return "cpu"
        case .memLoad: return "memorychip"
        case .gpuLoad: return "cpu.fill"
        case .cpuTemp: return "thermometer.medium"
        case .gpuTemp: return "thermometer.high"
        }
    }
}

// MARK: - Readings

/// One menu-bar reading, at the precision the menu-bar surfaces show it.
///
/// Values are floored to a tenth. Every figure on the bar and in the popover is
/// a whole number, truncated (`Int(x)`) or rounded, and every temperature word
/// compares against a whole-degree threshold; flooring to a tenth changes none
/// of those results, and moves a bar by at most a tenth of a percent. What it
/// buys is equality: two readings that agree to a tenth compare equal, so a
/// tick that changed nothing visible publishes nothing.
public struct MenuBarReadings: Equatable, Sendable {
    public var cpuPercent: Double = 0
    public var memPercent: Double = 0
    public var memPressure: MemoryPressure = .normal
    public var gpuPercent: Double?
    public var cpuTemp: Double?
    public var gpuTemp: Double?

    public init() {}

    static func displayed(_ value: Double) -> Double { (value * 10).rounded(.down) / 10 }

    /// Short text for a metric in the status bar (e.g. "24%", "38°", "—").
    public func shortValue(_ metric: MenuBarMetric) -> String {
        switch metric {
        case .cpuLoad: return "\(Int(cpuPercent))%"
        case .memLoad: return "\(Int(memPercent))%"
        case .gpuLoad: return gpuPercent.map { "\(Int($0))%" } ?? "—"
        case .cpuTemp: return cpuTemp.map { "\(Int($0))°" } ?? "—"
        case .gpuTemp: return gpuTemp.map { "\(Int($0))°" } ?? "—"
        }
    }

    /// 0…1 for the gauge layout; nil when the metric has no 0–100 scale.
    public func loadFraction(_ metric: MenuBarMetric) -> Double? {
        switch metric {
        case .cpuLoad:            return cpuPercent / 100
        case .memLoad:            return memPercent / 100
        case .gpuLoad:            return gpuPercent.map { $0 / 100 }
        case .cpuTemp, .gpuTemp:  return nil
        }
    }
}

// MARK: - Menu bar controller
//
// Three surfaces show the readings, and each observes only what it draws. The
// status item observes `statusLabel`, which speaks up only when the label's
// pixels would change. The popover observes `popover`, which changes only while
// the popover is open: SwiftUI keeps the popover's view alive after its first
// opening, so anything it observes re-lays it out, and replays its number and
// bar animations, on every tick with nothing on screen. The Settings preview
// exists only while it is shown and observes the controller itself.

@MainActor
public final class MenuBarController: ObservableObject {
    public static let shared = MenuBarController()

    /// The latest reading. Assigned only when it differs, so the Settings
    /// preview redraws for a changed figure and not for a tick.
    @Published public private(set) var readings = MenuBarReadings()

    /// Per-logical-core load, 0…100 — the `cores` status-bar layout.
    @Published public private(set) var perCore: [Double] = []

    /// Recent load of the first pinned metric, 0…1, oldest first — the `graph`
    /// layout. At the 5 s menu-bar cadence 12 points is a minute, which is what
    /// a sparkline that narrow can show without turning into a smudge.
    @Published public private(set) var history: [Double] = []
    private static let historyLength = 12

    /// Whether this Mac exposes a GPU temperature sensor. False on base Apple
    /// Silicon — the GPU-temp menu-bar metric is then disabled and can't be
    /// pinned. Probed once off the main thread at init.
    @Published public private(set) var gpuTempSupported = true {
        didSet { popover.configurationChanged() }
    }

    /// Which metrics appear in the status-bar label (ordered). Persisted.
    @Published public var selectedMetrics: [MenuBarMetric] {
        didSet {
            defaults?.set(selectedMetrics.map(\.rawValue), forKey: Self.key)
            refreshStatusLabel()
            popover.configurationChanged()
        }
    }

    /// What the status item observes.
    public let statusLabel = MenuBarStatusLabel()
    /// What the popover observes.
    public let popover = MenuBarPopoverModel()

    private static let key = "app.menuBarMetrics"
    private let defaults: UserDefaults?
    // Ticks every 5 s; a TTL above that interval is what makes the temperature
    // cache actually cache instead of missing on every single tick.
    private let monitor = SystemMonitor(temperatureTTL: 12)
    private let queue = DispatchQueue(label: "cleanappcache.menubar.sample", qos: .utility)
    private var timer: Timer?
    private var sampling  = false
    private var tickCount = 0   // incremented every tick (5 s)

    /// True while the popover is on screen. The popover shows GPU + temperatures,
    /// so we compute them every tick while it's open even if the bar itself only
    /// shows CPU/RAM. When closed, each is only computed if its metric is
    /// actually pinned to the status bar (or, for the CPU temperature, an alert
    /// watches it).
    private var popoverVisible = false

    init(defaults: UserDefaults? = .standard, startSampling: Bool = true) {
        self.defaults = defaults
        if let raw = defaults?.array(forKey: Self.key) as? [String] {
            let parsed = raw.compactMap { MenuBarMetric(rawValue: $0) }
            selectedMetrics = parsed.isEmpty ? [.cpuLoad] : parsed
        } else {
            selectedMetrics = [.cpuLoad, .memLoad]   // sensible default
        }
        guard startSampling else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Lives for the whole process; without tolerance the kernel must honor
        // each 5 s deadline exactly and can never coalesce the wakeup. The
        // readout is only cadence-accurate anyway.
        timer?.tolerance = 0.5

        // Probe GPU-temperature sensor support once, off the main thread. If it's
        // absent, disable the metric and drop it from any persisted selection so it
        // can't show a permanent "—" in the bar.
        queue.async { [weak self] in
            guard let self else { return }
            let supported = self.monitor.probeGPUTempAvailable()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.gpuTempSupported = supported
                if !supported, self.selectedMetrics.contains(.gpuTemp) {
                    self.selectedMetrics.removeAll { $0 == .gpuTemp }
                    if self.selectedMetrics.isEmpty { self.selectedMetrics = [.cpuLoad] }
                }
            }
        }
    }

    /// Called when the popover appears/disappears so we can compute the extra
    /// metrics it shows only while it's visible, and refresh immediately on open.
    public func setPopoverVisible(_ visible: Bool) {
        popoverVisible = visible
        // The popover opens on the latest reading, not on the one it last
        // showed, before the fresh GPU/temperature read below lands.
        popover.setVisible(visible, latest: readings)
        if visible { tick() }   // refresh GPU/temps right away
    }

    public func toggle(_ metric: MenuBarMetric) {
        // Refuse to pin a metric whose sensor doesn't exist on this Mac.
        guard isAvailable(metric) else { return }
        if let idx = selectedMetrics.firstIndex(of: metric) {
            if selectedMetrics.count > 1 { selectedMetrics.remove(at: idx) }  // keep ≥1
        } else {
            selectedMetrics.append(metric)
        }
    }

    public func isOn(_ metric: MenuBarMetric) -> Bool { selectedMetrics.contains(metric) }

    /// Whether the metric's sensor is readable on this hardware.
    public func isAvailable(_ metric: MenuBarMetric) -> Bool {
        metric == .gpuTemp ? gpuTempSupported : true
    }

    /// Short text for a metric in the status bar (e.g. "24%", "38°", "—").
    public func shortValue(_ metric: MenuBarMetric) -> String {
        readings.shortValue(metric)
    }

    /// One column of the status-bar widget.
    public struct WidgetCell: Identifiable, Equatable, Sendable {
        public let id: String
        /// Upper tier of the stacked layout: the paired temperature when there
        /// is one, otherwise the metric's own short caption.
        public let top: String
        public let caption: String
        public let value: String
        /// nil for a temperature: °C has no 0–100 scale to fill.
        public let fraction: Double?
    }

    /// What the widget draws, in order.
    ///
    /// The Settings preview and `MenuBarLabelRenderer` both read this. Computing
    /// it separately in each would make "a live preview of the real menu bar" a
    /// promise the preview could quietly break.
    public func widgetCells(style: MenuBarStyle, localized: (String) -> String) -> [WidgetCell] {
        let pinned = selectedMetrics
        // The pairing — with both CPU load and CPU temperature pinned, the
        // temperature becomes the upper line above the load — applies to
        // the **stacked** layout, which is the only one with an upper tier to
        // put it on. Applied everywhere, it drops the temperature outright:
        // `.inline` and `.dotted` would show one metric when two are pinned.
        let pairs = style == .stack

        var cells: [WidgetCell] = []
        for metric in pinned {
            if pairs, let load = metric.pairedLoad, pinned.contains(load) { continue }

            let companion = metric.companionTemperature
            let paired = pairs
                ? companion.flatMap { pinned.contains($0) ? shortValue($0) : nil }
                : nil
            let caption = localized("menubar.short.\(metric.rawValue)")
            cells.append(WidgetCell(id: metric.rawValue,
                                    top: paired ?? caption,
                                    caption: caption,
                                    value: shortValue(metric),
                                    fraction: loadFraction(metric)))
        }
        return cells
    }

    /// Exactly what the status-bar label draws in `style`.
    ///
    /// The status item and the Settings preview both render from this, so the
    /// preview cannot drift from the real bar, and the status item compares
    /// it with what it last drew to decide whether to draw at all.
    public func labelState(style: MenuBarStyle) -> MenuBarLabelState {
        let all = widgetCells(style: style, localized: { Localizer.shared.s($0) })
        // Four of the layouts draw a graphic beside one number; crowding a
        // second metric in beside it defeats the point of the graphic.
        var cells = style.showsSingleMetric ? Array(all.prefix(1)) : all
        cells = cells.enumerated().map { index, cell in
            // The dot is part of the string so it inherits the spacing and the
            // monospaced advance.
            let value = style == .dotted && index > 0 ? "· " + cell.value : cell.value
            return WidgetCell(id: cell.id, top: cell.top, caption: cell.caption,
                              value: value,
                              fraction: cell.fraction.map(MenuBarLabelState.wholePercent))
        }
        return MenuBarLabelState(
            style: style,
            cells: cells,
            // Only the layouts that draw these carry them, so a new sparkline
            // point or a core's flicker never redraws a label that shows neither.
            history: style == .graph ? history.map(MenuBarLabelState.wholePercent) : [],
            perCore: style == .cores ? perCore.map { $0.rounded(.down) } : []
        )
    }

    private func refreshStatusLabel() {
        statusLabel.refresh { self.labelState(style: $0) }
    }

    /// Records the primary metric's current load for the sparkline.
    private func appendHistory() {
        guard let first = selectedMetrics.first,
              let fraction = loadFraction(first) else { return }
        history.append(max(0, min(1, fraction)))
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
    }

    /// 0…1 for the gauge layout; nil when the metric has no 0–100 scale.
    public func loadFraction(_ metric: MenuBarMetric) -> Double? {
        readings.loadFraction(metric)
    }

    private func tick() {
        // Low-disk check every ~60 s (12 × 5 s timer interval). The volume stat is
        // a filesystem syscall that can block on a slow/sleeping disk, so it must
        // not run on the MainActor — do it on the sampler queue and hop back only
        // to deliver the result.
        tickCount += 1
        if tickCount.isMultiple(of: 12), UserDefaults.standard.bool(forKey: NotificationManager.lowDiskEnabledKey) {
            queue.async {
                // Same free-space definition the Storage screen shows, so the
                // alert can't contradict the number on screen.
                guard let info = StorageInfo.read() else { return }
                Task { @MainActor in
                    NotificationManager.shared.checkLowDisk(
                        freeBytes: info.freeBytes, totalBytes: info.totalBytes)
                }
            }
        }

        guard !sampling else { return }
        sampling = true

        // Only pay for the GPU/temperature reads when something actually shows
        // them: a pinned status-bar metric, or the open popover. Each
        // temperature is its own set of SMC keys, so each is asked for alone.
        let needGPU = popoverVisible || selectedMetrics.contains(.gpuLoad)
        let needCPUTemp = popoverVisible
            || selectedMetrics.contains(.cpuTemp)
            || MonitorAlerts.shared.wantsTemperature   // temp alerts need a reading
        // A Mac without the sensor would run the whole fallback chain, IOHID
        // walk included, for a row the popover then leaves out.
        let needGPUTemp = gpuTempSupported
            && (popoverVisible || selectedMetrics.contains(.gpuTemp))
        var wanted: SystemMonitor.TemperatureSet = []
        if needCPUTemp { wanted.insert(.cpu) }
        if needGPUTemp { wanted.insert(.gpu) }
        let temperatures = wanted

        queue.async { [weak self] in
            guard let self else { return }
            let r = self.monitor.menuSample(includeGPU: needGPU, temperatures: temperatures)
            // A failed startup discovery is retried on this queue. Once sensor
            // availability is known the probe returns its cached result.
            let gpuTempSupported = self.monitor.probeGPUTempAvailable()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.gpuTempSupported != gpuTempSupported {
                    self.gpuTempSupported = gpuTempSupported
                    if !gpuTempSupported, self.selectedMetrics.contains(.gpuTemp) {
                        self.selectedMetrics.removeAll { $0 == .gpuTemp }
                        if self.selectedMetrics.isEmpty { self.selectedMetrics = [.cpuLoad] }
                    }
                }
                var next = self.readings
                next.cpuPercent  = MenuBarReadings.displayed(r.cpu)
                next.memPercent  = MenuBarReadings.displayed(r.memPercent)
                next.memPressure = r.memPressure
                // Leave the previous value untouched when we skipped the read,
                // rather than blanking a metric that just isn't on screen.
                if needGPU { next.gpuPercent = r.gpu.map(MenuBarReadings.displayed) }
                if needCPUTemp { next.cpuTemp = r.cpuTemp.map(MenuBarReadings.displayed) }
                if needGPUTemp { next.gpuTemp = r.gpuTemp.map(MenuBarReadings.displayed) }
                if next != self.readings { self.readings = next }
                let cores = r.perCore.map(MenuBarReadings.displayed)
                if cores != self.perCore { self.perCore = cores }
                self.appendHistory()
                self.sampling    = false
                self.refreshStatusLabel()
                self.popover.show(self.readings)
                // Threshold alerts ride the always-on menu-bar cadence, so they
                // fire even when the main window is closed. They compare the
                // raw reading, not the display-rounded one.
                MonitorAlerts.shared.check(cpu: r.cpu,
                                           cpuTemp: needCPUTemp ? r.cpuTemp : nil,
                                           pressure: r.memPressure)
            }
        }
    }
}

// MARK: - Status-bar label state

/// Everything the status-bar label draws, and nothing else: two states that
/// compare equal draw the same pixels.
///
/// Loads are floored to a whole percent — the figure printed beside every
/// graphic, and about a tenth of a point on graphics 12–13 pt tall — so a
/// reading that moved by less than that does not redraw the label.
public struct MenuBarLabelState: Equatable, Sendable {
    public let style: MenuBarStyle
    /// The columns as drawn, in order; `fraction` already floored.
    public let cells: [MenuBarController.WidgetCell]
    /// The sparkline, oldest first, 0…1. Empty unless the layout is `graph`.
    public let history: [Double]
    /// Per-core loads, 0…100. Empty unless the layout is `cores`.
    public let perCore: [Double]

    static func wholePercent(_ fraction: Double) -> Double {
        (fraction * 100).rounded(.down) / 100
    }
}

/// What the status item observes: it announces a change only when the label
/// would draw something different, and keeps the image it drew last.
///
/// Observing the controller instead would redraw the label, re-measure it and
/// hand the status item a new image on every tick, including the many ticks
/// that leave every drawn figure where it was.
@MainActor
public final class MenuBarStatusLabel: ObservableObject {
    private var drawn: (state: MenuBarLabelState, image: NSImage)?

    /// The label image for `state`, drawn again only if `state` differs from
    /// the last one drawn.
    func image(for state: MenuBarLabelState) -> NSImage {
        if let drawn, drawn.state == state { return drawn.image }
        let image = MenuBarLabelRenderer.image(state)
        drawn = (state, image)
        return image
    }

    /// Redraws the label if what it shows in its current layout has changed.
    /// `state` builds the label for a layout from the controller's values.
    func refresh(_ state: (MenuBarStyle) -> MenuBarLabelState) {
        // Nothing drawn yet: the label's first render builds it anyway.
        guard let drawn else { return }
        if state(drawn.state.style) != drawn.state { objectWillChange.send() }
    }
}

// MARK: - Popover model

/// What the popover observes. It changes only while the popover is open.
///
/// While open it takes each new reading and passes on changes to the metric
/// list and to the Smart Cleanup scan the quick-cleanup item spends; while
/// closed it does neither. On opening it takes the latest reading with
/// animation off, so the popover does not replay the whole gap since it last
/// closed as rolling numbers.
@MainActor
public final class MenuBarPopoverModel: ObservableObject {
    @Published public private(set) var readings = MenuBarReadings()
    private var isVisible = false
    /// Forwards the dashboard's changes while the popover is open. A scan
    /// publishes progress many times a second, and a popover observing the
    /// dashboard directly would redraw itself for each one, open or closed.
    private var dashboardRelay: AnyCancellable?

    func setVisible(_ visible: Bool, latest: MenuBarReadings) {
        isVisible = visible
        guard visible else {
            dashboardRelay = nil
            return
        }
        dashboardRelay = AppState.shared.dashboardViewModel.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        var opening = Transaction()
        opening.disablesAnimations = true
        withTransaction(opening) {
            if readings != latest { readings = latest }
            // The metric list or the scan may have moved while closed.
            objectWillChange.send()
        }
    }

    func show(_ latest: MenuBarReadings) {
        guard isVisible, readings != latest else { return }
        readings = latest
    }

    func configurationChanged() {
        if isVisible { objectWillChange.send() }
    }
}

// MARK: - Menu bar label (status bar)
//
// The label is drawn into an `NSImage` rather than assembled from SwiftUI views.
// That is not a stylistic choice: a composed `HStack { Image; Text }` label is
// rasterized by `MenuBarExtra` into a fixed-size template and can go blank
// when its width shrinks — removing a metric and leaving one behind empties
// the status item. Collapsing everything into a single `Text` avoids that but
// rules out the two stacked layouts. Rendering the whole thing ourselves gives
// exact measurements, one view, and all three layouts.
//
// The image is a template (`isTemplate = true`), so macOS inverts it for light
// and dark menu bars and it stays legible on a wallpaper of any colour.
//
// There is deliberately no app mark in front of the values. A template glyph
// could be drawn for the status bar, but next to two-digit readings it reads as
// noise and costs width the numbers need — and the menu bar already identifies
// the app when you click it.

/// Draws the status-bar label: the pinned metrics, laid out per
/// `MenuBarStyle`.
@MainActor
enum MenuBarLabelRenderer {

    /// Height of the drawn label. The menu bar gives ~22pt; 18 leaves the
    /// breathing room the system's own items use.
    private static let height: CGFloat = 18
    private static let metricGap: CGFloat = 7

    static func image(_ state: MenuBarLabelState) -> NSImage {
        let cells = state.cells
        guard !cells.isEmpty else { return NSImage(size: NSSize(width: 1, height: height)) }

        let widths = cells.map { width(of: $0, in: state) }
        let total = widths.reduce(0, +) + metricGap * CGFloat(cells.count - 1)

        let image = NSImage(size: NSSize(width: max(total, 1), height: height))
        image.lockFocus()
        var x: CGFloat = 0
        for (cell, w) in zip(cells, widths) {
            draw(cell, in: state, atX: x)
            x += w + metricGap
        }
        image.unlockFocus()
        // Every pixel is monochrome by construction, so the system can use the
        // whole thing as a mask and invert it for a light menu bar.
        image.isTemplate = true
        // `MenuBarExtra` hands the image to an `NSStatusBarButton`, which
        // reads this rather than any SwiftUI label; without it VoiceOver
        // announces the status item as "image".
        image.accessibilityDescription = cells.map { "\($0.caption) \($0.value)" }
            .joined(separator: ", ")
        return image
    }

    // MARK: Fonts
    //
    // Computed, not stored: a stored `NSFont` is a mutable global that
    // StrictConcurrency rejects, and AppKit caches font lookups anyway.

    private static var valueFont: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }
    private static var stackTopFont: NSFont { .monospacedDigitSystemFont(ofSize: 9, weight: .regular) }
    private static var stackValueFont: NSFont { .monospacedDigitSystemFont(ofSize: 10, weight: .medium) }
    private static var captionFont: NSFont { .systemFont(ofSize: 11, weight: .medium) }

    private static func attrs(_ font: NSFont, alpha: CGFloat = 1) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(alpha)]
    }

    // MARK: Graphic sizes

    private static let graphSize = NSSize(width: 26, height: 12)
    private static let gaugeSize = NSSize(width: 4, height: 13)
    private static let coreBar: CGFloat = 2
    private static let coreGap: CGFloat = 1.5
    private static let graphicGap: CGFloat = 5

    /// How many cores the bars show. Past a dozen they stop being separable at
    /// 2pt apiece and the label starts eating the menu bar.
    private static let coreLimit = 10

    private static func coresWidth(_ perCore: [Double]) -> CGFloat {
        let n = min(perCore.count, coreLimit)
        guard n > 0 else { return 0 }
        return CGFloat(n) * (coreBar + coreGap) - coreGap
    }

    // MARK: Measure

    private static func width(of cell: MenuBarController.WidgetCell,
                              in state: MenuBarLabelState) -> CGFloat {
        let value = cell.value as NSString
        switch state.style {
        case .value, .inline:
            return ceil(value.size(withAttributes: attrs(valueFont)).width)
        case .dotted:
            return ceil(value.size(withAttributes: attrs(valueFont)).width)
        case .labeled:
            let caption = (cell.caption as NSString).size(withAttributes: attrs(captionFont, alpha: 0.65)).width
            return ceil(caption + 4 + value.size(withAttributes: attrs(valueFont)).width)
        case .stack:
            let top = (cell.top as NSString).size(withAttributes: attrs(stackTopFont, alpha: 0.75)).width
            return ceil(max(top, value.size(withAttributes: attrs(stackValueFont)).width))
        case .graph:
            return ceil(graphSize.width + graphicGap
                        + value.size(withAttributes: attrs(valueFont)).width)
        case .gauge:
            let track = cell.fraction == nil ? 0 : gaugeSize.width + graphicGap
            return ceil(track + value.size(withAttributes: attrs(valueFont)).width)
        case .cores:
            let bars = coresWidth(state.perCore)
            return ceil((bars > 0 ? bars + graphicGap : 0)
                        + value.size(withAttributes: attrs(valueFont)).width)
        }
    }

    // MARK: Draw

    private static func draw(_ cell: MenuBarController.WidgetCell,
                             in state: MenuBarLabelState,
                             atX x: CGFloat) {
        switch state.style {
        case .value, .inline, .dotted:
            // `.dotted`'s separator is already in the value (`labelState`).
            drawValue(cell.value, atX: x)

        case .labeled:
            let a = attrs(captionFont, alpha: 0.65)
            let caption = cell.caption as NSString
            caption.draw(at: NSPoint(x: x, y: baseline(captionFont)), withAttributes: a)
            drawValue(cell.value, atX: x + caption.size(withAttributes: a).width + 4)

        case .stack:
            // Two tiers centred on the strip: the paired temperature (or the
            // caption) above, the reading below.
            let topAttrs = attrs(stackTopFont, alpha: 0.75)
            let valueAttrs = attrs(stackValueFont)
            (cell.top as NSString).draw(at: NSPoint(x: x, y: height / 2 - 0.5),
                                        withAttributes: topAttrs)
            let vh = (cell.value as NSString).size(withAttributes: valueAttrs).height
            (cell.value as NSString).draw(at: NSPoint(x: x, y: height / 2 - vh + 1.5),
                                          withAttributes: valueAttrs)

        case .graph:
            drawGraph(state.history, atX: x)
            drawValue(cell.value, atX: x + graphSize.width + graphicGap)

        case .gauge:
            guard let fraction = cell.fraction else {
                drawValue(cell.value, atX: x)
                return
            }
            drawGauge(fraction, atX: x)
            drawValue(cell.value, atX: x + gaugeSize.width + graphicGap)

        case .cores:
            let bars = coresWidth(state.perCore)
            drawCores(state.perCore, atX: x)
            drawValue(cell.value, atX: x + (bars > 0 ? bars + graphicGap : 0))
        }
    }

    private static func baseline(_ font: NSFont) -> CGFloat {
        (height - font.boundingRectForFont.height) / 2 - font.descender / 2
    }

    private static func drawValue(_ text: String, atX x: CGFloat) {
        let a = attrs(valueFont)
        let s = text as NSString
        s.draw(at: NSPoint(x: x, y: (height - s.size(withAttributes: a).height) / 2),
               withAttributes: a)
    }

    /// Sparkline of the recent load. A single sample has no shape to draw, so it
    /// waits for a second one rather than drawing a flat line that means "idle".
    private static func drawGraph(_ history: [Double], atX x: CGFloat) {
        guard history.count >= 2 else { return }
        let y = (height - graphSize.height) / 2
        let path = NSBezierPath()
        path.lineWidth = 1.2
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        for (i, value) in history.enumerated() {
            let px = x + graphSize.width * CGFloat(i) / CGFloat(history.count - 1)
            let py = y + graphSize.height * CGFloat(max(0, min(1, value)))
            i == 0 ? path.move(to: NSPoint(x: px, y: py)) : path.line(to: NSPoint(x: px, y: py))
        }
        NSColor.black.withAlphaComponent(0.85).set()
        path.stroke()
    }

    private static func drawGauge(_ fraction: Double, atX x: CGFloat) {
        let y = (height - gaugeSize.height) / 2
        let track = NSRect(x: x, y: y, width: gaugeSize.width, height: gaugeSize.height)
        NSColor.black.withAlphaComponent(0.28).set()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        NSColor.black.set()
        let filled = CGFloat(max(0, min(1, fraction))) * gaugeSize.height
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: gaugeSize.width, height: filled),
                     xRadius: 2, yRadius: 2).fill()
    }

    private static func drawCores(_ loads: [Double], atX x: CGFloat) {
        let shown = loads.prefix(coreLimit)
        guard !shown.isEmpty else { return }
        let barHeight: CGFloat = 12
        let y = (height - barHeight) / 2
        for (i, load) in shown.enumerated() {
            let bx = x + CGFloat(i) * (coreBar + coreGap)
            NSColor.black.withAlphaComponent(0.25).set()
            NSBezierPath(roundedRect: NSRect(x: bx, y: y, width: coreBar, height: barHeight),
                         xRadius: 1, yRadius: 1).fill()
            NSColor.black.set()
            let filled = barHeight * CGFloat(max(0, min(1, load / 100)))
            NSBezierPath(roundedRect: NSRect(x: bx, y: y, width: coreBar, height: filled),
                         xRadius: 1, yRadius: 1).fill()
        }
    }
}

public struct MenuBarLabel: View {
    /// Not the controller: this speaks up only when the drawn label changes.
    @ObservedObject private var statusLabel = MenuBarController.shared.statusLabel
    @Environment(\.openWindow) private var openWindow
    /// Settings owns the layout; the status item only reads it.
    @AppStorage(MenuBarStyle.storageKey) private var style: MenuBarStyle = .stack

    public init() {}

    public var body: some View {
        let state = MenuBarController.shared.labelState(style: style)
        let image = statusLabel.image(for: state)
        return Image(nsImage: image)
            .accessibilityLabel(Text(image.accessibilityDescription ?? ""))
            .onReceive(NotificationCenter.default.publisher(for: .cacShowMainWindow)) { _ in
                // Policy flip first, alone in this turn: on macOS 14+
                // activation is cooperative, and activating in the same turn
                // as the flip out of `.accessory` raises the window while the
                // previous app keeps the menu bar.
                NSApp.setActivationPolicy(.regular)
                Task { @MainActor in
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
            }
    }
}

// MARK: - Menu bar popover

public struct MenuBarPopover: View {
    /// The one observed source of readings, metric-list changes and scan
    /// progress; it holds still while the popover is closed. Everything the
    /// controller would publish reaches the popover through it.
    @ObservedObject private var model = MenuBarController.shared.popover
    private var controller: MenuBarController { .shared }
    private var snapshot: MenuBarReadings { model.readings }
    // The popover paints itself from `Palette` instead of borrowing the
    // system material, so it has to observe the theme or a theme switch would
    // leave it in the previous palette until the app restarted.
    @ObservedObject private var themeManager = ThemeManager.shared
    // Quick cleanup spends the Smart Cleanup scan, so the popover reads the same
    // view model the window does — one scan, one number, whichever surface is
    // in front. Read, not observed: `model` forwards its changes while the
    // popover is open.
    private var dashboard: DashboardViewModel { AppState.shared.dashboardViewModel }
    @EnvironmentObject private var loc: Localizer
    @Environment(\.openWindow) private var openWindow
    /// Closes the menu-bar window (the `.window`-style MenuBarExtra popover).
    @Environment(\.dismiss) private var dismiss

    /// "Hot" uses the same limit the user set for temperature alerts, so the
    /// word here and the notification that fires cannot disagree.
    @AppStorage(MonitorAlerts.tempThresholdKey) private var tempThreshold = 85.0

    @State private var popoverVisible = false
    @State private var freeSpace: String?
    @State private var confirmingQuickClean = false
    @State private var pendingQuickClean: DashboardViewModel.CleanupSelection?
    /// Set once a menu-bar cleanup finishes. Toasts render in the main window's
    /// overlay, which is exactly the window that is closed when someone cleans
    /// from here — so the outcome, the failures and the Undo live in the
    /// popover itself.
    @State private var quickCleanResult: QuickCleanNotice?

    private struct QuickCleanNotice {
        var text: String
        var tone: Tone
        /// What an Undo would put back; empty once used or when nothing can be.
        var undoable: [TrashService.Trashed]
        var historyRecord: UUID?
    }
    @State private var showMetricPicker = false

    /// Popover width.
    private let width: CGFloat = 280
    /// Inset of the popover's own rows. Narrower than `Metric.inset`: 22pt each
    /// side of 280 is a sixth of the surface.
    private let inset: CGFloat = 14

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            meters
            readings
            menu
        }
        .frame(width: width)
        .background(Palette.surfaceRaised)
        .overlay(Rectangle().strokeBorder(Palette.borderStrong, lineWidth: 1))
        .task(id: popoverVisible) {
            guard popoverVisible else { return }
            await refreshFreeSpaceWhileVisible()
        }
        // The window says when it is on screen; the view tree does not. A
        // popover closed by `dismiss()` or ordered out never reports
        // `onDisappear`, so the controller went on sampling the GPU and
        // redrawing this hidden view every tick for the rest of the session.
        .onWindowVisibilityChange { visible in
            popoverVisible = visible
            controller.setPopoverVisible(visible)
            guard !visible else { return }
            // Nothing half-finished survives a close: reopening starts from the
            // menu, not from a confirmation the user walked away from.
            confirmingQuickClean = false
            quickCleanResult = nil
            freeSpace = nil
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            Rectangle().fill(Palette.accent).frame(width: 6, height: 6)
            Text(loc.s("app.name")).microLabel(Palette.textSecondary)
            Spacer(minLength: 8)
            // Numbers that move on their own say how often they move.
            Text(loc.s("menubar.tick"))
                .font(Typo.numeric(11, weight: .regular))
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, inset)
        .frame(height: 38)
        .overlay(alignment: .bottom) { hairline(Palette.borderStrong) }
    }

    // MARK: Load metres

    private var meters: some View {
        VStack(spacing: 0) {
            meter(loc.s("monitor.cpu"), percent: snapshot.cpuPercent, tint: Palette.accent)

            // The memory bar carries pressure because pressure is a risk, which
            // is the one thing colour is allowed to say — and the
            // word underneath says it again for anyone the colour doesn't reach.
            meter(loc.s("monitor.ram"),
                  percent: snapshot.memPercent,
                  tint: pressureTone.fill,
                  footnote: (text: loc.f("menubar.pressureFmt", pressureWord),
                             color: pressureTone == .info ? Palette.textTertiary : pressureTone.text))

            if let gpu = snapshot.gpuPercent {
                meter(loc.s("monitor.gpu"), percent: gpu, tint: Palette.accent)
            }
        }
    }

    private func meter(_ label: String, percent: Double, tint: Color,
                       footnote: (text: String, color: Color)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).microLabel()
                Spacer(minLength: 8)
                Text("\(Int(percent.rounded()))%")
                    .font(Typo.numeric(13, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .contentTransition(.numericText())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Palette.borderStrong)
                    Rectangle().fill(tint)
                        .frame(width: geo.size.width * min(max(percent / 100, 0), 1))
                }
            }
            .frame(height: 4)
            if let footnote {
                Text(footnote.text)
                    .font(Typo.numeric(11, weight: .regular))
                    .foregroundStyle(footnote.color)
                    .lineLimit(1)
            }
        }
        .animation(.easeOut(duration: 0.25), value: percent)
        .padding(.horizontal, inset)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { hairline(Palette.borderHairline) }
    }

    private var pressureTone: Tone {
        switch snapshot.memPressure {
        case .normal:   return .info
        case .warning:  return .warning
        case .critical: return .danger
        }
    }

    private var pressureWord: String {
        switch snapshot.memPressure {
        case .normal:   return loc.s("monitor.pressureNormal")
        case .warning:  return loc.s("monitor.pressureWarning")
        case .critical: return loc.s("monitor.pressureCritical")
        }
    }

    // MARK: Sensor readings

    @ViewBuilder
    private var readings: some View {
        // Temperatures are rows rather than side-by-side chips, so each one
        // has room for a status word next to its value.
        if let t = snapshot.cpuTemp {
            readingRow(loc.s(MenuBarMetric.cpuTemp.labelKey),
                       value: celsius(t), status: tempStatus(t))
        }
        if let t = snapshot.gpuTemp {
            readingRow(loc.s(MenuBarMetric.gpuTemp.labelKey),
                       value: celsius(t), status: tempStatus(t))
        }
        readingRow(loc.s("menubar.diskFree"), value: freeSpace ?? "—", status: nil)
    }

    private func readingRow(_ title: String, value: String,
                            status: (word: String, tone: Tone)?) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(Typo.secondary)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(Typo.numeric(12, weight: .regular))
                .foregroundStyle(Palette.textPrimary)
            if let status {
                Text(status.word).riskLabel(status.tone.text)
            }
        }
        .padding(.horizontal, inset)
        .frame(height: 36)
        .overlay(alignment: .bottom) { hairline(Palette.borderHairline) }
    }

    private func celsius(_ value: Double) -> String { "\(Int(value.rounded())) °C" }

    /// A word, not a coloured dot. A small green circle says "fine" only to
    /// someone who can tell it from the orange one.
    private func tempStatus(_ celsius: Double) -> (word: String, tone: Tone) {
        if celsius >= tempThreshold { return (loc.s("menubar.temp.hot"), .danger) }
        if celsius >= tempThreshold - 15 { return (loc.s("menubar.temp.warm"), .warning) }
        return (loc.s("menubar.temp.normal"), .success)
    }

    // MARK: Menu

    private var menu: some View {
        VStack(spacing: 0) {
            PopoverMenuRow(title: loc.s("menubar.open"),
                           inset: inset,
                           accessibility: loc.s("menubar.open")) { openMain() }

            quickCleanup

            hairline(Palette.borderHairline)

            PopoverMenuRow(title: loc.s("menubar.chooseMetrics"),
                           symbol: showMetricPicker ? "chevron.up" : "chevron.down",
                           inset: inset,
                           muted: true,
                           accessibility: loc.s("menubar.chooseMetrics")) {
                withAnimation(Motion.panelReveal) { showMetricPicker.toggle() }
            }

            if showMetricPicker { metricPicker }

            PopoverMenuRow(title: loc.s("menubar.quit"),
                           inset: inset,
                           muted: true,
                           accessibility: loc.s("menubar.quit")) { NSApp.terminate(nil) }
        }
        .padding(.bottom, 6)
        .overlay(alignment: .top) { hairline(Palette.borderStrong) }
    }

    // MARK: Quick cleanup
    //
    // The product's main action, one click from the menu bar. It spends the
    // Smart Cleanup scan and only ever the *safe* half of it: `.trash` is not
    // `isSafeToAutoClean`, so nothing here is erased past the Trash and the
    // consequence line can promise a way back without qualification.

    @ViewBuilder
    private var quickCleanup: some View {
        // Summed once per render: the figure is tested, shown in the row, read
        // out in its accessibility label and printed on the confirm button.
        let bytes = confirmingQuickClean ? (pendingQuickClean?.size ?? 0) : quickCleanBytes
        let formatted = Fmt.bytes(Int64(bytes))

        if let notice = quickCleanResult {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(notice.text)
                    .font(Typo.footnote)
                    .foregroundStyle(notice.tone.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !notice.undoable.isEmpty {
                    Button(loc.s("trash.undo")) { undoQuickClean(notice) }
                        .buttonStyle(SecondaryButtonStyle(height: 24))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .notice(notice.tone)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }

        if dashboard.isCleaning {
            cleaningStrip
        } else if dashboard.isScanning {
            // A cleanup ends with a rescan, and `startScan` drops the result on
            // its way in. Without this branch the item would advertise "no scan
            // yet" for the length of it — seconds after a successful cleanup.
            progressStrip(loc.s("menubar.scanning"),
                          percent: dashboard.scanProgress?.percent ?? 0)
        } else if confirmingQuickClean {
            confirmStrip(formatted)
        } else if bytes > 0 {
            PopoverMenuRow(title: loc.s("menubar.quickClean"),
                           value: formatted,
                           valueTint: Palette.accent,
                           inset: inset,
                           accessibility: loc.f("cleanup.cleanFmt", formatted)) {
                pendingQuickClean = dashboard.prepareCleanup(safeOnly: true)
                confirmingQuickClean = pendingQuickClean != nil
            }
        } else {
            // Never a dead end: with no scan to spend, the row hands the user to
            // the screen that can produce one instead of greying itself out.
            PopoverMenuRow(title: loc.s("menubar.quickClean"),
                           value: "—",
                           detail: loc.s("menubar.quickClean.needsScan"),
                           inset: inset,
                           accessibility: loc.s("menubar.quickClean.needsScan")) {
                openMain(section: .smartCleanup)
            }
        }
    }

    /// An irreversible-looking action states its consequence before it
    /// runs. A `confirmationDialog` cannot be trusted to present from a
    /// menu-bar window, so the confirmation happens in place.
    private func confirmStrip(_ formatted: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc.s("cleanup.consequence.trash"))
                .font(Typo.footnote)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // 280pt is narrow enough that a long localized pair does not fit on
            // one line; the fallback stacks instead of clipping the verb.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    confirmButton(formatted)
                    cancelButton
                }
                VStack(spacing: 6) {
                    confirmButton(formatted).frame(maxWidth: .infinity)
                    cancelButton.frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .notice(.info)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// The volume is in the button, not in a label above it.
    private func confirmButton(_ formatted: String) -> some View {
        Button(loc.f("cleanup.cleanFmt", formatted)) { runQuickClean() }
            .buttonStyle(PrimaryButtonStyle(tint: Palette.dangerFill, height: 28))
    }

    private var cancelButton: some View {
        Button(loc.s("common.cancel")) { confirmingQuickClean = false }
            .buttonStyle(SecondaryButtonStyle(height: 28))
    }

    private var cleaningStrip: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(loc.s("menubar.cleaning"))
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 8)
                Text("\(Int((dashboard.cleaningProgress * 100).rounded()))%")
                    .font(Typo.numeric(12, weight: .regular))
                    .foregroundStyle(Palette.textSecondary)
            }
            ProgressView(value: dashboard.cleaningProgress)
                .progressViewStyle(.linear)
                .tint(Palette.dangerFill)
        }
        .padding(.horizontal, inset)
        .padding(.vertical, 10)
    }

    /// Same shape as a menu item, minus the button: nothing here is clickable
    /// while the work runs, and a row that looks pressable but is not is worse
    /// than one that plainly reports.
    private func progressStrip(_ title: String, percent: Double) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Typo.secondary)
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 8)
            Text("\(Int((percent * 100).rounded()))%")
                .font(Typo.numeric(11, weight: .regular))
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.horizontal, inset)
        .frame(height: 30)
    }

    /// Bytes `selectSafe()` would put in the selection — the same set, so the
    /// figure on the button is the figure that gets deleted.
    private var quickCleanBytes: UInt64 {
        dashboard.cleanableItems.filter(\.autoSelect).reduce(UInt64(0)) { $0 &+ $1.size }
    }

    private func runQuickClean() {
        guard let selection = pendingQuickClean,
              !dashboard.isCleaning, !dashboard.isScanning else { return }
        confirmingQuickClean = false
        pendingQuickClean = nil
        quickCleanResult = nil
        // `cleanupOutcome` is only cleared by the window that shows the result
        // panel. With that window closed it would still hold the previous
        // run's amounts when we read it back below.
        dashboard.cleanupOutcome = nil

        Task {
            // `false` means the reentry guard turned us away (a clean confirmed
            // from the window won the race) — announcing "done" would describe
            // a run that never happened, over a clean still in flight.
            guard await dashboard.cleanSelectedItems(selection: selection) else { return }
            quickCleanResult = notice(for: dashboard.lastCleanReport)
        }
    }

    /// Success only when something was cleaned; failures are counted either
    /// way, because the window that would show their toasts is closed.
    private func notice(for report: DashboardViewModel.CleanReport?) -> QuickCleanNotice {
        guard let report else {
            return QuickCleanNotice(text: loc.s("menubar.cleanNothing"), tone: .info,
                                    undoable: [], historyRecord: nil)
        }
        var lines: [String] = []
        if report.cleanedCount > 0 {
            if report.erasedBytes > 0 || report.trashedBytes > 0 {
                lines.append(quickCleanText(DashboardViewModel.CleanupOutcome(
                    freedBytes: report.erasedBytes, trashedBytes: report.trashedBytes)))
            } else if !report.trashed.isEmpty {
                lines.append(loc.f("trash.movedFmt", report.trashed.count, Fmt.bytes(report.trashedBytes)))
            } else {
                lines.append(loc.s("toast.deleted"))
            }
        }
        if report.failedCount > 0 {
            let key = report.cleanedCount > 0 ? "menubar.cleanFailedFmt" : "menubar.cleanNothingFmt"
            lines.append(loc.f(key, Fmt.plural("plural.objects", report.failedCount)))
        }
        if report.alreadyGoneCount > 0 {
            lines.append(loc.f("cleanup.alreadyGoneFmt", Fmt.plural("plural.objects", report.alreadyGoneCount)))
        }
        let tone: Tone = report.failedCount > 0 ? .warning : (report.cleanedCount > 0 ? .success : .info)
        let text = lines.isEmpty ? loc.s("menubar.cleanNothing") : lines.joined(separator: "\n")
        return QuickCleanNotice(text: text, tone: tone,
                                undoable: report.trashed.filter { !$0.viaFinder },
                                historyRecord: report.historyRecord)
    }

    private func undoQuickClean(_ notice: QuickCleanNotice) {
        let restored = TrashService.restore(notice.undoable, recordingUndoOf: notice.historyRecord)
        quickCleanResult = QuickCleanNotice(
            text: restored > 0 ? loc.f("trash.restoredFmt", restored) : loc.s("trash.nothingRestored"),
            tone: restored > 0 ? .success : .warning, undoable: [], historyRecord: nil)
        if restored > 0 { dashboard.startScan() }
    }

    /// The safe set always goes to the Trash, so the usual text is the
    /// trashed line plus the note that the space is not free yet. The notice
    /// wraps vertically, so the second line is never truncated.
    private func quickCleanText(_ outcome: DashboardViewModel.CleanupOutcome) -> String {
        let freed = Fmt.bytes(Int64(outcome.freedBytes))
        let trashed = Fmt.bytes(Int64(outcome.trashedBytes))
        switch (outcome.freedBytes > 0, outcome.trashedBytes > 0) {
        case (true, false):
            return loc.f("outcome.freedFmt", freed)
        case (false, true):
            return loc.f("outcome.trashedFmt", trashed) + "\n" + loc.s("outcome.trashNote")
        default:
            return loc.f("outcome.bothFmt", freed, trashed) + "\n" + loc.s("outcome.trashNote")
        }
    }

    // MARK: Metric picker
    //
    // This list and the one in Settings both draw the shared `RowCheckbox` at
    // the shared size and say the same thing about a missing sensor; separate
    // copies drift apart in font size, icon frame and indent. The full `ListRow`
    // cannot be used at 280pt: its fixed 86pt actions column plus two 22pt
    // insets would leave the metric name 108pt.

    @ViewBuilder
    private var metricPicker: some View {
        Text(loc.s("menubar.showInBar")).microLabel()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inset)
            .padding(.top, 10)
            .padding(.bottom, 6)

        ForEach(Array(MenuBarMetric.allCases.enumerated()), id: \.element) { index, metric in
            MetricPickerRow(
                title: loc.s(metric.labelKey),
                // An absent sensor explains itself instead of being
                // a checkbox dimmed to 50 % with no reason given.
                detail: controller.isAvailable(metric) ? nil : loc.s("menubar.gpuTempUnavailable"),
                value: snapshot.shortValue(metric),
                isOn: controller.isOn(metric),
                available: controller.isAvailable(metric),
                inset: inset,
                accessibility: loc.f("menubar.toggleFmt", loc.s(metric.labelKey)),
                action: { controller.toggle(metric) }
            )
            .staggeredAppear(index: index)
        }

        // `toggle` silently refuses to unpin the last metric. Saying so is the
        // difference between a rule and a click that does nothing.
        Text(loc.s("menubar.atLeastOne"))
            .font(Typo.footnote)
            .foregroundStyle(Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inset)
            .padding(.vertical, 8)
            .background(Palette.surfaceFooter)
    }

    // MARK: Plumbing

    /// The volume stat is a filesystem syscall that can block on a sleeping
    /// disk, so it stays off the MainActor. The visibility task refreshes on
    /// every open even when SwiftUI keeps the popover's view alive.
    private func refreshFreeSpaceWhileVisible() async {
        while !Task.isCancelled {
            let info = await Task.detached(priority: .utility) { StorageInfo.read() }.value
            guard !Task.isCancelled else { return }
            freeSpace = info?.formattedFree
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
        }
    }

    private func openMain(section: Screen? = nil) {
        // `menubar.open` lands on Storage, the same screen the app opens on.
        AppState.shared.open(section ?? .storage)
        // Policy flip alone in this turn — on macOS 14+ activation is
        // cooperative, and activating in the same turn as the flip out of
        // `.accessory` raises the window while the previous app keeps the
        // menu bar. Activate and open one turn later.
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        dismiss()   // fold the menu-bar popover away
        if #unavailable(macOS 14) {
            // Apple wired `dismiss` up for the window-style MenuBarExtra only
            // in macOS 14 — on Ventura the call is a no-op and the popover
            // hangs over the freshly opened window. Order its host window out
            // by hand.
            NSApp.windows.first { $0.className.contains("MenuBarExtraWindow") }?.orderOut(nil)
        }
    }

    private func hairline(_ color: Color) -> some View {
        Rectangle().fill(color).frame(height: 1)
    }
}

// MARK: - Popover menu row
//
// A menu item is a control, so it is a `Button` with a required accessibility
// label, a hover state and a 30pt hit area. A `Button` with a bare `Label` has
// no hit area beyond the text itself — the click target is whatever the glyph
// and the words happen to cover.

private struct PopoverMenuRow: View {
    let title: String
    /// Right-aligned monospaced figure ("6.2 GB").
    let value: String?
    let valueTint: Color?
    /// Second line — used where the item has to explain what it will do.
    let detail: String?
    /// Trailing SF Symbol, for the disclosure item.
    let symbol: String?
    let inset: CGFloat
    let muted: Bool
    /// Describes what the item does. Required — a menu item is a control.
    let accessibility: String
    let action: () -> Void

    @State private var hovered = false

    init(title: String, value: String? = nil, valueTint: Color? = nil,
         detail: String? = nil, symbol: String? = nil, inset: CGFloat,
         muted: Bool = false, accessibility: String,
         action: @escaping () -> Void) {
        self.title = title
        self.value = value
        self.valueTint = valueTint
        self.detail = detail
        self.symbol = symbol
        self.inset = inset
        self.muted = muted
        self.accessibility = accessibility
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Typo.secondary)
                        .foregroundStyle(muted ? Palette.textSecondary : Palette.textPrimary)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(Typo.footnote)
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(Typo.numeric(11, weight: .regular))
                        .foregroundStyle(valueTint ?? Palette.textSecondary)
                }
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            .padding(.horizontal, inset)
            .frame(height: detail == nil ? 30 : 42)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? Palette.selectedRow : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Motion.rowHover, value: hovered)
        .accessibilityLabel(Text(accessibility))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Metric picker row
//
// The Settings version of this list is a `ListRow`; at 280pt the component's
// fixed columns do not fit, so this row reuses what it can — `RowCheckbox` at
// the shared 20/28pt geometry, the same 13pt/600 title, the same "no sensor"
// line and the same `menubar.toggleFmt` label — with the popover's own 14pt
// inset.

private struct MetricPickerRow: View {
    let title: String
    let detail: String?
    let value: String
    let isOn: Bool
    let available: Bool
    let inset: CGFloat
    let accessibility: String
    let action: () -> Void

    @State private var hovered = false

    init(title: String, detail: String?, value: String, isOn: Bool, available: Bool,
         inset: CGFloat, accessibility: String, action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.value = value
        self.isOn = isOn
        self.available = available
        self.inset = inset
        self.accessibility = accessibility
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RowCheckbox(isOn: isOn, enabled: available)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Typo.bodyStrong)
                        .foregroundStyle(available ? Palette.textPrimary : Palette.textSecondary)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(Typo.footnote)
                            .foregroundStyle(Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Text(value)
                    .font(Typo.numeric(12, weight: .regular))
                    .foregroundStyle(available ? Palette.textSecondary : Palette.textTertiary)
            }
            .padding(.horizontal, inset)
            .padding(.vertical, 6)
            .frame(minHeight: detail == nil ? Metric.nestedRow : Metric.rowDetailed)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .overlay(alignment: .leading) {
                // Selected rows get the 2pt inset stripe, same as every table
                // row in the app.
                if isOn { Rectangle().fill(Palette.accent).frame(width: 2) }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.borderHairline).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .onHover { hovered = $0 }
        .animation(Motion.rowHover, value: hovered)
        .accessibilityLabel(Text(accessibility))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private var background: Color {
        if isOn { return Palette.selectedRow }
        return hovered && available ? Palette.selectedRow : .clear
    }
}
