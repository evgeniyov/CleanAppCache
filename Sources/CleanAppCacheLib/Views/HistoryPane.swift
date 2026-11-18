import SwiftUI

// MARK: - History
//
// The one screen with a dark surface. The design allows exactly one — this hero —
// and forbids a second anywhere else, which is why `heroDark` is read here and
// nowhere else in the app.
//
// Layout: a 300pt hero beside the per-cleanup chart, then the journal table with
// the 288pt "where it came from" panel. Selection is shared — picking a column
// picks its row and the other way round.
//
// Nothing on this screen scans; the journal is written by every section that
// deletes something. Its one destructive action, clearing the journal, lives in
// Settings → Maintenance, so it is not repeated here: a destructive action
// has exactly one home.

public struct HistoryPane: View {
    @EnvironmentObject private var loc: Localizer
    @ObservedObject private var history = CleanupHistory.shared

    /// The chart column and the table row are one selection.
    @State private var picked: UUID?
    @State private var shownRecord: CleanupRecord?

    // Screen geometry.
    private let heroWidth: CGFloat = 300
    private let barMaxHeight: CGFloat = 118
    private let rowHeight: CGFloat = 46

    /// Past a dozen columns the dates underneath stop being readable, and the
    /// journal holds up to 300 records.
    private let chartBarLimit = 12

    // MARK: Human equivalent
    //
    // "About 17 hours of 4K video or 20,944 photos" only means something if
    // the rates it converts at are stated, so they are constants rather than
    // magic numbers:
    //
    //   • 4K video at 16 Mbit/s — the bitrate the streaming services deliver UHD
    //     at — comes to 7.2 GB per hour.
    //   • one 12-megapixel photo saved as high-quality JPEG is about 3 MB.

    private static let bytesPerHourOf4K: Double = 7_200_000_000
    private static let bytesPerPhoto: Double = 3_000_000

    public init() {}

    public var body: some View {
        ScreenBody {
            header
            if history.records.isEmpty {
                emptyState
            } else {
                topRow
                tableAndPanel
            }
        }
        .background(Palette.background)
        // The screen opens with the newest cleanup picked, so the chart and
        // the panel say something before the user touches anything.
        .onAppear { if picked == nil { picked = history.records.first?.id } }
        .sheet(item: $shownRecord) { record in
            operationReport(history.records.first { $0.id == record.id } ?? record)
        }
    }

    // MARK: Header

    private var header: some View {
        // The screen title is "History" — the word the sidebar already
        // carries, so the two share one key.
        ScreenHeader(title: loc.s("history.show"), subtitle: subtitle)
    }

    private var subtitle: String? {
        guard let last = history.records.first else { return nil }
        return loc.f("history.subtitleFmt",
                     JournalStamps.current(loc.locale).full.string(from: last.date))
    }

    // MARK: Hero + chart

