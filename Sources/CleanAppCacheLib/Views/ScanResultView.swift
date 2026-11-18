import SwiftUI

// MARK: - Universal scan-result screen
//
// One template for eight sections: system data, system junk, development,
// privacy, duplicates, leftovers, orphans and startup items. They differ only
// in their data and their captions, so they differ only in the value they hand
// to this view.
//
// Two rules hold on all eight screens:
//
//   • the size filter is **per section**, not shared. A dictionary keyed by
//     section, not one global value.
//   • Startup items are not measured in bytes. They free no space, so they get
//     neither a volume total nor a size filter.
//
// Startup items are not shown in seconds of launch delay either: macOS reports
// no per-item launch cost (the sources are enumerated on
// `StartupManager.programBytes`), so such a column could only render dashes.
// `.launchImpact` states what is measured instead.

/// What the section measures. Everything downstream — the column, the totals,
/// the bottom bar — follows from this one choice.
public enum ScanMetric: Sendable {
    case bytes
    /// Startup items. Rows still carry a size — of the program each entry
    /// launches — so the share bar has something real to scale by, but the
    /// aggregates are counts: turning autostart off reclaims nothing, and a
    /// volume in the subtitle or the bottom bar would promise space.
    case launchImpact
}

public struct ScanResultItem: Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let path: String
    /// Value of the section's context column — "what it is", "browser", "copies"…
    public let context: String
    /// What the row is worth: bytes to reclaim, or — for `.launchImpact` — the
    /// on-disk size of the program the entry launches. One unit, both modes.
    public let bytes: UInt64
    /// One line on what the item is, drawn between the title and the path.
    /// Empty draws nothing and keeps the row at its two-line height.
    public let detail: String
    /// A word label for a row whose removal costs something that does not come
    /// back by itself. It sits beside the title in warning colour and the
    /// detail line takes the same colour, so the row is flagged in words, not
    /// only by colour.
    public let caution: String?
    /// "Select all" leaves this row as it is: it never ticks it and never
    /// unticks it. For rows the user has to choose one at a time, because a
    /// bulk tick would carry them into the delete without being read.
    public let excludedFromSelectAll: Bool

    public init(id: UUID = UUID(), title: String, path: String, context: String,
                bytes: UInt64 = 0, detail: String = "", caution: String? = nil,
                excludedFromSelectAll: Bool = false) {
        self.id = id
        self.title = title
        self.path = path
        self.context = context
        self.bytes = bytes
        self.detail = detail
        self.caution = caution
        self.excludedFromSelectAll = excludedFromSelectAll
    }

    /// What the share bar scales by.
    var magnitude: Double { Double(bytes) }
}

/// The size filter each section owns. `all` is always the first item.
public enum ScanSizeFilter: String, Codable, CaseIterable, Identifiable, Sendable {
    case all, mb100, mb500, gb1, gb5

    public var id: String { rawValue }

    var minimumBytes: UInt64 {
        switch self {
        case .all:   return 0
        case .mb100: return 100_000_000
        case .mb500: return 500_000_000
        case .gb1:   return 1_000_000_000
        case .gb5:   return 5_000_000_000
        }
    }

    var titleKey: String {
        switch self {
        case .all:   return "common.all"
        case .mb100: return "scan.sizeFilter.100mb"
        case .mb500: return "scan.sizeFilter.500mb"
        case .gb1:   return "scan.sizeFilter.1gb"
        case .gb5:   return "scan.sizeFilter.5gb"
        }
    }
}

/// Everything a section has to say about itself.
public struct ScanResultConfig {
    let title: String
    /// The trailing half of the subtitle — "caches, logs and temporary files".
    let describes: String
    /// Heading of the context column.
    let contextColumn: String
    /// Label of the primary button.
    let actionTitle: String
    /// Consequence line in the bottom bar.
    let warning: String
    let warningIsDestructive: Bool
    /// What the empty state promises the scan will look at.
    let willFind: String
    let metric: ScanMetric

