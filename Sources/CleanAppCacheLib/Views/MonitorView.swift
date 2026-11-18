import SwiftUI
import Foundation
import Darwin

// MARK: - Monitor
//
// Four tiers, all of them fixed in place: the thermal pill in the screen header,
// six metric cards, a chart beside a 262pt detail panel, and the process table
// taking whatever height is left.
//
// Selection only changes what the chart and the panel say — nothing moves.
// Inserting the chart between the tiles and the process list on selection would
// shove the list off screen.

/// Which metric the chart and the panel are showing.
enum MonitorMetric: String, CaseIterable, Identifiable {
    case cpu, memory, gpu, network, disk, battery
    var id: String { rawValue }
}

/// The chart window (1 minute / 10 minutes / 1 hour).
enum ChartRange: String, CaseIterable, Identifiable {
    case minute, tenMinutes, hour
    var id: String { rawValue }

    var seconds: Double {
        switch self {
        case .minute:      return 60
        case .tenMinutes:  return 600
        case .hour:        return 3600
        }
    }

    var titleKey: String {
        switch self {
        case .minute:      return "monitor.range.1m"
        case .tenMinutes:  return "monitor.range.10m"
        case .hour:        return "monitor.range.1h"
        }
    }
}

public struct MonitorView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var viewModel: MonitorViewModel

    @State private var metric: MonitorMetric = .cpu
    @State private var range: ChartRange = .tenMinutes
    @State private var procQuery = ""
    @State private var procSortByMemory = false
    @State private var expanded: Set<String> = []
    @State private var killTarget: ProcessInfoItem?

    /// The "external address" row. Off until turned on in Settings, so a fresh
    /// install makes no request at all — see `ExternalIPLookup`.
    @AppStorage(ExternalIPLookup.storageKey) private var externalIPEnabled = false
    @StateObject private var externalIP = ExternalIPProbe()

    /// Settings owns this preference; the Monitor only reads it (40pt rows,
    /// 32 in compact density). The key comes from `TableDensity` rather than a
    /// string literal — a key spelled by hand here could drift from the one
    /// Settings writes, and the density segments would do nothing.
    @AppStorage(TableDensity.storageKey) private var density: TableDensity = .regular

    /// `MonitorViewModel` samples every two seconds, so one history point is two
    /// seconds. Both the chart windows and the "idle for N s" line count points.
    private static let sampleInterval: Double = 2

    public init() {}

    public var body: some View {
        ScreenBody {
            ScreenHeader(title: loc.s("monitor.title"), subtitle: subtitle) {
                if let snap = viewModel.snapshot {
                    ThermalPill(cpu: snap.tempCPU,
                                gpu: snap.tempGPU,
                                battery: snap.tempBattery,
                                thermalState: viewModel.thermalState)
                }
            }
            content
        }
        .background(Palette.background)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        // Leaving the screen stops the sampler; so does a window nobody can
        // see — minimized, hidden with the app, or covered by another window.
        .onWindowVisibilityChange { [viewModel] visible in viewModel.setVisible(visible) }
        // The app's one outbound request, driven entirely by this id: it fires
        // when the id becomes `.fetch(...)` — the switch on, the network panel
        // chosen, an interface known — and again only when that identity
        // changes. Never on the 2 s sampler, never at launch.
        .task(id: externalIPRequest) { [request = externalIPRequest, probe = externalIP] in
            await probe.refresh(request)
        }
        .confirmationDialog(
            killTarget.map { loc.f("monitor.killConfirmFmt", $0.name) } ?? "",
            isPresented: Binding(get: { killTarget != nil }, set: { if !$0 { killTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button(loc.s("monitor.killAction"), role: .destructive) {
                if let target = killTarget {
                    Task {
                        switch await SystemMonitor.shared.terminate(pid: target.id) {
                        case .exited:
                            ToastCenter.shared.success(loc.f("monitor.killedFmt", target.name))
                        case .stillRunning:
                            ToastCenter.shared.show(Toast(style: .info,
                                                          title: loc.f("monitor.killPendingFmt", target.name),
                                                          message: loc.s("monitor.killPendingHint")))
                        case .refused:
                            ToastCenter.shared.error(loc.f("monitor.killFailedFmt", target.name))
                        }
                    }
                }
                killTarget = nil
            }
            Button(loc.s("common.cancel"), role: .cancel) { killTarget = nil }
        }
    }

    // MARK: Header

    /// "Apple M2 Pro · 12 cores: 8 performance + 4 efficiency ·
    /// up 4 days". Each part is dropped when the machine does not report it.
    private var subtitle: String? {
        let info = viewModel.machineInfo
        var parts = [info.chip]
        if info.perfCores > 0, info.effCores > 0 {
            parts.append(loc.f("monitor.subtitle.coresFmt",
                               Fmt.plural("plural.cores", info.totalCores),
                               info.perfCores, info.effCores))
        } else if info.totalCores > 0 {
            parts.append(Fmt.plural("plural.cores", info.totalCores))
        }
        if let uptime { parts.append(uptime) }
        return parts.joined(separator: " · ")
    }

    /// Whole days, or whole hours below a day. Under an hour there is nothing
    /// honest to round to, so the fact is dropped instead of saying "1 hour".
    private var uptime: String? {
        guard let seconds = viewModel.snapshot?.uptimeSeconds, seconds >= 3600 else { return nil }
        let hours = Int(seconds / 3600)
        let value = hours >= 24
            ? Fmt.plural("plural.days", hours / 24)
            : Fmt.plural("plural.hours", hours)
        return loc.f("monitor.uptimeFmt", value)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let snap = viewModel.snapshot {
            cards(snap)
            chartAndPanel(snap)
            ProcessTable(groups: viewModel.processGroups,
                         query: $procQuery,
                         sortByMemory: $procSortByMemory,
                         expanded: $expanded,
                         rowHeight: rowHeight,
                         onKill: { killTarget = $0 })
        } else {
            StateView(.scanning(percent: 0,
                                category: loc.s("monitor.starting"),
                                path: "", cancel: nil))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var rowHeight: CGFloat { density.rowHeight }

    // MARK: Six metric cards

    private func cards(_ snap: SystemSnapshot) -> some View {
        HStack(spacing: Metric.cardGap) {
            ForEach(MonitorMetric.allCases) { item in
                MonitorMetricCard(caption: caption(item),
                                  value: value(item, snap),
                                  isSelected: metric == item) {
                    withAnimation(Motion.content) { metric = item }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ item: MonitorMetric) -> String {
        switch item {
        case .cpu:     return loc.s("monitor.cpu")
        case .memory:  return loc.s("monitor.ram")
        case .gpu:     return loc.s("monitor.gpu")
        case .network: return loc.s("monitor.network")
        case .disk:    return loc.s("monitor.disk")
        case .battery: return loc.s("monitor.battery")
        }
    }

    /// Every card goes through `Fmt`, so an idle link reads "—" rather than
    /// "0.0 MB/s" and a machine without a battery reads "—" rather than "0 %".
    private func value(_ item: MonitorMetric, _ snap: SystemSnapshot) -> Fmt.Value {
        switch item {
        case .cpu:
            return Fmt.percentValue(snap.cpuPercent, decimals: 0)
        case .memory:
            return Fmt.size(snap.memUsedBytes)
        case .gpu:
            return snap.gpuPercent.map { Fmt.percentValue($0, decimals: 0) } ?? Self.missing
        case .network:
            return Fmt.speed(snap.netDownBytesPerSec)
        case .disk:
            return Fmt.speed(snap.diskReadBytesPerSec + snap.diskWriteBytesPerSec)
        case .battery:
            return snap.batteryPercent.map { Fmt.percentValue($0, decimals: 0) } ?? Self.missing
        }
    }

    private static let missing = Fmt.Value(number: Fmt.none, unit: nil)

    // MARK: Chart + 262pt panel

    private func chartAndPanel(_ snap: SystemSnapshot) -> some View {
        HStack(alignment: .top, spacing: Metric.cardGap) {
            MonitorChart(title: chartTitle(snap),
                         values: series,
                         maxValue: chartCeiling,
                         axisPast: axisPast,
                         range: $range)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()

            MonitorDetailPanel(title: panelTitle,
                               metric: metric,
                               snapshot: snap,
                               machine: viewModel.machineInfo,
                               gpuTempSupported: viewModel.gpuTempSupported,
                               externalAddress: externalIP.address,
                               externalLookupEnabled: externalIPEnabled)
                .frame(width: 262)
                .frame(maxHeight: .infinity)
                .card()
        }
        // Both cards take the height of the taller one; the row itself is as
        // tall as its content, so the process table keeps the remaining space.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Only the CPU panel has its own name (`monitor.detail.cores`); the rest are
    /// titled by their metric.
    private var panelTitle: String {
        metric == .cpu ? loc.s("monitor.detail.cores") : caption(metric)
    }

    private func chartTitle(_ snap: SystemSnapshot) -> String {
        loc.f("monitor.chart.titleFmt", caption(metric), chartUnit(snap))
    }

    /// What the y-axis is measured in. Network and disk name the direction they
    /// plot, because the sampler keeps one history for each.
    private func chartUnit(_ snap: SystemSnapshot) -> String {
        switch metric {
        case .cpu, .gpu, .battery:
            return "%"
        case .memory:
            return "% " + loc.f("monitor.ofTotal", Fmt.bytes(snap.memTotalBytes))
        case .network:
            return loc.s("monitor.detail.receive").lowercased()
        case .disk:
            return loc.s("monitor.detail.readWrite").lowercased()
        }
    }

    /// The window the chart draws. Battery has no history — the sampler records
    /// none — so it draws guides and no line rather than a fabricated curve.
    private var series: [Double] {
        let history: [Double]
        switch metric {
        case .cpu:     history = viewModel.cpuHistory
        case .memory:  history = viewModel.memHistory
        case .gpu:     history = viewModel.gpuHistory
        case .network: history = viewModel.netDownHistory
        case .disk:    history = viewModel.diskHistory
        case .battery: history = []
        }
        return Array(history.suffix(Int(range.seconds / Self.sampleInterval)))
    }

    private var chartCeiling: Double? {
        switch metric {
        case .cpu, .memory, .gpu, .battery: return 100
        case .network, .disk:               return nil
        }
    }

    /// The left axis states the span actually on screen. The sampler keeps ten
    /// minutes of history, so the 1-hour range shows every point it has and says so instead
    /// of stretching ten minutes across a label that claims an hour.
    private var axisPast: String {
        let seconds = Double(max(0, series.count - 1)) * Self.sampleInterval
        guard seconds >= 60 else { return "" }
        return loc.f("monitor.axis.spanFmt", Fmt.count(Int(seconds / 60)))
    }

    // The network panel's idle clock is not derived here from history points
    // below 1 B/s. The sampler times it directly, from the last tick that
    // actually carried bytes, so the panel reads `snapshot.netIdleSeconds`
    // rather than re-deriving a coarser version of it.

    // MARK: External address

    /// What the probe should do right now. Everything that decides whether the
    /// request may happen is folded into this one value, so `.task(id:)` is the
    /// only place that can start it.
    private var externalIPRequest: ExternalIPRequest {
        // The switch is the first gate: off means the app does not ask, and does
        // not go on showing an answer from when it did.
        guard externalIPEnabled else { return .off }
        guard metric == .network, let snap = viewModel.snapshot else { return .idle }
        // The identity of "this network": the link carrying the default route
        // and the address it gave us. The answer is refreshed when the network
        // changes, and this pair changing *is* the network changing.
        let identity = [snap.netInterfaceBSDName, snap.netLocalAddress].compactMap { $0 }
        // No default route at all — nothing to ask, and nothing to re-check an
        // old answer against. The row goes back to "—" rather than keeping the
        // address this Mac had on a network it has left.
        guard !identity.isEmpty else { return .off }
        return .fetch(identity.joined(separator: "/"))
    }
}

// MARK: - External address probe

/// What `ExternalIPProbe` is being asked for, and the `.task(id:)` key that
/// decides it. Three states, not a `String?`, because "the switch is off" and
/// "the panel is elsewhere" have to mean different things: the first forgets
/// the answer, the second keeps it.
private enum ExternalIPRequest: Equatable {
    /// The switch is off, or there is no network to ask about. Either way,
    /// forget anything already learned.
    case off
    /// On, but the network panel is not the one on screen. Keep what we already
    /// know — coming back to the panel is not a network change — and ask nothing.
    case idle
    /// On, visible, and this is the network to resolve.
    case fetch(String)
}

/// The "external address" row — the app's ONE outbound request.
///
/// Every other figure on this screen is read from the kernel. This row asks the
/// outside world "what address do you see me at?", which is the one fact no
/// local API can know — so it has an off switch in Settings and this class
/// exists to keep that promise narrow: it runs only when the switch is on and
/// the network panel is on screen, it caches the answer against the interface
/// identity so sitting on the panel does not repeat the request, and it returns
/// nil — "—" on screen — for every kind of failure.
@MainActor
private final class ExternalIPProbe: ObservableObject {
    /// The address the service reported. nil means "not asked, or asking did
    /// not produce an address" — shown as a dash, never a plausible-looking guess.
    @Published private(set) var address: String?

    /// The network identity `address` was resolved for.
    private var resolvedKey: String?

    /// A plain IP echo over HTTPS: no query string, no JSON, no SDK — the whole
    /// response body is the address. HTTPS so that what comes back cannot be
    /// rewritten by whatever sits between this Mac and the service.
    private static let endpoint = URL(string: "https://api.ipify.org")!

    /// Ephemeral by construction: no cookie jar, no disk cache, no credential
    /// store. The request carries nothing about this Mac beyond the connection
    /// it has to open, and leaves nothing behind on disk.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// `nonisolated` so a `@StateObject` initialiser in a view body can build it
    /// without hopping actors; nothing is touched here.
    nonisolated init() {}

    func refresh(_ request: ExternalIPRequest) async {
        switch request {
        case .off:
            // The user took the switch away, so the app forgets the answer too:
            // the row goes back to "—" instead of showing a value it is not
            // allowed to re-check.
            address = nil
            resolvedKey = nil

        case .idle:
            break

        case .fetch(let key):
            // Same network, already answered — the answer is refreshed on a
            // network change, not on every visit to the panel.
            if key == resolvedKey, address != nil { return }
            // A different network: the cached address is wrong now, not merely stale.
            if key != resolvedKey { address = nil }

            let found = await Self.lookup()
            // Cancelled — the panel closed or the network changed underneath.
            // Leave the state as it was rather than recording an answer nobody
            // asked for any more.
            guard !Task.isCancelled else { return }
            resolvedKey = key
            address = found
        }
    }

    /// One GET, nothing else. Any failure — offline, timeout, an HTTP error, a
    /// body that is not an address — returns nil, which the panel prints as "—".
    private static func lookup() async -> String? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let body = String(data: data, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  isIPLiteral(body)
            else { return nil }
            return body
        } catch {
            return nil
        }
    }

    /// A captive portal answers any request with its own page, and a service can
    /// change what it returns. The body is accepted only when it really parses
    /// as an address — anything else is a failed lookup, not a value to print.
    private static func isIPLiteral(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 45 else { return false }   // INET6_ADDRSTRLEN
        var v4 = in_addr()
        if text.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return true }
        var v6 = in6_addr()
        return text.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1
    }
}
