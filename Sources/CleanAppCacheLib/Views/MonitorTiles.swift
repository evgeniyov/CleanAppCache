import SwiftUI

// MARK: - Monitor pieces: thermal pill, metric card, detail panel
//
// The panel is where the app is strictest about honesty. `SystemSnapshot`
// is the only source of truth: a row prints what the sampler measured, or "—".
//
// Most of the panel's rows are measured — the memory breakdown, thread count,
// task queue, display count, interface and local address, the drive's product
// name, IOPS and the NVMe endurance log all reach the snapshot. Three do not,
// and they keep their dash on purpose:
//
//   • Shared memory (`monitor.detail.sharedMemory`) for the GPU. Unified memory
//     means the pool is the system RAM figure on Apple Silicon and a firmware
//     carve-out on Intel; nothing measures which of the two this Mac is, so the
//     row does not answer.
//   • The "of an estimated N TB" half of the SSD endurance note. No API publishes a
//     TBW rating, and capacity × assumed P/E cycles is arithmetic on a guess.
//     The bar shows the controller's own SSD life figure and the note states
//     what was actually written.
//   • Battery condition in the battery panel — not sampled.
//
// A gauge cannot say "unknown", only "0 %", so a health bar with nothing to draw
// is absent rather than empty (`healthSection`).

// MARK: - Thermal pill

/// 44pt white card in the screen header: a state dot, then CPU / GPU / battery
/// temperatures, each over its own 8pt caption.
struct ThermalPill: View {
    @EnvironmentObject private var loc: Localizer

    let cpu: Double?
    let gpu: Double?
    let battery: Double?
    let thermalState: ProcessInfo.ThermalState

    private var status: ThermalStatus {
        ThermalStatus(cpu: cpu, gpu: gpu, thermalState: thermalState)
    }

    private var stateWord: String { loc.s(status.labelKey).lowercased() }

    var body: some View {
        HStack(spacing: 16) {
            StatusDot(tone: status.tone, size: 7)
            reading(cpu, caption: loc.s("monitor.temp.cpu"))
            reading(gpu, caption: loc.s("monitor.temp.gpu"))
            reading(battery, caption: loc.s("monitor.temp.batt"))
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .card()
        .help(loc.f("monitor.thermal.tooltip", stateWord))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(loc.f("monitor.thermal.tooltip", stateWord)))
    }

    private func reading(_ celsius: Double?, caption: String) -> some View {
        VStack(spacing: 2) {
            Text(celsius.map { Fmt.decimal($0, decimals: 0) + "°" } ?? Fmt.none)
                .font(Typo.numeric(14, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(celsius == nil ? Palette.textTertiary : Palette.textPrimary)
            Text(caption)
                .font(Typo.tempCaption)
                .tracking(0.7)
                .foregroundStyle(Palette.textTertiary)
        }
    }
}

// MARK: - Metric card

/// One of the six cards. Padding `13 15`, a 12pt caption and a 26/600/−1.1
/// figure; the selected card takes an `accent` border and an `accentText`
/// caption. An idle rate reads "—" in `textTertiary`, never "0.0 MB/s".
struct MonitorMetricCard: View {
    let caption: String
    let value: Fmt.Value
    let isSelected: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Text(caption)
                    .font(Typo.secondary)
                    .foregroundStyle(isSelected ? Palette.accentText : Palette.textSecondary)
                    .lineLimit(1)
                Figure(value.number, unit: value.unit,
                       role: Typo.metricFigure,
                       color: isMissing ? Palette.textTertiary : Palette.textPrimary)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered && !isSelected ? Palette.selectedRow : Palette.surfaceRaised)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(Motion.rowHover, value: hovered)
        .background(
            RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                .fill(Palette.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                .strokeBorder(isSelected ? Palette.accent : Palette.borderStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Metric.card, style: .continuous))
        .shadow(color: Shadow.cardColor, radius: Shadow.cardRadius, x: 0, y: Shadow.cardY)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(caption), \(value.joined)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var isMissing: Bool { value.unit == nil && value.number == Fmt.none }
}

// MARK: - Detail panel (262pt)

/// A row of the panel. `value == nil` is the honest "we have no sensor for
/// this" and prints "—"; `muted` prints a real but non-numeric answer ("no
/// sensor", "idle for 4 s") in the same quiet colour.
struct MonitorDetail: Identifiable {
    let label: String
    let value: String?
    var muted: Bool = false
    var id: String { label }
}

struct MonitorDetailPanel: View {
    @EnvironmentObject private var loc: Localizer

    let title: String
    let metric: MonitorMetric
    let snapshot: SystemSnapshot
    let machine: MachineInfo
    let gpuTempSupported: Bool
    /// The external address row: what the echo service answered. nil covers all
    /// three ways there is nothing to show — the switch is off, the lookup has
    /// not run yet, or it failed — and all three print "—".
    let externalAddress: String?
    /// Whether the user turned that lookup on in Settings. It decides the footnote's
    /// wording, and it gates the row a second time: with the switch off nothing
    /// is shown even if an address is still in hand from before it was flipped.
    let externalLookupEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(Typo.cardTitle)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)

            if metric == .cpu, !snapshot.perCorePercent.isEmpty {
                CoreBars(loads: snapshot.perCorePercent, machine: machine)
                divider
            }

            healthSection

            ForEach(rows) { row in
                HStack(spacing: 10) {
                    Text(row.label)
                        .font(Typo.secondary)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(row.value ?? Fmt.none)
                        .font(Typo.numeric(12))
                        .foregroundStyle(row.value == nil || row.muted || row.value == Fmt.none
                                         ? Palette.textTertiary : Palette.textPrimary)
                        .lineLimit(1)
                }
            }

            networkNote

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metric.inset)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var divider: some View {
        Rectangle().fill(Palette.borderHairline).frame(height: 1)
    }

