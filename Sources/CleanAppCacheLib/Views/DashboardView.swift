import SwiftUI
import AppKit

// MARK: - Smart Cleanup
//
// Four states — idle → running → done → clean — and one idea behind the "done"
// one: the user is not choosing between seven caches, they are choosing how much
// consequence to accept. So the categories are grouped by risk (safe / comes back
// on its own / gone for good) and the 288pt panel answers the question that
// follows from the choice: how much free space is left afterwards.
//
// The screen header has no scan button: rescanning lives on the circular button
// in the "Found" card header, beside the "checked at" stamp that belongs with it.

/// The three risk groups.
///
/// Membership follows the actual items: a category containing manually reviewed
/// system paths must not inherit the label of its auto-selected user caches.
private enum RiskGroup: String, CaseIterable, Identifiable {
    case safe, recreates, permanent

    var id: String { rawValue }
    var titleKey: String { "risk.group." + rawValue }

    static func of(_ category: ScanCategory, requiresReview: Bool) -> RiskGroup {
        if category == .trash { return .permanent }
        return category.isSafeToAutoClean && !requiresReview ? .safe : .recreates
    }

    func categories(in tallies: [ScanCategory: CategoryTally]) -> [ScanCategory] {
        ScanCategory.allCases.filter {
            RiskGroup.of($0, requiresReview: tallies[$0]?.requiresReview ?? false) == self
        }
    }

    /// 7×7 marker in the group header.
    @MainActor var marker: Color {
        switch self {
        case .safe:      return Palette.successFill
        case .recreates: return Palette.warningFill
        case .permanent: return Palette.dangerFill
        }
    }

    /// Share bar of an unselected row in this group.
    @MainActor var bar: Color {
        switch self {
        case .safe:      return Palette.tokens.riskSafeBar
        case .recreates: return Palette.tokens.riskCheckBar
        case .permanent: return Palette.tokens.riskPermanentBar
        }
    }
}

/// What one category contributes. Counting inside the row meant a pass over
/// every scanned item per row, on every render; one pass fills the whole table.
private struct CategoryTally {
    var items = 0
    var selected = 0
    var excluded = 0
    var bytes: UInt64 = 0
    var requiresReview = false

    var isFull: Bool { selected > 0 && selected == items - excluded }
    var isPartial: Bool { selected > 0 && !isFull }
}