    public init(title: String, describes: String, contextColumn: String,
                actionTitle: String, warning: String,
                warningIsDestructive: Bool = false,
                willFind: String, metric: ScanMetric = .bytes) {
        self.title = title
        self.describes = describes
        self.contextColumn = contextColumn
        self.actionTitle = actionTitle
        self.warning = warning
        self.warningIsDestructive = warningIsDestructive
        self.willFind = willFind
        self.metric = metric
    }
}

public struct ScanResultView: View {
    @EnvironmentObject private var loc: Localizer

    let config: ScanResultConfig
    let items: [ScanResultItem]
    let hasScanned: Bool
    let isScanning: Bool
    let scanProgress: Double
    let scanDetail: String
    @Binding var selection: Set<UUID>
    @Binding var sizeFilter: ScanSizeFilter
    let onScan: () -> Void
    let onApply: () -> Void
    let onCancel: (() -> Void)?
    /// The bottom bar's volume when the plain sum of the selected rows would
    /// overstate it — rows that lie inside other selected rows. `nil` sums
    /// the rows.
    let selectedBytes: UInt64?
    /// The section's **scan inputs** — what the next scan will look at, as
    /// opposed to the size filter, which narrows what the last one found.
    ///
    /// Only duplicates has any (its scope and its threshold); the other
    /// seven sections scan a fixed set of locations and pass nothing, so the slot
    /// collapses to nothing for them. It lives in the screen header's trailing
    /// slot because that is where the Applications screen puts controls, and it is rendered
    /// even before the first scan — which is exactly when a scan input matters.
    let parameters: AnyView?
    let skipped: ScanSkipSummary

    @State private var filterOpen: String?

    public init(config: ScanResultConfig,
                items: [ScanResultItem],
                hasScanned: Bool,
                isScanning: Bool = false,
                scanProgress: Double = 0,
                scanDetail: String = "",
                selection: Binding<Set<UUID>>,
                sizeFilter: Binding<ScanSizeFilter>,
                onScan: @escaping () -> Void,
                onApply: @escaping () -> Void,
                onCancel: (() -> Void)? = nil,
                selectedBytes: UInt64? = nil,
                parameters: AnyView? = nil,
                skipped: ScanSkipSummary = ScanSkipSummary()) {
        self.config = config
        self.items = items
        self.hasScanned = hasScanned
        self.isScanning = isScanning
        self.scanProgress = scanProgress
        self.scanDetail = scanDetail
        self._selection = selection
        self._sizeFilter = sizeFilter
        self.onScan = onScan
        self.onApply = onApply
        self.onCancel = onCancel
        self.selectedBytes = selectedBytes
        self.parameters = parameters
        self.skipped = skipped
    }

    // MARK: Columns

    private var spec: TableSpec {
        var columns = [
            TableCol("check", width: Metric.checkboxGlyph),
            TableCol("item", title: loc.s("scan.col.item")),
            TableCol("context", title: config.contextColumn, width: 210),
            TableCol("share", title: loc.s("scan.col.share"), width: 84),
        ]
        // Startup items have no size filter and their own column name. It is
        // "program" (`startup.col.program`), not "size": everywhere else that column is what the
        // action reclaims, and here it is only how big the program is.
        columns.append(TableCol("size",
                                title: config.metric == .launchImpact
                                    ? loc.s("startup.col.program") : loc.s("scan.col.size"),
                                width: 88, alignment: .trailing))
        return TableSpec(columns)
    }

    private var hasSizeFilter: Bool { config.metric == .bytes }

    private var filtered: [ScanResultItem] {
        guard hasSizeFilter, sizeFilter != .all else { return items }
        return items.filter { $0.bytes >= sizeFilter.minimumBytes }
    }