    /// An 11pt footnote sits under the network list, because the external
    /// address is the one row on this screen that is not read from the kernel.
    /// The note says where the address came from while the lookup is on, and
    /// says it is off while it is off — so the "—" above it is never a mystery.
    @ViewBuilder
    private var networkNote: some View {
        if metric == .network {
            Text(loc.s(externalLookupEnabled ? "monitor.detail.extIp.note"
                                             : "monitor.detail.extIp.off"))
                .font(Typo.footnote)
                .foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
                .padding(.top, 3)
        }
    }

    // MARK: Health gauges

    @ViewBuilder
    private var healthSection: some View {
        switch metric {
        case .memory:
            HealthBar(title: loc.s("monitor.detail.memPressure"),
                      value: Fmt.percent(snapshot.memPressurePercent, decimals: 0),
                      fraction: snapshot.memPressurePercent / 100,
                      color: pressureColor)
            divider
        case .battery:
            if let health = snapshot.batteryHealthPercent {
                HealthBar(title: loc.s("monitor.detail.battCapacity"),
                          value: Fmt.percent(health, decimals: 0),
                          fraction: health / 100,
                          color: Palette.warningFill,
                          note: wearNote(health))
                divider
            }
        case .disk:
            // SSD life. The figure is `PERCENTAGE_USED` out of the
            // drive's own NVMe health log, inverted — not an estimate of ours.
            // Hardware with no readable log draws no bar at all: a gauge can
            // only ever say "0 %", which would read as a dead disk.
            if let ssd = snapshot.ssdEndurance {
                HealthBar(title: loc.s("monitor.detail.ssdLife"),
                          value: Fmt.percent(ssd.remainingPercent, decimals: 0),
                          fraction: ssd.remainingPercent / 100,
                          color: enduranceColor(ssd),
                          note: enduranceNote(ssd))
                divider
            }
        default:
            EmptyView()
        }
    }

    private var pressureColor: Color {
        switch snapshot.memPressure {
        case .normal:   return Palette.successFill
        case .warning:  return Palette.warningFill
        case .critical: return Palette.dangerFill
        }
    }

    private func wearNote(_ health: Double) -> String? {
        guard let cycles = snapshot.batteryCycleCount, health < 100 else { return nil }
        return loc.f("monitor.batteryWearFmt",
                     Fmt.percent(100 - health, decimals: 0),
                     Fmt.plural("plural.cycles", cycles))
    }

    /// A colour, not a measurement. The controller's own critical-warning bit is
    /// the only "this drive is in trouble" signal there is; the amber step below
    /// a fifth of rated life left is a reading aid for the bar beside the
    /// number, and the number itself is always the drive's own.
    private func enduranceColor(_ ssd: SSDEndurance) -> Color {
        guard ssd.isHealthy else { return Palette.dangerFill }
        return ssd.remainingPercent >= 20 ? Palette.successFill : Palette.warningFill
    }

    /// The full form of this note would be "84 TB written of an estimated
    /// 2200 TB". The first
    /// half is measured — "Data Units Written" from the health log. The second
    /// is not: no API publishes a TBW rating, and capacity × assumed P/E cycles
    /// would be arithmetic on a guess printed as a spec. So the note stops after
    /// what the drive reported, and the verdict clause goes with the denominator
    /// it depended on.
    private func enduranceNote(_ ssd: SSDEndurance) -> String? {
        guard ssd.bytesWritten > 0 else { return nil }
        return loc.f("monitor.detail.ssdWrittenFmt", Fmt.bytes(ssd.bytesWritten))
    }