    private var topRow: some View {
        HStack(alignment: .top, spacing: Metric.cardGap) {
            hero.frame(width: heroWidth)
            chart
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var hero: some View {
        let total = Fmt.size(history.totalFreedBytes)
        return VStack(alignment: .leading, spacing: 0) {
            Text(loc.s("history.totalAllTime"))
                .font(Typo.secondary)
                .foregroundStyle(Palette.heroDarkSecondary)

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(total.number).figure(Typo.heroFigure, color: Palette.heroDarkText)
                if let unit = total.unit {
                    // The unit is `heroDarkSecondary`, not the `Figure`
                    // component's `textTertiary`: on the dark surface the light
                    // theme's tertiary is a near-match but the dark theme's is
                    // unreadable.
                    Text(unit)
                        .font(Typo.numeric(18, weight: .regular))
                        .foregroundStyle(Palette.heroDarkSecondary)
                }
            }
            .padding(.top, 8)

            if let equivalent = equivalent {
                Text(equivalent)
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.heroDarkSecondary)
                    .lineSpacing(6)          // 12pt × 1,5
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }

            // The big figure is space deleted for good. Moves to the Trash
            // still occupy the disk, so they are stated apart from it rather
            // than added in.
            if history.totalTrashedBytes > 0 {
                Text(loc.f("history.trashedTotalFmt", Fmt.bytes(history.totalTrashedBytes)))
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.heroDarkSecondary)
                    .lineSpacing(6)          // 12pt × 1,5
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }

            Spacer(minLength: 16)

            HStack(alignment: .top, spacing: 22) {
                heroStat(count(history.records.count),
                         Fmt.plural("plural.cleanupsWord", history.records.count))
                heroStat(Fmt.bytes(averageFreed), loc.s("history.stat.average"))
                heroStat(count(totalItems),
                         Fmt.plural("plural.objectsWord", totalItems),
                         color: Palette.accentOnDark)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metric.card, style: .continuous)
                .fill(Palette.heroDark)
        )
    }

    private func heroStat(_ value: String, _ caption: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(Typo.numeric(19))
                .foregroundStyle(color ?? Palette.heroDarkText)
                .lineLimit(1)
            Text(caption)
                .font(Typo.footnote)
                .foregroundStyle(Palette.heroDarkSecondary)
                .lineLimit(1)
        }
    }

    /// Below an hour the line is dropped rather than rounded down to "0 hours",
    /// because a zero never reads as a figure. One hour of 4K is already ~2 400 photos, so the photo half never
    /// reaches zero first.
    private var equivalent: String? {
        let total = Double(history.totalFreedBytes)
        let hours = Int(total / Self.bytesPerHourOf4K)
        let photos = Int(total / Self.bytesPerPhoto)
        guard hours >= 1, photos >= 1 else { return nil }
        return loc.f("history.equivalentFmt",
                     Fmt.plural("plural.hours", hours),
                     Fmt.plural("plural.photos", photos))
    }

    // MARK: Per-cleanup chart

    private var chart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(loc.s("history.perCleanup"))
                    .font(Typo.cardTitle)
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 8)
                Text(loc.s("history.chartHint"))
                    .font(Typo.footnote)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
            chartColumns
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var chartColumns: some View {
        let points = chartRecords
        let peak = points.map { $0.freedBytes &+ $0.trashedBytes }.max() ?? 0
        let stamps = JournalStamps.current(loc.locale)
        return HStack(alignment: .bottom, spacing: 10) {
            ForEach(points) { record in
                chartColumn(record, peak: peak, stamps: stamps)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.content, value: picked)
    }

    /// The chart reads left to right in time, so the most recent cleanups are
    /// reversed back into chronological order — the journal itself is newest
    /// first.
    private var chartRecords: [CleanupRecord] {
        Array(history.records.prefix(chartBarLimit).reversed())
    }

    private func chartColumn(_ record: CleanupRecord, peak: UInt64,
                             stamps: JournalStamps) -> some View {
        let isPicked = picked == record.id
        let removed = record.freedBytes &+ record.trashedBytes
        let fraction = peak > 0 ? Double(removed) / Double(peak) : 0
        let day = stamps.day.string(from: record.date)
        let freedColor = isPicked ? Palette.accent : Palette.accentBorder

        // A cleanup that removed almost nothing still needs a visible column:
        // an invisible bar reads as a gap in the record.
        let height = max(10, fraction * barMaxHeight)
        // The trashed share of that height. A segment that exists keeps at
        // least 3pt, or a small move to the Trash above a large deletion
        // (or the other way round) disappears into its neighbour.
        let trashedHeight: CGFloat = {
            guard record.trashedBytes > 0, removed > 0 else { return 0 }
            guard record.freedBytes > 0 else { return height }
            let share = height * CGFloat(Double(record.trashedBytes) / Double(removed))
            return min(max(3, share), height - 3)
        }()
        let freedHeight = height - trashedHeight

        return Button { picked = record.id } label: {
            VStack(spacing: 7) {
                Text(Fmt.bytes(removed))
                    .font(Typo.numeric(11))
                    .foregroundStyle(isPicked ? Palette.accentText : Palette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                // Freed space sits at the bottom in the accent; what only went
                // to the Trash stacks above it in a neutral, because it is not
                // space the disk has back yet. Only the top segment rounds its
                // corners, so the column keeps one silhouette.
                VStack(spacing: 0) {
                    if trashedHeight > 0 {
                        BarShape(radius: 4)
                            .fill(Palette.barUsedNeutral)
                            .frame(height: trashedHeight)
                    }
                    if freedHeight > 0 {
                        if trashedHeight > 0 {
                            Rectangle()
                                .fill(freedColor)
                                .frame(height: freedHeight)
                        } else {
                            BarShape(radius: 4)
                                .fill(freedColor)
                                .frame(height: freedHeight)
                        }
                    }
                }
                Text(day)
                    .font(Typo.numeric(10, weight: .regular))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The columns are the only place the per-cleanup figures exist, so each
        // one reads out its own value rather than being decorative.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(day) · \(loc.s(record.source.labelKey)) · \(outcome(record))"))
        .accessibilityAddTraits(isPicked ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Journal table + panel

    private var tableAndPanel: some View {
        HStack(alignment: .top, spacing: Metric.cardGap) {
            // The spec is chosen from the table's measured width and handed to
            // both the header and every row, so the two cannot drift.
            GeometryReader { geo in
                recordTable(spec: spec(width: geo.size.width))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            panel
                .frame(width: Metric.heroColumn)
                .frame(maxHeight: .infinity)
                .card()
        }
        .frame(maxHeight: .infinity)
    }

    /// Columns: when 118 | section | items 76 | freed 88 | to Trash 88 | action 74.
    private func spec(width: CGFloat) -> TableSpec {
        // Every column shown needs 690pt for a 130pt section column:
        // 18 + 118 + 16 + 130 + 16 + 76 + 16 + 88 + 16 + 88 + 16 + 74 + 18.
        // The table is narrower than that at ordinary window sizes (about
        // 594pt at 1180pt, 514pt at the 1100pt minimum), and a squeezed section
        // column cuts "System Junk" in Russian down to a few letters. So the
        // object count steps aside first, since the two byte columns already
        // answer "how much"; below 594pt the date leaves its own column and
        // moves under the section name, which keeps that column at 180pt even
        // in the minimum window.
        let hasWhen = width >= 594
        var columns: [TableCol] = []
        if hasWhen {
            columns.append(TableCol("when", title: loc.s("history.col.when"), width: 118))
        }
        columns.append(TableCol("section", title: loc.s("history.col.section")))
        if width >= 690 {
            columns.append(TableCol("items", title: loc.s("history.col.items"),
                                    width: 76, alignment: .trailing))
        }
        columns.append(TableCol("freed", title: loc.s("history.col.freed"),
                                width: 88, alignment: .trailing))
        columns.append(TableCol("trashed", title: loc.s("history.col.trashed"),
                                width: 88, alignment: .trailing))
        columns.append(TableCol("action", width: 74, alignment: .trailing))
        return TableSpec(columns)
    }

    private func recordTable(spec: TableSpec) -> some View {
        let stamps = JournalStamps.current(loc.locale)
        return VStack(spacing: 0) {
            TableHeader(spec)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(history.records.enumerated()), id: \.element.id) { index, record in
                        recordRow(record, spec: spec, stamps: stamps)
                            .staggeredAppear(index: index)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }

    private func recordRow(_ record: CleanupRecord, spec: TableSpec,
                           stamps: JournalStamps) -> some View {
        let isPicked = picked == record.id
        let when = stamps.full.string(from: record.date)

        return TableRow(spec: spec,
                        height: rowHeight,
                        isSelected: isPicked,
                        selectionColor: Palette.pickedRow,
                        accessibility: "\(when) · \(loc.s(record.source.labelKey)) · \(outcome(record))",
                        action: { picked = record.id }) {
            if spec.column("when") != nil {
                Text(when)
                    .font(Typo.numeric(12, weight: .regular))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .column(spec, "when")
            }

            HStack(spacing: 9) {
                CategorySwatch(color: record.source.sectionColor, size: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc.s(record.source.labelKey))
                        .font(Typo.body)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    // A narrow table has no date column; the date then sits
                    // under the section name, where the 46pt row has room.
                    if spec.column("when") == nil {
                        Text(when)
                            .font(Typo.numeric(11, weight: .regular))
                            .foregroundStyle(Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
            .column(spec, "section")

            if spec.column("items") != nil {
                Text(count(record.itemCount))
                    .font(Typo.numeric(12, weight: .regular))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .column(spec, "items")
            }

            // `Fmt.bytes` renders zero as an em dash, so a cleanup that only
            // moved files to the Trash never reads as "freed 0".
            Text(Fmt.bytes(record.freedBytes))
                .font(Typo.numeric(13))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .column(spec, "freed")

            Text(Fmt.bytes(record.trashedBytes))
                .font(Typo.numeric(13))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .column(spec, "trashed")

            Color.clear.column(spec, "action")
        }
        .overlay(alignment: .trailing) {
            if isPicked {
                Button(loc.s("history.details")) { shownRecord = record }
                    .buttonStyle(.plain)
                    .font(Typo.footnote)
                    .foregroundStyle(Palette.accentText)
                    .frame(width: spec.column("action")?.width, height: rowHeight, alignment: .trailing)
                    .padding(.trailing, spec.inset)
            }
        }
    }

    private func operationReport(_ record: CleanupRecord) -> some View {
        ScreenBody {
            ScreenHeader(title: loc.s(record.source.labelKey), subtitle: loc.dateTime(record.date))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(outcome(record))
                        .font(Typo.bodyStrong)
                        .foregroundStyle(Palette.textPrimary)
                    if let report = record.report {
                        TableSectionHeader(loc.s("history.originalOutcome"))
                        ForEach(report.categories) { entry in
                            HStack(spacing: 8) {
                                Text(loc.s(entry.category.titleKey))
                                Spacer(minLength: 4)
                                Text(loc.f("history.removedOfFmt", Fmt.count(entry.removed), Fmt.count(entry.selected)))
                                Text(Fmt.bytes(entry.bytes))
                                    .frame(minWidth: 82, alignment: .trailing)
                            }
                        }
                        ForEach(ScanSkipReason.allCases, id: \.self) { reason in
                            if let count = report.skipped[reason] {
                                Text(loc.f("scan.skipped.reasonCountFmt", loc.s(reason.titleKey), Fmt.count(count)))
                            }
                        }
                        ForEach(RemovalObstacle.allCases, id: \.self) { obstacle in
                            if let count = report.failed[obstacle] {
                                Text(failureText(obstacle, count: count))
                            }
                        }
                        if report.alreadyGone > 0 {
                            Text(loc.f("cleanup.alreadyGoneFmt", Fmt.plural("plural.objects", report.alreadyGone)))
                        }
                        if report.notAttempted > 0 {
                            Text(loc.f("history.notAttemptedFmt", Fmt.count(report.notAttempted)))
                        }
                    } else {
                        Text(loc.s("history.noReport"))
                    }
                }
                .font(Typo.secondary)
                .foregroundStyle(Palette.textSecondary)
                .padding(Metric.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .card()
            HStack {
                let target = screen(for: record.source)
                Button(loc.f("history.openSectionFmt", loc.s(target.titleKey))) {
                    shownRecord = nil
                    open(target)
                }
                .buttonStyle(.secondaryAction)
                Spacer()
                Button(loc.s("common.close")) { shownRecord = nil }
                    .buttonStyle(.primaryAction)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 560, height: 430)
        .background(Palette.background)
    }

    private func failureText(_ obstacle: RemovalObstacle, count: Int) -> String {
        let items = Fmt.plural("plural.objects", count)
        switch obstacle {
        case .needsAdmin: return loc.f("removal.needsAdminFmt", items)
        case .privacyProtected: return loc.f("removal.privacyFmt", items)
        case .systemProtected: return loc.f("removal.systemFmt", items)
        case .locked: return loc.f("removal.lockedFmt", items)
        case .inUse: return loc.f("removal.inUseFmt", items)
        case .changedSinceScan: return loc.f("removal.changedSinceScanFmt", items)
        case .other: return loc.f("toast.deleteFailedFmt", count)
        }
    }

    // MARK: "Where it came from" panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(loc.s("history.bySection"))
                .font(Typo.cardTitle)
                .foregroundStyle(Palette.textPrimary)

            // Eight sections can log cleanups, which is more than a short window
            // fits. The list takes the slack and scrolls; the verdict and the
            // button stay pinned to the bottom of the card.
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    ForEach(sectionTotals) { entry in
                        sectionRow(entry)
                    }
                }
            }

            Rectangle().fill(Palette.borderHairline).frame(height: 1)

            if let insight = insight {
                Text(insight)
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textSecondary)
                    .lineSpacing(6.6)        // 12pt × 1,55
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button { open(.smartCleanup) } label: {
                Text(loc.s("history.runCleanup")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondaryAction(height: Metric.primaryButton))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionRow(_ entry: SectionTotal) -> some View {
        // The panel breaks one whole down, so a bar is the section's share of
        // everything ever freed — not of the largest section, which is the
        // rule for share bars inside a table. Moves to the Trash are not part
        // of that whole: a section that only trashed still lists, with a dash
        // and an empty bar.
        let total = history.totalFreedBytes
        let fraction = total > 0 ? Double(entry.bytes) / Double(total) : 0

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(loc.s(entry.source.labelKey))
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textNav)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Fmt.bytes(entry.bytes))
                    .font(Typo.numeric(12))
                    .foregroundStyle(Palette.textPrimary)
            }
            GaugeBar(fraction: fraction, height: 6, fill: entry.source.sectionColor)
        }
    }

    private var insight: String? {
        guard let top = sectionTotals.first, top.bytes > 0 else { return nil }
        return loc.f("history.insightFmt",
                     loc.s(top.source.labelKey),
                     Fmt.bytes(top.bytes),
                     Fmt.plural("plural.cleanups", top.cleanups))
    }

    private struct SectionTotal: Identifiable {
        let source: CleanupRecord.Source
        let bytes: UInt64
        let cleanups: Int
        var id: String { source.rawValue }
    }

    private var sectionTotals: [SectionTotal] {
        var totals: [CleanupRecord.Source: (bytes: UInt64, cleanups: Int)] = [:]
        for record in history.records {
            let running = totals[record.source] ?? (bytes: 0, cleanups: 0)
            totals[record.source] = (running.bytes &+ record.freedBytes, running.cleanups + 1)
        }
        return totals
            .map { SectionTotal(source: $0.key, bytes: $0.value.bytes, cleanups: $0.value.cleanups) }
            // Dictionary order is not stable between renders, so equal volumes
            // are broken by name — otherwise two sections swap places on every
            // redraw.
            .sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
    }

    // MARK: Empty state

    private var emptyState: some View {
        // The journal never scans anything itself, so `.idle` is the state that
        // fits, and its action hands the user to the screen that fills it.
        StateView(.idle(section: loc.s("history.show"),
                        willFind: loc.s("history.emptyDesc"),
                        scan: { open(.smartCleanup) }))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .card()
    }

    // MARK: Figures

    private var averageFreed: UInt64 {
        guard !history.records.isEmpty else { return 0 }
        return history.totalFreedBytes / UInt64(history.records.count)
    }

    /// What one cleanup did to the disk, in words: freed, moved to the Trash,
    /// or both. A record with neither amount (an item count alone) reads as
    /// "freed" with a dash.
    private func outcome(_ record: CleanupRecord) -> String {
        let freed = record.freedBytes
        let trashed = record.trashedBytes
        if freed > 0, trashed > 0 {
            return loc.f("outcome.bothFmt", Fmt.bytes(freed), Fmt.bytes(trashed))
        }
        if trashed > 0 {
            return loc.f("outcome.trashedFmt", Fmt.bytes(trashed))
        }
        return loc.f("outcome.freedFmt", Fmt.bytes(freed))
    }

    private var totalItems: Int {
        history.records.reduce(0) { $0 + $1.itemCount }
    }

    /// A zero measurement reads as an em dash, never 0.
    private func count(_ value: Int) -> String {
        value > 0 ? Fmt.count(value) : Fmt.none
    }

    // MARK: Navigation

    /// Sends the user to a section. `AppState` is reached through the
    /// singleton rather than the environment so the pane does not depend on
    /// what its presenter happens to inject.
    private func open(_ target: Screen) {
        AppState.shared.open(target)
    }

    /// Flat navigation lets a record point at its exact screen rather than
    /// at the section that happens to contain it.
    private func screen(for source: CleanupRecord.Source) -> Screen {
        switch source {
        case .smartCleanup, .trash: return .smartCleanup
        case .systemJunk:           return .systemJunk
        case .developer:            return .developer
        case .uninstaller:          return .apps
        case .leftovers:            return .leftovers
        case .orphans:              return .orphans
        case .largeFiles:           return .largeFiles
        case .duplicates:           return .duplicates
        }
    }
}

// MARK: - Section colour
//
// The History mapping reuses six of the eleven category hues rather than
// introducing colours of its own, so each source resolves onto the palette entry
// that already carries its value; everything else is the neutral "other" hue.

private extension CleanupRecord.Source {
    @MainActor var sectionColor: Color {
        switch self {
        case .smartCleanup:            return Palette.accent        // #6C63E0
        case .developer:               return Palette.breakdown(1)  // #4A8FD8
        case .systemJunk:              return Palette.breakdown(2)  // #C77BC0
        case .trash:                   return Palette.breakdown(5)  // #D2372B
        case .largeFiles:              return Palette.breakdown(3)  // #3F8A6B
        case .duplicates:              return Palette.breakdown(10) // #B08A3F
        case .uninstaller, .leftovers, .orphans: return Palette.breakdown(8)  // #9A9AA2
        }
    }
}

// MARK: - Chart column shape
//
// A column rounds its top corners only. `UnevenRoundedRectangle` says that in one
// line but arrived in macOS 14, and the package targets 13.

private struct BarShape: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Journal date formats
//
// A `DateFormatter` built without a `.locale` and with a literal
// "MMM d" pattern gives a Russian UI English month names in English word order,
// so both formats come from `dateFormat(fromTemplate:)`. Building one
// costs about a millisecond and the table renders up to 300 rows, so the pair is
// cached until the UI language changes.

@MainActor
private struct JournalStamps {
    /// "Aug 15, 11:24" — the journal's "when" column.
    let full: DateFormatter
    /// "Aug 15" — the label under a chart column.
    let day: DateFormatter

    private static var cached: (locale: Locale, stamps: JournalStamps)?

    static func current(_ locale: Locale) -> JournalStamps {
        if let existing = cached, existing.locale == locale { return existing.stamps }
        let stamps = JournalStamps(locale: locale)
        cached = (locale, stamps)
        return stamps
    }

    private init(locale: Locale) {
        full = Self.formatter(locale: locale, template: "MMMdjmm")
        day = Self.formatter(locale: locale, template: "MMMd")
    }

    private static func formatter(locale: Locale, template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: template,
                                                        options: 0,
                                                        locale: locale) ?? template
        return formatter
    }
}
