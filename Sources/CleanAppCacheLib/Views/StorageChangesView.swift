import SwiftUI

struct StorageChangesView: View {
    @EnvironmentObject private var loc: Localizer
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var cleanups = CleanupHistory.shared
    @State private var snapshots: [StorageSnapshot] = []
    @State private var loaded = false
    @State private var period = StorageSnapshotPeriod.previous
    @State private var browser: FolderBrowser?

    let makeBrowser: () -> StorageViewModel

    private struct FolderBrowser: Identifiable {
        let id = UUID()
        let viewModel: StorageViewModel
    }

    private var spec: TableSpec {
        TableSpec([
            TableCol("name", title: loc.s("storage.changes.item")),
            TableCol("delta", title: loc.s("storage.changes.delta"), width: 140, alignment: .trailing),
            TableCol("current", title: loc.s("storage.changes.current"), width: 110, alignment: .trailing)
        ])
    }

    var body: some View {
        ScreenBody {
            ScreenHeader(title: loc.s("storage.changes.title")) {
                IconButton("xmark", label: loc.s("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            SegmentedControl(selection: $period, options: [
                SegmentOption(value: .previous, label: loc.s("storage.changes.previous")),
                SegmentOption(value: .week, label: loc.s("storage.trend.week")),
                SegmentOption(value: .month, label: loc.s("storage.trend.month"))
            ])
            .fixedSize()

            if let selection = period.select(snapshots) {
                comparison(selection)
            } else {
                VStack {
                    if loaded {
                        Text(loc.s("storage.changes.collecting"))
                            .font(Typo.body)
                            .foregroundStyle(Palette.textSecondary)
                            .multilineTextAlignment(.center)
                    } else {
                        ProgressView()
                    }
                }
                .padding(Metric.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
            }
        }
        .frame(width: 740, height: 520)
        .background(Palette.background)
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .storageSnapshotsChanged)) { _ in
            Task { await load() }
        }
        .sheet(item: $browser) { presentation in
            StorageDetailView().environmentObject(presentation.viewModel).environmentObject(loc)
        }
    }

    private func load() async {
        snapshots = await StorageSnapshotStore.shared.history()
        loaded = true
    }

    private func comparison(_ selection: StorageSnapshotPeriod.Selection) -> some View {
        let result = StorageSnapshotComparison(from: selection.from, to: selection.to, cleanups: cleanups.records)
        let growth = result.changes.filter { !$0.uncertain && ($0.delta > 0 || $0.presence == .added) }
        let shrink = result.changes.filter { !$0.uncertain && ($0.delta < 0 || $0.presence == .removed) }
        let uncertain = result.changes.filter(\.uncertain)

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(loc.f("storage.changes.rangeFmt", measurementDate(selection.from.date),
                           measurementDate(selection.to.date)))
                    .foregroundStyle(Palette.textSecondary)
                if selection.shortHistory {
                    Text(loc.f("storage.changes.shortHistoryFmt", loc.date(selection.from.date)))
                        .foregroundStyle(Palette.warningText)
                }
                summary(loc.s("storage.changes.used"), signed(result.usedDelta))
                summary(loc.s("storage.changes.freed"), sizeLabel(result.freedBytes))
                summary(loc.s("storage.changes.trash"), sizeLabel(result.trashedBytes))
            }
            .font(Typo.body)
            .padding(Metric.inset)
            .card()

            VStack(spacing: 0) {
                TableHeader(spec)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        group(loc.s("storage.changes.growth"), rows: growth)
                        group(loc.s("storage.changes.shrink"), rows: shrink)
                        group(loc.s("storage.changes.uncertain"), rows: uncertain)
                        if result.changes.isEmpty {
                            Text(loc.s("storage.changes.noChanges"))
                                .font(Typo.secondary)
                                .foregroundStyle(Palette.textSecondary)
                                .padding(Metric.inset)
                        }
                    }
                }
            }
            .card()
        }
    }

    private func measurementDate(_ date: Date) -> String {
        loc.date(date) + " " + Fmt.clock(date)
    }

    private func summary(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Palette.textPrimary)
            Spacer()
            Text(value).font(Typo.numeric(13, weight: .regular))
                .foregroundStyle(Palette.textPrimary)
        }
    }

    @ViewBuilder
    private func group(_ title: String, rows: [StorageSnapshotComparison.Change]) -> some View {
        if !rows.isEmpty {
            Text(title)
                .font(Typo.secondary)
                .foregroundStyle(Palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, spec.inset)
                .padding(.vertical, 7)
                .background(Palette.surfaceFooter)
            ForEach(rows) { row($0) }
        }
    }

    @ViewBuilder
    private func row(_ change: StorageSnapshotComparison.Change) -> some View {
        let category = loc.name(change.category)
        let name = change.member?.name ?? category
        let location = change.member.flatMap { $0.id.hasPrefix("/") ? $0.id : nil } ?? category
        let delta = deltaLabel(change)
        let current = change.currentPartial
            ? (change.currentBytes == 0 ? Fmt.none : "≥ " + Fmt.bytes(change.currentBytes))
            : sizeLabel(change.currentBytes)

        if let path = change.folderPath {
            TableRow(spec: spec, height: 48,
                     accessibility: [name, location, delta, current].joined(separator: ", "),
                     action: { openFolder(path) }) {
                cells(name: name, location: location, browsable: true, delta: delta,
                      current: current, uncertain: change.uncertain)
            }
        } else {
            HStack(spacing: spec.spacing) {
                cells(name: name, location: change.member == nil ? nil : location, delta: delta,
                      current: current, uncertain: change.uncertain)
            }
            .padding(.horizontal, spec.inset)
            .frame(height: 48)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.rowDivider).frame(height: 1)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func openFolder(_ path: String) {
        let viewModel = makeBrowser()
        viewModel.openDiskBrowser(path: path)
        browser = FolderBrowser(viewModel: viewModel)
    }

    @ViewBuilder
    private func cells(name: String, location: String?, browsable: Bool = false,
                       delta: String, current: String, uncertain: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name).font(Typo.body).foregroundStyle(Palette.textPrimary)
                if browsable {
                    Image(systemName: "arrow.up.right").foregroundStyle(Palette.textTertiary)
                }
            }
            if let subtitle = location {
                Text(subtitle).font(Typo.footnote).foregroundStyle(Palette.textSecondary)
                    .truncationMode(.middle)
                    .help(subtitle)
            }
        }
        .lineLimit(1)
        .column(spec, "name")

        Text(delta)
            .font(Typo.secondary)
            .foregroundStyle(uncertain ? Palette.warningText : Palette.textPrimary)
            .column(spec, "delta")

        Text(current)
            .font(Typo.numeric(12, weight: .regular))
            .foregroundStyle(Palette.textSecondary)
            .column(spec, "current")
    }

    private func sizeLabel(_ value: UInt64) -> String {
        value == 0 ? Fmt.zeroBytes : Fmt.bytes(value)
    }

    private func deltaLabel(_ change: StorageSnapshotComparison.Change) -> String {
        let value = change.uncertain ? loc.s("storage.changes.uncertain") : signed(change.delta)
        switch change.presence {
        case .added: return loc.f("storage.changes.newFmt", value)
        case .removed: return loc.f("storage.changes.removedFmt", value)
        case .changed: return value
        }
    }

    private func signed(_ value: Int64) -> String {
        let sign = value < 0 ? "−" : (value > 0 ? "+" : "")
        return sign + sizeLabel(value.magnitude)
    }
}