    // MARK: Rows

    private var rows: [MonitorDetail] {
        switch metric {
        case .cpu:     return cpuRows
        case .memory:  return memoryRows
        case .gpu:     return gpuRows
        case .network: return networkRows
        case .disk:    return diskRows
        case .battery: return batteryRows
        }
    }

    private var cpuRows: [MonitorDetail] {
        [
            MonitorDetail(label: loc.s("monitor.freqP"), value: snapshot.freqPCluster.map(megahertz)),
            MonitorDetail(label: loc.s("monitor.freqE"), value: snapshot.freqECluster.map(megahertz)),
            MonitorDetail(label: loc.s(snapshot.tempOrigin.cpu == .smc
                                      ? "monitor.detail.temperatureAverage" : "monitor.detail.temperature"),
                          value: snapshot.tempCPU.map(celsius)),
            MonitorDetail(label: loc.s("monitor.detail.taskQueue"), value: taskQueue),
            MonitorDetail(label: loc.s("monitor.detail.threads"),
                          value: snapshot.threadCount.map { Fmt.count($0) }),
        ]
    }

    /// Task queue — "2.1 of 12 cores": the 1-minute load average
    /// measured against the cores it is queued for. Both halves have to be real;
    /// a load average with no core count beside it does not say how loaded the
    /// machine is, so the row waits rather than half-answering.
    private var taskQueue: String? {
        guard let load = snapshot.loadAverage1m, machine.totalCores > 0 else { return nil }
        return loc.f("monitor.detail.taskQueueFmt",
                     Fmt.decimal(load, decimals: 1), Fmt.plural("plural.cores", machine.totalCores))
    }

    /// The four shares are parts of the same `vm_statistics64` call that
    /// produces `memUsedBytes` — app + wired + compressed sums to it exactly,
    /// and the file cache is the reclaimable remainder it excludes. They are
    /// Activity Monitor's own definitions, not a second opinion on the total.
    private var memoryRows: [MonitorDetail] {
        [
            MonitorDetail(label: loc.s("monitor.detail.appMemory"), value: volume(snapshot.memAppBytes)),
            MonitorDetail(label: loc.s("monitor.detail.fileCache"), value: volume(snapshot.memFileCacheBytes)),
            MonitorDetail(label: loc.s("monitor.detail.wired"), value: volume(snapshot.memWiredBytes)),
            MonitorDetail(label: loc.s("monitor.detail.compressed"), value: volume(snapshot.memCompressedBytes)),
            MonitorDetail(label: loc.s("monitor.detail.swap"), value: volume(snapshot.swapUsedBytes)),
        ]
    }

    /// A zero measurement reads as "—", never "0 B" — including an empty swap file.
    private func volume(_ bytes: UInt64) -> String? {
        bytes > 0 ? Fmt.bytes(bytes) : nil
    }

    private var gpuRows: [MonitorDetail] {
        [
            MonitorDetail(label: loc.s("monitor.detail.load"),
                          value: snapshot.gpuPercent.map { Fmt.percent($0, decimals: 0) }),
            MonitorDetail(label: loc.s("monitor.detail.frequency"), value: snapshot.freqGPU.map(megahertz)),
            // "No sensor" is a fact about the chip; "—" would read as a value
            // that has not arrived yet and never will.
            MonitorDetail(label: loc.s("monitor.detail.temperature"),
                          value: gpuTempSupported ? snapshot.tempGPU.map(celsius) : loc.s("monitor.noSensor"),
                          muted: !gpuTempSupported),
            // Shared memory has no measurement behind it. On Apple Silicon the
            // GPU shares the whole system pool, on Intel it gets a firmware
            // carve-out — and nothing here reads which of the two this Mac is,
            // so printing `memTotalBytes` would be a claim, not a reading.
            MonitorDetail(label: loc.s("monitor.detail.sharedMemory"), value: nil),
            MonitorDetail(label: loc.s("monitor.detail.displays"),
                          value: snapshot.displayCount.map { Fmt.count($0) }),
        ]
    }

