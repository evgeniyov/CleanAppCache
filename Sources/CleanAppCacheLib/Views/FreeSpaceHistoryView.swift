import Charts
import SwiftUI

struct FreeSpaceHistoryView: View {
    @EnvironmentObject private var loc: Localizer
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var history = FreeSpaceHistory.shared
    @ObservedObject private var cleanups = CleanupHistory.shared
    @State private var days = 7

    var body: some View {
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let samples = history.samples.filter { $0.date >= start && $0.date <= now }.sorted { $0.date < $1.date }
        let events = cleanups.records.filter { $0.date >= start && $0.date <= now }

        ScreenBody {
            ScreenHeader(title: loc.s("storage.trend.title"), subtitle: loc.s("storage.trend.subtitle")) {
                SegmentedControl(selection: $days, options: [
                    SegmentOption(value: 7, label: loc.s("storage.trend.week")),
                    SegmentOption(value: 30, label: loc.s("storage.trend.month"))
                ])
                .fixedSize()
                IconButton("xmark", label: loc.s("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: 12) {
                Chart {
                    ForEach(samples) { sample in
                        LineMark(x: .value(loc.s("storage.trend.date"), sample.date),
                                 y: .value(loc.s("storage.card.free"), Double(sample.bytes)))
                            .foregroundStyle(Palette.accentText)
                        PointMark(x: .value(loc.s("storage.trend.date"), sample.date),
                                  y: .value(loc.s("storage.card.free"), Double(sample.bytes)))
                            .foregroundStyle(Palette.accentText)
                            .accessibilityLabel(loc.date(sample.date) + " " + Fmt.clock(sample.date))
                            .accessibilityValue(sample.bytes == 0 ? Fmt.zeroBytes : Fmt.bytes(sample.bytes))
                    }
                    ForEach(events) { event in
                        RuleMark(x: .value(loc.s("storage.trend.date"), event.date))
                            .foregroundStyle(Palette.warningText)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .accessibilityHidden(true)
                    }
                }
                .chartXScale(domain: start...now)
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let bytes = value.as(Double.self) {
                                Text(bytes == 0 ? Fmt.zeroBytes : Fmt.bytes(UInt64(max(0, bytes))))
                            }
                        }
                    }
                }
                .frame(height: 210)

                if samples.count < 2 {
                    Text(loc.s("storage.trend.collecting")).foregroundStyle(Palette.textSecondary)
                }
                if !events.isEmpty {
                    Text(loc.s("storage.trend.cleanups")).microLabel()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(events) { event in
                                HStack {
                                    Image(systemName: event.source.icon).foregroundStyle(Palette.warningText)
                                    Text(loc.s(event.source.labelKey))
                                    Spacer()
                                    Text(loc.date(event.date) + " " + Fmt.clock(event.date))
                                        .foregroundStyle(Palette.textSecondary)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 110)
                }
            }
            .font(Typo.secondary)
            .padding(Metric.inset)
            .card()
        }
        .frame(width: 720)
        .background(Palette.background)
        .task { await history.capture() }
    }
}