public struct DashboardView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var viewModel: DashboardViewModel
    @ObservedObject private var history = CleanupHistory.shared

    @State private var pendingCleanup: DashboardViewModel.CleanupSelection?
    @State private var expandedCategory: ScanCategory?
    @State private var searchText = ""
    @State private var onlySelected = false
    /// Free-space reading behind the projection. Cached because it is a syscall
    /// and it only moves when a scan or a cleanup finishes — not when the
    /// selection changes.
    @State private var storage: StorageInfo?
    /// The roots each category was actually collected from, for the second line
    /// of the row. Walks every item, so it is recomputed per scan, not per render.
    @State private var origins: [ScanCategory: String] = [:]

    public init() {}

    private var spec: TableSpec {
        TableSpec([
            TableCol("check", width: Metric.checkboxGlyph),
            TableCol("name", title: loc.s("cleanup.col.category")),
            TableCol("share", title: loc.s("cleanup.col.share"), width: 88),
            TableCol("size", title: loc.s("cleanup.col.size"), width: 76, alignment: .trailing),
            TableCol("count", title: loc.s("cleanup.col.count"), width: 62, alignment: .trailing),
            TableCol("expand", width: Metric.tapTarget, alignment: .trailing),
        ])
    }

    public var body: some View {
        ScreenBody {
            // No button in the header: rescanning lives in the card header.
            ScreenHeader(title: loc.s("cleanup.title"), subtitle: subtitle)
            if viewModel.cleanupSkipped.needsNotice {
                ScanSkippedSummaryView(summary: viewModel.cleanupSkipped,
                                       titleKey: "scan.skipped.cleanupTitleFmt",
                                       explanationKey: "scan.skipped.cleanupExplanation")
                    .card()
            }
            content
        }
        .background(Palette.background)
        .overlay {
            if let outcome = viewModel.cleanupOutcome {
                CelebrationView(outcome: outcome) { viewModel.cleanupOutcome = nil }
            }
        }
        .onAppear {
            refreshDerived()
            announceCachedResult()
        }
        .onChange(of: viewModel.showingCachedResult) { _ in announceCachedResult() }
        .onChange(of: viewModel.lastScanDate) { _ in refreshDerived() }
        .sheet(item: $pendingCleanup) { selection in
            cleanupConfirmation(selection)
        }
    }

    private func cleanupConfirmation(_ selection: DashboardViewModel.CleanupSelection) -> some View {
        let categories = selection.categorySummaries
        return ScreenBody {
            ScreenHeader(title: loc.f("cleanup.confirmTitleFmt", Fmt.plural("plural.items", selection.count)))

            confirmationGroup(categories.filter { $0.category != .trash },
                              title: loc.s("cleanup.confirmMoveToTrash"),
                              color: Palette.accent,
                              detail: loc.s("cleanup.confirmMsgDefault"))
            confirmationGroup(categories.filter { $0.category == .trash },
                              title: loc.s("cleanup.confirmPermanent"),
                              color: Palette.dangerFill)

            if selection.reachesSystemFolders {
                Text(loc.s("cleanup.confirmAdminNote"))
                    .font(Typo.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(loc.s("common.cancel"), role: .cancel) { pendingCleanup = nil }
                    .buttonStyle(.secondaryAction)
                    .keyboardShortcut(.cancelAction)
                Button(loc.f("cleanup.cleanFmt", Fmt.bytes(selection.size)), role: .destructive) {
                    pendingCleanup = nil
                    Task { await viewModel.cleanSelectedItems(selection: selection) }
                }
                .buttonStyle(.dangerAction)
                .disabled(viewModel.isCleaning || viewModel.isScanning)
            }
        }
        .frame(width: 540)
        .background(Palette.background)
    }

    @ViewBuilder
    private func confirmationGroup(_ categories: [DashboardViewModel.CleanupSelection.CategorySummary],
                                   title: String, color: Color, detail: String? = nil) -> some View {
        if !categories.isEmpty {
            let total = categories.reduce(UInt64(0)) { $0 &+ $1.bytes }
            VStack(spacing: 0) {
                TableGroupHeader(color: color, title: title, total: Fmt.bytes(total))
                ForEach(categories) { category in
                    HStack(spacing: 12) {
                        Text(catName(category.category))
                            .font(Typo.body)
                            .foregroundStyle(Palette.textPrimary)
                        Spacer(minLength: 0)
                        Text(Fmt.plural("plural.items", category.count))
                            .font(Typo.footnote)
                            .foregroundStyle(Palette.textSecondary)
                        Text(Fmt.bytes(category.bytes))
                            .font(Typo.numeric(12, weight: .regular))
                            .foregroundStyle(Palette.textPrimary)
                            .frame(minWidth: 82, alignment: .trailing)
                    }
                    .padding(.horizontal, Metric.inset)
                    .frame(minHeight: Metric.nestedRow)
                }
                if let detail {
                    TableFootnoteRow(text: detail)
                }
            }
            .card()
        }
    }

    // MARK: Subtitle (one line per state)

    private var subtitle: String? {
        guard !viewModel.isScanning else { return nil }
        guard let result = viewModel.scanResult else { return loc.s("cleanup.idleSubtitle") }

        let tallies = tally(result)
        let listed = categories(of: tallies)
        if !listed.isEmpty {
            let total = listed.reduce(UInt64(0)) { $0 &+ (tallies[$1]?.bytes ?? 0) }
            return loc.f("cleanup.foundSubtitleFmt",
                         Fmt.bytes(total),
                         Fmt.plural("plural.categories", listed.count),
                         loc.dateTime(viewModel.lastScanDate))
        }
        if let record = lastCleanup {
            return loc.f("cleanup.lastCleanupFmt", loc.dateTime(record.date))
        }
        return loc.s("cleanup.idleSubtitle")
    }

    private var lastCleanup: CleanupRecord? {
        history.records.first { $0.source == .smartCleanup }
    }

    // MARK: Content — one of the four states

    @ViewBuilder
    private var content: some View {
        if viewModel.isScanning {
            // Percent, a 280×5 bar, category, path, Cancel.
            StateView(.scanning(
                percent: viewModel.scanProgress?.percent ?? 0,
                category: viewModel.scanProgress.map { catName($0.currentCategory) } ?? "",
                path: viewModel.scanProgress?.currentPath ?? "",
                cancel: { viewModel.cancelScan() }
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .card()
        } else if let result = viewModel.scanResult {
            let tallies = tally(result)
            let listed = categories(of: tallies)
            if listed.isEmpty && result.skipped.needsNotice {
                VStack(alignment: .leading, spacing: 0) {
                    CardHeader(title: loc.s("scan.skipped.noCleanable")) {
                        RefreshStamp(text: viewModel.lastScanDate.map { loc.f("common.checkedAt", Fmt.clock($0)) },
                                     label: loc.s("common.rescan.tooltip")) { viewModel.startScan() }
                    }
                    scanCoverage
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
            } else if listed.isEmpty {
                cleanState
            } else {
                found(result, tallies: tallies, listed: listed)
            }
        } else {
            StateView(.idle(section: loc.s("cleanup.title"),
                            willFind: loc.s("cleanup.willFind"),
                            scan: { viewModel.startScan() }))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
        }
    }

    /// "Clean" plus what the last cleanup actually did — the numbers come
    /// from the History record it wrote, so they are never re-derived here.
    private var cleanState: some View {
        let record = lastCleanup
        let message = record.map {
            outcomeText(freed: $0.freedBytes, trashed: $0.trashedBytes)
                + " · " + Fmt.plural("plural.objects", $0.itemCount)
        }
        return StateView(.clean(checked: message ?? loc.s("cleanup.scanned"),
                                // The date is already in the subtitle when a
                                // cleanup is what emptied this screen.
                                lastScan: message == nil ? viewModel.lastScanDate : nil,
                                rescan: { viewModel.startScan() }))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .card()
    }

    /// Bytes moved to the Trash still occupy the disk, so they are never
    /// counted as freed. A record with neither amount reads as "freed zero".
    private func outcomeText(freed: UInt64, trashed: UInt64) -> String {
        if trashed == 0 { return loc.f("outcome.freedFmt", Fmt.bytes(freed)) }
        if freed == 0 { return loc.f("outcome.trashedFmt", Fmt.bytes(trashed)) }
        return loc.f("outcome.bothFmt", Fmt.bytes(freed), Fmt.bytes(trashed))
    }

    // MARK: Done — table + 288pt panel

    private func found(_ result: ScanResult,
                       tallies: [ScanCategory: CategoryTally],
                       listed: [ScanCategory]) -> some View {
        // Once per pass, not once per row: `spec` runs `loc.s()` per column.
        let spec = self.spec
        let candidateSpec = TableSpec(spec.columns.filter { $0.key != "share" })
        let peak = self.peak(tallies)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .top, spacing: Metric.cardGap) {
            VStack(spacing: 0) {
                foundHeader(tallies: tallies, listed: listed)
                HStack(spacing: 12) {
                    SearchField(text: $searchText, placeholder: loc.s("cleanup.search"))
                    Toggle(loc.s("cleanup.onlySelected"), isOn: $onlySelected)
                        .font(Typo.secondary)
                        .toggleStyle(.checkbox)
                }
                .padding(.horizontal, spec.inset)
                .padding(.vertical, 8)
                scanCoverage
                if onlySelected || !query.isEmpty {
                    filteredResults(result, query: query, categories: listed, spec: candidateSpec)
                } else {
                    TableHeader(spec)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(RiskGroup.allCases) { group in
                                let members = group.categories(in: tallies).filter { listed.contains($0) }
                                if !members.isEmpty {
                                    groupHeader(group, members: members, tallies: tallies, in: result)
                                    ForEach(members) { category in
                                        row(category, group: group,
                                            tally: tallies[category] ?? CategoryTally(),
                                            peak: peak,
                                            index: listed.firstIndex(of: category) ?? 0,
                                            in: result,
                                            spec: spec)
                                        if expandedCategory == category {
                                            ForEach(result.items(for: category)) { item in
                                                candidateRow(item, spec: candidateSpec)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .card()

            panel
                .frame(width: Metric.heroColumn)
                .frame(maxHeight: .infinity)
                .card()
        }
        .frame(maxHeight: .infinity)
    }

    private var scanCoverage: some View {
        ScanSkippedSummaryView(summary: viewModel.displayedSkipSummary,
                               cached: viewModel.showingCachedResult,
                               rescan: { viewModel.startScan() })
    }

    private func filteredResults(_ result: ScanResult, query: String,
                                 categories: [ScanCategory], spec: TableSpec) -> some View {
        var matches: [ScanCategory: [CleanableItem]] = [:]
        var hiddenSelection = false
        for item in result.items {
            let selected = viewModel.selectedItems.contains(item.id)
            guard !onlySelected || selected else { continue }
            if query.isEmpty || item.url.path.localizedStandardContains(query) {
                matches[item.category, default: []].append(item)
            } else if selected {
                hiddenSelection = true
            }
        }
        return VStack(spacing: 0) {
            if hiddenSelection {
                Text(loc.s("cleanup.filterScope"))
                    .font(Typo.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, spec.inset)
                    .padding(.bottom, 8)
            }
            if matches.isEmpty {
                Text(loc.s("cleanup.noMatches"))
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(categories) { category in
                            if let items = matches[category] {
                                TableGroupHeader(color: Palette.accent, title: catName(category),
                                                 total: Fmt.plural("plural.items", items.count))
                                ForEach(items) { item in
                                    candidateRow(item, spec: spec)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 44pt card header: "Found" · total · categories · checked at · refresh.
    private func foundHeader(tallies: [ScanCategory: CategoryTally],
                             listed: [ScanCategory]) -> some View {
        let total = listed.reduce(UInt64(0)) { $0 &+ (tallies[$1]?.bytes ?? 0) }
        return CardHeader(
            title: loc.s("cleanup.found"),
            detail: loc.f("cleanup.foundDetailFmt",
                          Fmt.bytes(total),
                          Fmt.plural("plural.categories", listed.count))
        ) {
            RefreshStamp(text: viewModel.lastScanDate.map { loc.f("common.checkedAt", Fmt.clock($0)) },
                         label: loc.s("common.rescan.tooltip")) {
                viewModel.startScan()
            }
        }
    }

    private func groupHeader(_ group: RiskGroup,
                             members: [ScanCategory],
                             tallies: [ScanCategory: CategoryTally],
                             in result: ScanResult) -> some View {
        let bytes = members.reduce(UInt64(0)) { $0 &+ (tallies[$1]?.bytes ?? 0) }
        let selectable = members.filter { category in
            guard let tally = tallies[category] else { return false }
            return tally.items > tally.excluded
        }
        let allOn = selectable.allSatisfy { tallies[$0]?.isFull ?? false }
        // The header shows one link, and which one depends on the group's state.
        // A partly selected category counts as not selected, so Select All stays
        // offered until every item of every member is queued.
        let selectAll: (() -> Void)? = allOn ? nil : { select(members, in: result, on: true) }
        let clear: (() -> Void)? = allOn && !selectable.isEmpty ? { select(members, in: result, on: false) } : nil
        return TableGroupHeader(
            color: group.marker,
            title: loc.s(group.titleKey),
            total: Fmt.bytes(bytes),
            selectAllTitle: loc.s("common.selectAll"),
            clearTitle: loc.s("common.deselect"),
            onSelectAll: selectAll,
            onClear: clear
        )
    }

    private func row(_ category: ScanCategory,
                     group: RiskGroup,
                     tally: CategoryTally,
                     peak: UInt64,
                     index: Int,
                     in result: ScanResult,
                     spec: TableSpec) -> some View {
        // The row is a category, but the selection underneath is per item: some
        // roots inside a category are opt-in (`/var/log`, `/tmp`), so a category
        // can be partly queued. A tick means every item is queued and a bar means
        // only some are, so the sizes of ticked rows never add up to more than
        // the "To delete" panel. The highlight and the share bar mean "anything
        // queued". A click follows the macOS mixed-checkbox convention: off or
        // partial claims the whole category, full clears it.
        let isOn = tally.selected > 0
        let full = tally.isFull
        let partial = tally.isPartial
        let accessibility = partial
            ? catName(category) + ", " + loc.s("cleanup.partialSelection")
            : catName(category)

        return TableRow(spec: spec,
                        height: Metric.rowDetailed,
                        isSelected: isOn,
                        accessibility: accessibility,
                        action: tally.items > tally.excluded ? { select([category], in: result, on: !full) } : nil) {
            RowCheckbox(isOn: full, mixed: partial)
                .column(spec, "check")

            VStack(alignment: .leading, spacing: 2) {
                Text(catName(category))
                    .font(Typo.bodyStrong)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(origins[category] ?? Fmt.none)
                    .font(Typo.numeric(11, weight: .regular))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .column(spec, "name")

            // The share is measured against the largest row, not the sum.
            ShareBar(fraction: peak > 0 ? Double(tally.bytes) / Double(peak) : 0,
                     color: isOn ? Palette.accent : group.bar)
                .column(spec, "share")

            Text(Fmt.bytes(tally.bytes))
                .font(Typo.numeric(13))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .column(spec, "size")

            Text(Fmt.count(tally.items))
                .font(Typo.numeric(12, weight: .regular))
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                .column(spec, "count")
            Color.clear.column(spec, "expand")
        }
        .overlay(alignment: .trailing) {
            let expanded = expandedCategory == category
            IconButton(expanded ? "chevron.down" : "chevron.right",
                       label: loc.f(expanded ? "cleanup.collapseCategoryFmt" : "cleanup.expandCategoryFmt",
                                    catName(category))) {
                expandedCategory = expanded ? nil : category
            }
            .padding(.trailing, spec.inset)
        }
        .staggeredAppear(index: index)
    }

    private func candidateRow(_ item: CleanableItem, spec: TableSpec) -> some View {
        let excluded = viewModel.excludedItemIDs.contains(item.id)
        let selected = !excluded && viewModel.selectedItems.contains(item.id)
        let path = item.url.path
        return TableRow(spec: spec, height: Metric.rowDetailed, isSelected: selected,
                        accessibility: excluded ? path + " · " + loc.s("scan.skipped.userExcluded")
                                                : "\(path) · \(Fmt.bytes(item.size))",
                        action: excluded ? nil : { viewModel.toggleSelection(for: item) }) {
            RowCheckbox(isOn: selected).opacity(excluded ? 0.4 : 1).column(spec, "check")
            VStack(alignment: .leading, spacing: 2) {
                Text(excluded ? item.url.lastPathComponent + " · " + loc.s("scan.skipped.userExcluded")
                              : item.url.lastPathComponent)
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textPrimary)
                Text(path)
                    .font(Typo.numeric(11, weight: .regular))
                    .foregroundStyle(Palette.textSecondary)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            .column(spec, "name")
            Text(Fmt.bytes(item.size))
                .font(Typo.numeric(12, weight: .regular))
                .foregroundStyle(Palette.textSecondary)
                .column(spec, "size")
            Color.clear.column(spec, "count")
            Color.clear.column(spec, "expand")
        }
        .help(path)
        .contextMenu {
            if viewModel.excludedPaths.contains(item.url.standardizedFileURL.path) {
                Button(loc.s("cleanup.removeExclusion")) {
                    viewModel.removeExclusion(item.url.standardizedFileURL.path)
                }
            } else if !excluded {
                Button(loc.s("cleanup.alwaysSkip")) { viewModel.alwaysSkip(item.url) }
            }
            Button(loc.s("common.revealInFinder")) {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Button(loc.s("cleanup.copyPath")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
    }

    // MARK: Panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(loc.s("cleanup.toDelete"))
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 8)
                Text(selectionCount)
                    .font(Typo.numeric(11, weight: .regular))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }

            Figure(selected.number, unit: selected.unit, role: Typo.bigFigure)
                .padding(.top, 8)
                .contentTransition(.numericText())
                .animation(Motion.content, value: viewModel.selectedSize)

            Rectangle().fill(Palette.borderHairline).frame(height: 1)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Text(loc.s("cleanup.freeOnDisk"))
                .font(Typo.secondary)
                .foregroundStyle(Palette.textSecondary)
                .padding(.bottom, 10)

            SplitBar(usedFraction: usedFraction, freedFraction: freedFraction)
                .animation(Motion.content, value: freedFraction)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(projection)
                    .font(Typo.numeric(13, weight: .regular))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Fmt.delta(viewModel.selectedTrashSize))
                    .font(Typo.numeric(12))
                    .foregroundStyle(Palette.accentText)
                    .lineLimit(1)
            }
            .padding(.top, 10)

            // What goes to the Trash still occupies the disk until the Trash
            // is emptied; the projection above counts only what is erased.
            if viewModel.selectedSize > viewModel.selectedTrashSize {
                Text(loc.f("cleanup.afterTrashFmt",
                           Fmt.bytes(viewModel.selectedSize - viewModel.selectedTrashSize)))
                    .font(Typo.footnote)
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }

            Spacer(minLength: 18)

            // Only when the selection actually contains the one category that is
            // erased rather than trashed — a standing warning is one the eye
            // learns to skip.
            if viewModel.selectionIncludesTrash {
                Text(loc.s("cleanup.trashWarning"))
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.warningBody)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .notice(.warning)
                    .padding(.bottom, 12)
            }

            Button {
                pendingCleanup = viewModel.prepareCleanup()
            } label: {
                // The style sizes its background to the label, so the expansion
                // has to happen inside it.
                Text(cleanTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle(height: Metric.heroButton))
            .disabled(viewModel.selectedItems.isEmpty || viewModel.isCleaning)

            // Stacked, not side by side. Half of the 288pt panel leaves about
            // 130pt per button and the Russian "only safe" label needs more, so
            // side by side it truncates to a word fragment that tells the user
            // nothing, and shrinking the type to fit makes it unreadable.
            VStack(spacing: 8) {
                Button { viewModel.selectSafe() } label: {
                    Text(loc.s("cleanup.onlySafe"))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
                Button { viewModel.deselectAll() } label: {
                    Text(loc.s("cleanup.deselectAll"))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, 8)

            if viewModel.isCleaning {
                GaugeBar(fraction: viewModel.cleaningProgress, height: 5)
                    .padding(.top, 10)
                    .animation(Motion.progress, value: viewModel.cleaningProgress)
            }
        }
        .padding(20)
    }

    private var selected: Fmt.Value { Fmt.size(viewModel.selectedSize) }

    private var selectionCount: String {
        let count = viewModel.selectedItems.count
        guard count > 0 else { return loc.s("cleanup.nothingSelected") }
        return Fmt.plural("plural.objects", count)
    }

    private var cleanTitle: String {
        guard !viewModel.selectedItems.isEmpty else { return loc.s("cleanup.hero.clean") }
        return loc.f("cleanup.cleanFmt", Fmt.bytes(viewModel.selectedSize))
    }

    /// "120.9 → 128.2 GB". The unit is printed once when both halves land on the
    /// same one, which is what makes the pair read as one measurement.
    ///
    /// Only erased bytes count: a move to the Trash leaves the free space as
    /// it was until the Trash is emptied.
    private var projection: String {
        guard let storage else { return Fmt.none }
        let now = Fmt.size(storage.freeBytes)
        let after = Fmt.size(storage.freeBytes &+ viewModel.selectedTrashSize)
        return loc.f("cleanup.projectionFmt",
                     now.unit == after.unit ? now.number : now.joined,
                     after.joined)
    }

    /// Space already in use, minus what the selection would give back now.
    private var usedFraction: Double {
        guard let storage, storage.totalBytes > 0 else { return 0 }
        let erased = viewModel.selectedTrashSize
        let used = storage.usedBytes > erased ? storage.usedBytes - erased : 0
        return Double(used) / Double(storage.totalBytes)
    }

    private var freedFraction: Double {
        guard let storage, storage.totalBytes > 0 else { return 0 }
        return Double(min(viewModel.selectedTrashSize, storage.usedBytes)) / Double(storage.totalBytes)
    }

    // MARK: Selection

    /// Selecting is a set operation on the whole category: item-by-item toggling
    /// published a change per item, and a cache folder can hold thousands.
    private func select(_ categories: [ScanCategory], in result: ScanResult, on: Bool) {
        let ids = categories.flatMap { result.items(for: $0).map(\.id) }
            .filter { !viewModel.excludedItemIDs.contains($0) }
        guard !ids.isEmpty else { return }
        if on {
            viewModel.selectedItems.formUnion(ids)
        } else {
            viewModel.selectedItems.subtract(ids)
        }
    }

    // MARK: Derived data

    /// One pass over the scan result for every number the table needs.
    private func tally(_ result: ScanResult) -> [ScanCategory: CategoryTally] {
        var tallies: [ScanCategory: CategoryTally] = [:]
        for item in result.items {
            var entry = tallies[item.category] ?? CategoryTally()
            entry.items += 1
            if viewModel.excludedItemIDs.contains(item.id) {
                entry.excluded += 1
            } else {
                entry.bytes &+= item.size
                entry.requiresReview = entry.requiresReview || !item.autoSelect
                if viewModel.selectedItems.contains(item.id) { entry.selected += 1 }
            }
            tallies[item.category] = entry
        }
        return tallies
    }

    /// Categories with something in them, in risk-group order. A category the
    /// scan found nothing in is not a row that says "0" — it is not a row.
    private func categories(of tallies: [ScanCategory: CategoryTally]) -> [ScanCategory] {
        RiskGroup.allCases.flatMap { group in
            group.categories(in: tallies).filter { (tallies[$0]?.items ?? 0) > 0 }
        }
    }

    private func peak(_ tallies: [ScanCategory: CategoryTally]) -> UInt64 {
        tallies.values.map(\.bytes).max() ?? 0
    }

    private func refreshDerived() {
        storage = StorageInfo.read()
        guard let result = viewModel.scanResult else {
            origins = [:]
            return
        }
        var map: [ScanCategory: String] = [:]
        for category in ScanCategory.allCases {
            map[category] = originText(result.items(for: category))
        }
        origins = map
    }

    /// Where a category's items were actually collected from. The scanner reads
    /// each category from at most two roots, so this is the roots it really used
    /// — the app has no per-category description to print here.
    private func originText(_ items: [CleanableItem]) -> String {
        var roots: [String] = []
        for item in items {
            let parent = item.url.deletingLastPathComponent().path
            guard !roots.contains(parent) else { continue }
            roots.append(parent)
            if roots.count == 2 { break }
        }
        guard !roots.isEmpty else { return Fmt.none }
        return roots.map(abbreviated).joined(separator: " · ")
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + String(path.dropFirst(home.count))
    }

    // MARK: Cached-result toast

    /// Without this announcement a restored result up to 24 hours old looks
    /// freshly scanned.
    private func announceCachedResult() {
        // `onAppear` re-runs on every return to this tab while the cache flag
        // stays set (up to 24 h) — without the once-guard each visit stacked
        // another identical toast and re-fired the VoiceOver announcement.
        guard viewModel.showingCachedResult, !viewModel.cachedResultAnnounced,
              let scanned = viewModel.lastScanDate else { return }
        viewModel.cachedResultAnnounced = true
        ToastCenter.shared.show(Toast(
            style: .cached,
            title: loc.s("toast.cached.title"),
            message: loc.f("toast.cached.bodyFmt", loc.dateTime(scanned)),
            actionTitle: loc.s("toast.cached.action"),
            duration: 10,
            action: { viewModel.startScan() }
        ))
    }

    private func catName(_ category: ScanCategory) -> String {
        loc.s(category.titleKey)
    }
}