    /// The interface named here is the one whose bytes the two rate rows are
    /// showing: `SystemMonitor` picks the physical link carrying the default
    /// route, and it sums only physical links. A VPN's tunnel address in
    /// the local address row would not match the throughput above it.
    private var networkRows: [MonitorDetail] {
        var list = [
            MonitorDetail(label: loc.s("monitor.detail.receive"),
                          value: Fmt.speedString(snapshot.netDownBytesPerSec)),
            MonitorDetail(label: loc.s("monitor.detail.transmit"),
                          value: Fmt.speedString(snapshot.netUpBytesPerSec)),
            // macOS's own name for the link ("Wi-Fi"); tunnels and bridges have
            // none, and then the BSD name is the only true answer there is.
            MonitorDetail(label: loc.s("monitor.detail.interface"),
                          value: snapshot.netInterfaceName ?? snapshot.netInterfaceBSDName),
            MonitorDetail(label: loc.s("monitor.detail.localIp"),
                          value: snapshot.netLocalAddress),
            MonitorDetail(label: loc.s("monitor.detail.extIp"),
                          value: externalLookupEnabled ? externalAddress : nil),
        ]
        // While the link is idle the session total gives way to how long it
        // has been quiet. The clock is the sampler's — it counts from the last
        // tick that actually carried bytes — so a sub-second gap between two
        // samples is not dressed up as "idle for 0 s".
        if let idle = snapshot.netIdleSeconds, idle >= 1 {
            list.append(MonitorDetail(label: loc.s("monitor.idle"),
                                      value: loc.f("monitor.idleFmt", Int(idle.rounded())),
                                      muted: true))
        } else {
            // One figure here, so it is both directions together — the
            // receive and transmit rows above already split them by direction.
            list.append(MonitorDetail(
                label: loc.s("monitor.detail.session"),
                value: volume(snapshot.netSessionDownBytes &+ snapshot.netSessionUpBytes)))
        }
        return list
    }

    private var diskRows: [MonitorDetail] {
        [
            MonitorDetail(label: loc.s("monitor.detail.read"),
                          value: Fmt.speedString(snapshot.diskReadBytesPerSec)),
            MonitorDetail(label: loc.s("monitor.detail.write"),
                          value: Fmt.speedString(snapshot.diskWriteBytesPerSec)),
            MonitorDetail(label: loc.s("monitor.detail.ops"), value: diskOps),
            MonitorDetail(label: loc.s("monitor.detail.device"), value: snapshot.storageDeviceName),
            // SMART status. The verdict is the controller's own
            // critical-warning bitfield, not a rule of ours layered on top of it.
            MonitorDetail(label: loc.s("monitor.detail.smart"),
                          value: snapshot.ssdEndurance.map {
                              loc.s($0.isHealthy ? "monitor.smart.ok" : "monitor.smart.warning")
                          }),
        ]
    }

    /// Operations per second — read+write completions per second, from the same
    /// cumulative IOKit counters as the byte rates. Below one per second the
    /// drive is idle, and idle reads as "—" rather than "0".
    private var diskOps: String? {
        snapshot.diskOpsPerSec >= 1 ? Fmt.count(Int(snapshot.diskOpsPerSec.rounded())) : nil
    }

    private var batteryRows: [MonitorDetail] {
        [
            MonitorDetail(label: loc.s("monitor.detail.charge"),
                          value: snapshot.batteryPercent.map { Fmt.percent($0, decimals: 0) }),
            MonitorDetail(label: loc.s("monitor.detail.cycles"),
                          value: snapshot.batteryCycleCount.map { Fmt.count($0) }),
            MonitorDetail(label: loc.s("monitor.detail.power"), value: powerSource),
            MonitorDetail(label: loc.s("monitor.detail.temperature"), value: snapshot.tempBattery.map(celsius)),
            // Full-charge capacity — the present full-charge capacity the
            // battery itself reports, the numerator of the health figure above.
            MonitorDetail(label: loc.s("monitor.detail.capacity"),
                          value: snapshot.batteryCapacityMAh.map(milliampHours)),
        ]
    }

    /// Power source — "Power adapter, 96 W".
    ///
    /// The wattage is read from the attached adapter, so its presence *is* the
    /// answer to "is this Mac on mains?" — `batteryCharging` is not: it is false
    /// on a full battery that is still plugged in. Without an adapter the row
    /// names the source alone rather than inventing a figure for it.
    private var powerSource: String? {
        if let watts = snapshot.powerAdapterWatts {
            return loc.f("monitor.power.adapterWattsFmt", Fmt.count(watts))
        }
        guard let charging = snapshot.batteryCharging else { return nil }
        return charging ? loc.s("monitor.power.adapter") : loc.s("monitor.power.battery")
    }

    private func megahertz(_ value: Double) -> String {
        "\(Fmt.decimal(value, decimals: 0)) \(loc.s("monitor.mhz"))"
    }

    private func milliampHours(_ value: Int) -> String {
        "\(Fmt.count(value)) \(loc.s("monitor.mah"))"
    }

    private func celsius(_ value: Double) -> String {
        "\(Fmt.decimal(value, decimals: 0)) °C"
    }
}