    private var selected: [ScanResultItem] {
        filtered.filter { selection.contains($0.id) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScreenBody {
                header
                if hasScanned && !isScanning && !items.isEmpty && skipped.needsNotice {
                    ScanSkippedSummaryView(summary: skipped)
                }
                table
            }
            if !selected.isEmpty {
                bottomBar
            }
        }
        .background(Palette.background)
        // Only one filter menu may be open, and clicking elsewhere closes it.
        .onTapGesture { filterOpen = nil }
    }

    // MARK: Header

    private var header: some View {
        ScreenHeader(title: config.title, subtitle: subtitle) {
            HStack(spacing: 8) {
                // Scan inputs come first: they are read before the results, and
                // they stay reachable while the section is still unscanned.
                // Hidden mid-scan — the scan already committed to them.
                if let parameters, !isScanning { parameters }
                // While the section is unscanned the action lives in the
                // centre of the empty state and must not be duplicated here.
                if hasScanned && !isScanning {
                    if hasSizeFilter && sizeFilter != .all {
                        Button(loc.s("common.resetFilter")) { sizeFilter = .all }
                            .buttonStyle(.secondaryAction)
                    }
                    // A select-all over nothing is a control that cannot do
                    // anything, so a section with no row it may tick does not
                    // draw one.
                    if filtered.contains(where: { !$0.excludedFromSelectAll }) {
                        Button(loc.s("common.selectAll")) { selectAll() }
                            .buttonStyle(.secondaryAction)
                    }
                }
            }
        }
    }

    private var subtitle: String? {
        guard hasScanned, !isScanning else { return nil }
        // Nothing found: the count would be "0 items" and the total an em
        // dash, so the subtitle would read "Found 0 items · — · …" beside a
        // panel that already says the section is clean, and a zero count is
        // never printed. It states what was looked at and stops there.
        guard !filtered.isEmpty else { return config.describes }
        let count = Fmt.plural("plural.items", filtered.count)
        switch config.metric {
        case .bytes:
            return loc.f("scan.subtitleFmt", count, total(of: filtered), config.describes)
        case .launchImpact:
            // The middle slot is a volume everywhere else. Startup items reclaim
            // nothing, so there is no total to put there, and the subtitle says one
            // fact fewer rather than a number about space it never touches. The
            // section supplies its own second fact through `describes`.
            return loc.f("scan.subtitlePairFmt", count, config.describes)
        }
    }

    /// The section's own total. Only `.bytes` sections have one.
    private func total(of set: [ScanResultItem]) -> String {
        Fmt.bytes(set.reduce(UInt64(0)) { $0 &+ $1.bytes })
    }

    // MARK: Table

