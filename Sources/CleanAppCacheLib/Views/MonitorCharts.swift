import SwiftUI

// MARK: - Monitor chart and core bars
//
// One line chart, one strip of per-core bars. Both draw only what the sampler
// actually recorded: an empty history draws guides and nothing else rather than
// a flat line at zero, which would read as "the machine is idle".

// MARK: - Sparkline shape

/// The plotted series. `maxValue` fixes the ceiling for percentage metrics so
/// the line does not rescale itself every time the peak moves; passing nil
/// scales to the window's own maximum (bytes per second).
struct Sparkline: Shape {
    let values: [Double]
    var maxValue: Double?
    var filled: Bool = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }

        let ceiling = max(maxValue ?? (values.max() ?? 1), 0.0001)
        let stepX = rect.width / CGFloat(values.count - 1)

        func point(_ i: Int) -> CGPoint {
            let x = rect.minX + CGFloat(i) * stepX
            let norm = min(max(values[i] / ceiling, 0), 1)
            return CGPoint(x: x, y: rect.maxY - CGFloat(norm) * rect.height)
        }

        if filled {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: point(0))
        } else {
            path.move(to: point(0))
        }
        for i in 1..<values.count { path.addLine(to: point(i)) }
        if filled {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Chart card

/// Title, the 1m/10m/1h segments, a 78pt plot with guides at 25/50/75 %, and the
/// two axis captions. The card around it is applied by the caller.
struct MonitorChart: View {
    @EnvironmentObject private var loc: Localizer

    let title: String
    let values: [Double]
    /// Ceiling for percentage metrics; nil auto-scales the window.
    let maxValue: Double?
    /// Left-hand axis caption — the span actually plotted, not the span asked for.
    let axisPast: String
    @Binding var range: ChartRange

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(title)
                    .font(Typo.cardTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                // No pinned width: at 132pt each of the three segments gets 22pt
                // for its label, and the 10-minute label truncates to "1…". The control sizes to
                // its own content.
                SegmentedControl(selection: $range,
                                 options: ChartRange.allCases.map {
                                     SegmentOption(value: $0, label: loc.s($0.titleKey))
                                 })
            }

            plot.frame(minHeight: 78, maxHeight: .infinity)

            HStack(spacing: 8) {
                Text(axisPast)
                    .font(Typo.footnote)
                    .foregroundStyle(Palette.textTertiary)
                Spacer(minLength: 8)
                Text(loc.s("monitor.axisNow"))
                    .font(Typo.footnote)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.horizontal, Metric.inset)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The plot itself is shapes; without a value VoiceOver reads the title
        // and the range control and nothing for the line. The latest point is what a sighted
        // reader takes from it.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(latestText))
    }

    /// A ceiling means a percentage series; without one the history is a
    /// byte rate (network, disk).
    private var latestText: String {
        guard let last = values.last else { return Fmt.none }
        return maxValue == nil ? Fmt.speedString(last) : Fmt.percent(last, decimals: 0)
    }

    private var plot: some View {
        ZStack {
            GeometryReader { geo in
                ForEach([0.25, 0.5, 0.75], id: \.self) { fraction in
                    Path { p in
                        let y = geo.size.height * (1 - fraction)
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Palette.borderHairline, lineWidth: 1)
                }
            }
            Sparkline(values: values, maxValue: maxValue, filled: true)
                .fill(Palette.accent.opacity(0.09))
            Sparkline(values: values, maxValue: maxValue)
                .stroke(Palette.accent,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .animation(Motion.content, value: values)
    }
}

// MARK: - Per-core bars

/// One bar per logical core, 50pt tall, E-cores in `accentBarLight` and P-cores
/// in `accent` with a wider gap where the cluster changes.
struct CoreBars: View {
    @EnvironmentObject private var loc: Localizer

    let loads: [Double]
    let machine: MachineInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(loads.enumerated()), id: \.offset) { index, load in
                    if index > 0, isEfficiency(index) != isEfficiency(index - 1) {
                        Spacer().frame(width: 6)
                    }
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(isEfficiency(index) ? Palette.accentBarLight : Palette.accent)
                        .frame(height: max(2, 50 * min(max(load, 0), 100) / 100))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 50, alignment: .bottom)
            .animation(Motion.content, value: loads)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(loc.s("monitor.coresLabel")))
            .accessibilityValue(Text(loads.map { Fmt.percent($0, decimals: 0) }
                                        .joined(separator: ", ")))

            if machine.effCores > 0, machine.perfCores > 0 {
                Text(loc.f("monitor.detail.coreSplitFmt", machine.effCores, machine.perfCores))
                    .font(Typo.footnote)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }

    /// The device-tree cluster map is authoritative; the "E-cores come first"
    /// ordering is only a fallback for chips that publish no map.
    private func isEfficiency(_ index: Int) -> Bool {
        if let map = machine.clusterMap, index < map.count { return map[index] == "E" }
        // Ultra cores are numbered per die (die0-E, die0-P, die1-E, die1-P),
        // so "first effCores indices are E" would paint P cores as E and vice
        // versa. If even the synthesized Ultra map was refused, uniform bars
        // beat a wrong split.
        if machine.chip.contains("Ultra") { return false }
        return machine.effCores > 0 && index < machine.effCores
    }
}