    @ViewBuilder
    private var table: some View {
        if isScanning {
            StateView(.scanning(percent: scanProgress,
                                category: config.title,
                                path: scanDetail,
                                cancel: onCancel))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
        } else if !hasScanned {
            StateView(.idle(section: config.title, willFind: config.willFind, scan: onScan))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
        } else if filtered.isEmpty && !items.isEmpty {
            // Names the filter and the total behind it: "the “5 GB+” filter left none of 6 items".
            StateView(.filterEmpty(total: items.count,
                                   query: loc.s(sizeFilter.titleKey),
                                   reset: { sizeFilter = .all }))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
        } else if items.isEmpty && skipped.needsNotice {
            VStack(alignment: .leading) {
                ScanSkippedSummaryView(summary: skipped)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .card()
        } else if items.isEmpty {
            StateView(.clean(checked: config.describes, lastScan: nil, rescan: onScan))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
        } else {
            // Read once per pass. `spec` runs four `loc.s()` calls and allocates
            // the column array, and `filtered` is a filter pass; read inside the
            // row they would run again for every row, and `peak` would re-walk
            // `filtered` per row on top of that.
            let spec = self.spec
            let rows = filtered
            let peak = rows.map(\.magnitude).max() ?? 1
            VStack(spacing: 0) {
                TableHeader(spec, customKeys: hasSizeFilter ? ["size"] : []) { _ in
                    ColumnFilter(title: loc.s("scan.col.size"),
                                 options: ScanSizeFilter.allCases.dropFirst().map {
                                     SegmentOption(value: $0, label: loc.s($0.titleKey))
                                 },
                                 selection: $sizeFilter,
                                 allValue: .all,
                                 allTitle: loc.s("common.all"),
                                 columnKey: "size",
                                 openKey: $filterOpen)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                // The open menu is an overlay on the header; without this the rows
                // below it paint over the menu.
                .zIndex(1)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                            row(item, spec: spec, peak: peak).staggeredAppear(index: index)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .card()
        }
    }

    /// `peak` is the largest row's magnitude: the bar is measured against
    /// that, not against the sum.
    private func row(_ item: ScanResultItem, spec: TableSpec, peak: Double) -> some View {
        let isOn = selection.contains(item.id)

        return TableRow(spec: spec,
                        height: item.detail.isEmpty ? Metric.rowResult : Metric.rowResultDetailed,
                        isSelected: isOn,
                        accessibility: [item.title, item.caution ?? "", item.detail]
                            .filter { !$0.isEmpty }.joined(separator: ", "),
                        action: { toggle(item) }) {
            RowCheckbox(isOn: isOn)
                .column(spec, "check")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(Typo.bodyStrong)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let caution = item.caution {
                        // A long title truncates before the warning does.
                        Text(caution).riskLabel(Palette.warningText)
                            .layoutPriority(1)
                    }
                }
                if !item.detail.isEmpty {
                    // `warningText`, not `warningButton`: the button amber is
                    // a fill and is too faint as 12pt text.
                    Text(item.detail)
                        .font(Typo.secondary)
                        .foregroundStyle(item.caution == nil ? Palette.textSecondary : Palette.warningText)
                        .lineLimit(1)
                        .help(item.detail)
                }
                if !item.path.isEmpty {
                    Text(item.path)
                        .font(Typo.numeric(11, weight: .regular))
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .column(spec, "item")

            Text(item.context)
                .font(Typo.secondary)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .column(spec, "context")

            ShareBar(fraction: peak > 0 ? item.magnitude / peak : 0,
                     color: isOn ? Palette.accent : Palette.accentBarLight)
                .column(spec, "share")

            Text(Fmt.bytes(item.bytes))
                .font(Typo.numeric(12, weight: .regular))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .column(spec, "size")
        }
    }

    /// Ticks every visible row except those excluded from the bulk tick; an
    /// excluded row the user ticked by hand stays ticked.
    private func selectAll() {
        selection = Set(filtered.filter {
            !$0.excludedFromSelectAll || selection.contains($0.id)
        }.map(\.id))
    }

    private func toggle(_ item: ScanResultItem) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        BottomActionBar(
            selectionLabel: loc.s("common.selected"),
            selectionValue: selectionValue,
            // The count sits beside the volume; when the count *is* the value
            // there is nothing left to put here.
            selectionCount: config.metric == .bytes
                ? Fmt.plural("plural.items", selected.count) : nil,
            consequence: config.warning,
            consequenceIsDestructive: config.warningIsDestructive
        ) {
            Button(config.actionTitle, action: onApply)
                .buttonStyle(config.warningIsDestructive
                             ? PrimaryButtonStyle(tint: Palette.dangerFill)
                             : PrimaryButtonStyle())
        }
    }

    private var selectionValue: String {
        switch config.metric {
        case .bytes:
            return Fmt.bytes(selectedBytes ?? selected.reduce(UInt64(0)) { $0 &+ $1.bytes })
        case .launchImpact:
            // Summing the programs would read as space about to be freed, and
            // turning autostart off frees none of it. The count is the honest
            // headline: what the button is about to act on.
            return Fmt.plural("plural.items", selected.count)
        }
    }
}
