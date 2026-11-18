import SwiftUI
import AppKit

// MARK: - Uninstaller → Applications
//
// One card, one table, six columns: checkbox 20 | app | version 90 |
// last launched 110 | size 76 | files 70. Four of them sort. Header and
// rows read the same `TableSpec`, so they cannot advertise different widths —
// which is what happens when the table is measured twice (once for its own
// header, once for the row).
//
// The row has no app icon, risk badge or per-row actions column, and there is
// no search/sort strip under the header; the search field and the "not opened
// lately" chip (`apps.staleFilter`) live in the screen header.
// Reveal-in-Finder and the detail sheet are reached through a row context
// menu — the same arrangement StorageView uses for its drill-down browser.
//
// The "last launched" column is a real measurement: `AppManager` reads Spotlight's
// `kMDItemLastUsedDate` per bundle (see `lastOpenedDate(of:)` for why that
// source and not the access date). Everything that hangs off that date — the
// column, the amber over-three-months rule, the header chip and the third
// clause of the subtitle — is live. An app whose date is unknown prints
// "—", sorts last and does not count as stale.

/// Loads and renders a real application icon for a `.app` URL (cached by the
/// system). The table row does not show it; the detail sheet does.
struct AppIconView: View {
    let url: URL
    let size: CGFloat
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: Metric.control, style: .continuous)
                    .fill(Palette.surfaceControl)
                    .overlay(
                        Image(systemName: "app.dashed")
                            .font(.system(size: size * 0.45))
                            .foregroundStyle(Palette.textSecondary)
                    )
            }
        }
        .frame(width: size, height: size)
        .task(id: url) { icon = NSWorkspace.shared.icon(forFile: url.path) }
    }
}

public struct AppsView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var viewModel: AppsViewModel

    /// The uninstaller's sort, direction and stale filter live in the
    /// view; only the query and the selection belong to the view model, because
    /// the uninstall itself reads them.
    @State private var sort: AppSort = .size
    @State private var ascending = false
    @State private var staleOnly = false

    /// Set by Cancel so the idle state shows instead of the progress, until
    /// the next scan starts.
    @State private var scanCancelled = false
    /// Probed in `onAppear`: `FullDiskAccess.isGranted()` opens a file, and
    /// `body` runs on every keystroke in the search field.
    @State private var hasFullDiskAccess = true

    /// The table-density setting owns this preference, and this screen is one of
    /// the two it changes; the Uninstaller only reads it.
    @AppStorage(TableDensity.storageKey) private var density: TableDensity = .regular

    /// Regular density keeps this table's own 44pt row; compact density swaps
    /// in the shared compact row height.
    private var rowHeight: CGFloat {
        density == .compact ? Metric.rowCompact : 44
    }

    /// The four sortable columns, keyed by their `TableSpec` column.
    private enum AppSort: String {
        case name, used, size, files
    }

    public init() {}

    // MARK: Columns

    private var spec: TableSpec {
        TableSpec([
            TableCol("check", width: Metric.checkboxGlyph),
            TableCol("name", title: loc.s("apps.col.app")),
            TableCol("version", title: loc.s("apps.col.version"), width: 90),
            TableCol("used", title: loc.s("apps.col.lastUsed"), width: 110),
            TableCol("size", title: loc.s("apps.col.size"), width: 76, alignment: .trailing),
            TableCol("files", title: loc.s("apps.col.files"), width: 70, alignment: .trailing),
            TableCol("details", width: Metric.tapTarget),
        ])
    }

    public var body: some View {
        ScreenBody {
            header
            content
        }
        .background(Palette.background)
        .onAppear { hasFullDiskAccess = FullDiskAccess.isGranted() }
        .uninstallConfirmation(viewModel: viewModel, origin: .list)
        .sheet(item: $viewModel.selectedApp) { app in
            AppDetailSheet(app: app)
                .environmentObject(viewModel)
                .environmentObject(loc)
        }
    }

    // MARK: Header

    private var header: some View {
        ScreenHeader(title: loc.s("apps.title"), subtitle: subtitle) {
            // While the section is unscanned the scan button lives
            // in the centre of the empty state, and nothing here may duplicate
            // it — so the whole control group waits for a list to act on.
            if hasList {
                HStack(spacing: 8) {
                    SearchField(text: $viewModel.searchText,
                                placeholder: loc.s("apps.search"),
                                width: 170)

                    Chip(loc.s("apps.staleFilter"), isOn: staleOnly) {
                        staleOnly.toggle()
                    }
                    .fixedSize()

                    // The scan is real and the list goes stale the moment
                    // something is installed outside the app, so the way to
                    // repeat it stays reachable once there is a list.
                    Button(loc.s("common.rescan")) { startScan() }
                        .buttonStyle(.secondaryAction)
                        .fixedSize()
                }
            }
        }
    }

    /// "143 apps · 138.7 GB · 4 apps not opened in over three
    /// months" — count, total size and the stale clause.
    ///
    /// The third clause is dropped when nothing is stale rather than printed as
    /// "0 apps…", because a zero count is never printed; that is the only reason there are two
    /// subtitle keys. Counting is a single pass over the same list the header
    /// already sums.
    private var subtitle: String? {
        guard hasList else { return nil }
        let cutoff = staleCutoff
        var bytes: UInt64 = 0
        var stale = 0
        for app in viewModel.apps {
            bytes &+= app.totalSize
            if isStale(app, before: cutoff) { stale += 1 }
        }
        let apps = Fmt.plural("plural.apps", viewModel.apps.count)
        let size = Fmt.bytes(bytes)
        guard stale > 0 else { return loc.f("apps.subtitleNoStaleFmt", apps, size) }
        return loc.f("apps.subtitleFmt", apps, size,
                     loc.f("apps.staleCountFmt", Fmt.plural("plural.apps", stale)))
    }

    private var hasList: Bool {
        viewModel.hasScanned && !viewModel.apps.isEmpty && !viewModel.isLoading
    }

    // MARK: Content — the six states

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && !scanCancelled {
            state(.scanning(
                percent: viewModel.loadProgress,
                category: loc.s("apps.scanning"),
                // The progress callback carries the app being sized, but the
                // view model drops it and publishes only the fraction, so there
                // is no current path to show.
                path: "",
                cancel: { cancelScan() }
            ))
        } else if !viewModel.hasScanned || (scanCancelled && viewModel.apps.isEmpty) {
            if hasFullDiskAccess {
                state(.idle(section: loc.s("apps.title"),
                            willFind: loc.s("apps.idle"),
                            scan: { startScan() }))
            } else {
                // Scanning still works without Full Disk Access — it just
                // under-reports associated files — so "scan anyway" is offered.
                state(.noAccess(missing: loc.s("apps.noAccessMissing"),
                                openSettings: { FullDiskAccess.openSettings() },
                                scanAnyway: { startScan() }))
            }
        } else if viewModel.apps.isEmpty {
            // A Mac with zero applications means /Applications could not be
            // enumerated (`discoverAppBundles` swallows the error with `try?`),
            // not that there is nothing to uninstall.
            state(.failure(path: "/Applications", code: "EMPTY", retry: { startScan() }))
        } else if rows.isEmpty {
            state(.filterEmpty(total: viewModel.apps.count,
                               query: activeFilterLabel,
                               reset: { resetFilters() }))
        } else {
            table
        }
    }

    private func state(_ screenState: ScreenState) -> some View {
        StateView(screenState)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .card()
    }

    /// Whichever filter emptied the list — the query if there is one, otherwise
    /// the chip, so `state.noMatch.desc` names the control the user can undo.
    private var activeFilterLabel: String {
        let query = viewModel.searchText.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? loc.s("apps.staleFilter") : query
    }

    private func resetFilters() {
        viewModel.searchText = ""
        staleOnly = false
    }

    /// Starts (or restarts) the scan. Clears the local cancel flag first so a
    /// cancelled scan is not stuck showing the idle state.
    private func startScan() {
        scanCancelled = false
        viewModel.loadApps()
    }

    private func cancelScan() {
        scanCancelled = true
        viewModel.cancelScan()
    }

    // MARK: Table

    private var table: some View {
        // Resolved once per pass, not once per row: `Calendar.current` copies a
        // whole calendar, `spec` runs six `loc.s()` calls, and this table
        // re-renders on every keystroke in the search field.
        let cutoff = staleCutoff
        let spec = self.spec

        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, app in
                            row(app, cutoff: cutoff, spec: spec).staggeredAppear(index: index)
                        }
                    } header: {
                        TableHeader(spec, customKeys: ["name", "used", "size", "files"]) { key in
                            sortHeader(key, spec: spec)
                        }
                        .background(Palette.surfaceRaised)
                    }
                }
            }

            // The action footer belongs to the table card, under the rows.
            if !viewModel.batchSelection.isEmpty {
                bottomBar.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
        .animation(Motion.panelReveal, value: viewModel.batchSelection.isEmpty)
    }

    @ViewBuilder
    private func sortHeader(_ key: String, spec: TableSpec) -> some View {
        if let column = AppSort(rawValue: key) {
            SortableHeader(title: spec.column(key)?.title ?? "",
                           isActive: sort == column,
                           ascending: ascending,
                           alignment: column == .size || column == .files ? .trailing : .leading) {
                toggleSort(column)
            }
        }
    }

    /// A click sorts, a second click on the same column reverses. A fresh
    /// column starts in its natural direction — names A→Z, numbers
    /// largest first.
    private func toggleSort(_ column: AppSort) {
        if sort == column {
            ascending.toggle()
        } else {
            sort = column
            ascending = column == .name
        }
    }

    private func row(_ app: InstalledApp, cutoff: Date, spec: TableSpec) -> some View {
        let isOn = viewModel.batchSelection.contains(app.id)
        let stale = isStale(app, before: cutoff)
        let files = app.associatedFiles.count

        return TableRow(spec: spec,
                        height: rowHeight,
                        isSelected: isOn,
                        accessibility: loc.f("apps.a11y.selectFmt", app.name),
                        action: { viewModel.toggleBatch(app) }) {
            RowCheckbox(isOn: isOn)
                .column(spec, "check")

            Text(app.name)
                .font(Typo.body)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .column(spec, "name")

            Text(app.version ?? Fmt.none)
                .font(Typo.numeric(12, weight: .regular))
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                .column(spec, "version")

            // Over three months without a launch and the date goes amber.
            // `warningText`, not `warningButton`: the button amber is a fill
            // and reads 3.9:1 as 12pt text. The tooltip and the accessibility
            // value say the same thing in words, so the colour is not the only
            // cue. `loc.date` prints "—" when the launch date is unknown.
            Text(loc.date(app.lastOpened))
                .font(Typo.secondary)
                .foregroundStyle(stale ? Palette.warningText : Palette.textSecondary)
                .lineLimit(1)
                .help(stale ? loc.s("apps.staleFilter") : "")
                .accessibilityValue(Text(stale ? loc.s("apps.staleFilter") : ""))
                .column(spec, "used")

            Text(Fmt.bytes(app.totalSize))
                .font(Typo.numeric(12, weight: .regular))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .column(spec, "size")

            Text(files > 0 ? Fmt.count(files) : Fmt.none)
                .font(Typo.numeric(12, weight: .regular))
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                .column(spec, "files")

            Color.clear.column(spec, "details")
        }
        .overlay(alignment: .trailing) {
            IconButton("info.circle", label: loc.f("apps.a11y.detailsFmt", app.name)) {
                viewModel.selectedApp = app
            }
            .padding(.trailing, spec.inset)
        }
        .contextMenu {
            Button(loc.f("apps.a11y.revealFmt", app.name)) { viewModel.revealInFinder(app) }
            Button(loc.f("apps.a11y.detailsFmt", app.name)) { viewModel.selectedApp = app }
        }
    }

    // MARK: Filtering and sorting

    private var rows: [InstalledApp] {
        var list = viewModel.apps
        let query = viewModel.searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        if staleOnly {
            let cutoff = staleCutoff
            list = list.filter { isStale($0, before: cutoff) }
        }
        return list.sorted(by: precedes)
    }

    /// Direction is applied to a `ComparisonResult` rather than by negating a
    /// `<`, so ties stay ties whichever way the column points — negating would
    /// make equal rows precede each other and break the sort's ordering.
    private func precedes(_ lhs: InstalledApp, _ rhs: InstalledApp) -> Bool {
        // An app with no launch date sorts last in BOTH directions, so the pin
        // has to happen before the direction is applied: run it through `rank`
        // and a descending sort would put every "—" at the top, reading as
        // "these are the most recently used".
        if sort == .used, (lhs.lastOpened == nil) != (rhs.lastOpened == nil) {
            return rhs.lastOpened == nil
        }
        let order = rank(lhs, rhs)
        return ascending ? order == .orderedAscending : order == .orderedDescending
    }

    private func rank(_ lhs: InstalledApp, _ rhs: InstalledApp) -> ComparisonResult {
        switch sort {
        case .name:
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        case .used:
            // `precedes` has already settled every pair where exactly one date
            // is missing; two missing dates are equal.
            guard let l = lhs.lastOpened, let r = rhs.lastOpened else { return .orderedSame }
            return compare(l, r)
        case .size:
            return compare(lhs.totalSize, rhs.totalSize)
        case .files:
            return compare(lhs.associatedFiles.count, rhs.associatedFiles.count)
        }
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    // MARK: Stale — not opened in over three months

    private static let staleAfterMonths = 3

    /// The instant an app must predate to count as stale. Callers resolve it
    /// once and hand it to `isStale` for every row: `Calendar.current` copies a
    /// calendar per access, and both the filter and the subtitle walk the whole
    /// list on every keystroke in the search field.
    private var staleCutoff: Date {
        Calendar.current.date(byAdding: .month, value: -Self.staleAfterMonths, to: Date())
            ?? .distantPast
    }

    /// An app the system has no launch date for is never stale — "we do not
    /// know" is not "opened long ago", so it stays out of the chip's filter, out
    /// of the subtitle's count and off the amber colour.
    private func isStale(_ app: InstalledApp, before cutoff: Date) -> Bool {
        guard let opened = app.lastOpened else { return false }
        return opened < cutoff
    }

    // MARK: Bottom action bar

    private var bottomBar: some View {
        BottomActionBar(
            selectionLabel: loc.s("common.selected"),
            // The view model's own totals, not the filtered list's: these are
            // the apps the button will actually delete, including any hidden
            // behind the current search.
            selectionValue: viewModel.formattedBatchSize,
            selectionCount: Fmt.plural("plural.apps", viewModel.batchSelection.count),
            consequence: loc.s("apps.deleteWarning"),
            consequenceIsDestructive: true
        ) {
            Button(viewModel.isBatchWorking
                   ? loc.s("apps.uninstalling")
                   : loc.s("apps.uninstall")) {
                viewModel.prepareUninstall(viewModel.batchApps, from: .list)
            }
            .buttonStyle(PrimaryButtonStyle(tint: Palette.dangerFill))
            .disabled(viewModel.isBatchWorking || viewModel.isPreparing)
        }
    }
}

// MARK: - Detail sheet
//
// The table shows only the list; the per-app view lives here: the associated-file list, Reveal in Finder, and the single
// uninstall with its admin route all live here. It is reached from the row's
// context menu.

struct AppDetailSheet: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var viewModel: AppsViewModel
    @Environment(\.dismiss) private var dismiss
    let app: InstalledApp
    @State private var showAllFiles = false

    /// Apps with hundreds of leftover files exist (Adobe, Office); the rest is
    /// one click away rather than silently cut off.
    private let fileLimit = 50

    var body: some View {
        ScreenBody {
            headerSection
            VStack(spacing: 0) {
                locationRow
                filesSection
                bottomBar
            }
            .card()
        }
        .frame(minWidth: 680, minHeight: 470)
        .background(Palette.background)
        // A dialog on the list behind a sheet never appears, so the sheet
        // presents its own.
        .uninstallConfirmation(viewModel: viewModel, origin: .detail)
    }

    private var headerSection: some View {
        HStack(spacing: 14) {
            AppIconView(url: app.url, size: 44)
            VStack(alignment: .leading, spacing: 5) {
                ScreenHeader(title: app.name, subtitle: app.bundleIdentifier)
                    .help(app.name)
                HStack(spacing: 8) {
                    if let version = app.version {
                        Text(loc.f("apps.versionFmt", version))
                    }
                    Text(loc.f("apps.installedFmt", viewModel.installDateText(app)))
                }
                .font(Typo.footnote)
                .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    /// Where the bundle lives, with a way to jump to it.
    private var locationRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
            Text(app.path)
                .font(Typo.numeric(11, weight: .regular))
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button(loc.s("common.revealInFinder")) { viewModel.revealInFinder(app) }
                .buttonStyle(.secondaryAction(height: 26))
        }
        .padding(.horizontal, Metric.inset)
        .frame(height: Metric.utilityStrip)
        .background(Palette.surfaceFooter)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.borderHairline).frame(height: 1)
        }
    }

    private var filesSection: some View {
        VStack(spacing: 0) {
            TableSectionHeader(loc.s("apps.associated"), trailing: associatedSummary)

            if let other = app.sharedDataWith {
                TableFootnoteRow(text: loc.f("apps.sharedDataFmt",
                                             other.deletingPathExtension().lastPathComponent))
                Spacer(minLength: 0)
            } else if app.associatedFiles.isEmpty {
                TableFootnoteRow(text: loc.s("apps.noAssociated"))
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visibleFiles.enumerated()), id: \.element.id) { index, file in
                            fileRow(file).staggeredAppear(index: index)
                        }
                        if let hidden = hiddenFiles {
                            TableFootnoteRow(
                                text: loc.f("footnote.moreFmt", "\(hidden.count)", hidden.size),
                                actionTitle: loc.s("footnote.showAll"),
                                action: { showAllFiles = true }
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileRow(_ file: AssociatedFile) -> some View {
        ListRow(
            title: file.name,
            detail: file.url.path,
            detailStyle: .path,
            icon: .symbol(file.type.icon),
            // Two lines (name + path) in the 34–38pt nested-row band.
            height: Metric.nestedRow + 2,
            // Every row needs an action of its own; showing the file in Finder
            // is the one that cannot do damage.
            accessibility: loc.f("apps.a11y.revealFmt", file.name),
            action: { NSWorkspace.shared.activateFileViewerSelecting([file.url]) },
            meta: { RowValue(file.formattedSize, width: 78) })
    }

    private var associatedSummary: String {
        let bytes = app.associatedFiles.reduce(UInt64(0)) { $0 &+ $1.size }
        return loc.f("apps.assocFmt", Fmt.plural("plural.files", app.associatedFiles.count), Fmt.bytes(bytes))
    }

    private var visibleFiles: [AssociatedFile] {
        showAllFiles ? app.associatedFiles : Array(app.associatedFiles.prefix(fileLimit))
    }

    private var hiddenFiles: (count: Int, size: String)? {
        guard app.associatedFiles.count > fileLimit, !showAllFiles else { return nil }
        let rest = app.associatedFiles.dropFirst(fileLimit)
        let bytes = rest.reduce(UInt64(0)) { $0 &+ $1.size }
        return (rest.count, Fmt.bytes(bytes))
    }

    private var bottomBar: some View {
        BottomActionBar(
            selectionLabel: loc.s("apps.totalSize"),
            selectionValue: app.formattedSize,
            consequence: loc.s("apps.deleteWarning"),
            consequenceIsDestructive: true
        ) {
            Button(loc.s("common.close")) { dismiss() }
                .buttonStyle(.secondaryAction)
                .keyboardShortcut(.cancelAction)
            Button(viewModel.isUninstalling
                   ? loc.s("apps.uninstalling")
                   : loc.f("apps.uninstallFmt", app.formattedSize)) {
                viewModel.prepareUninstall([app], from: .detail)
            }
            .buttonStyle(PrimaryButtonStyle(tint: Palette.dangerFill))
            .disabled(viewModel.isUninstalling || viewModel.isPreparing)
        }
    }
}

// MARK: - Uninstall confirmation

/// The one confirmation every uninstall passes through. It is shown by
/// whichever surface asked for it — the list or the detail sheet — and states
/// what the check found: permanence, a coming password prompt, apps that will
/// be quit, data that stays.
private struct UninstallConfirmation: ViewModifier {
    @EnvironmentObject private var loc: Localizer
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: AppsViewModel
    let origin: AppsViewModel.PendingUninstall.Origin

    private var pending: AppsViewModel.PendingUninstall? {
        viewModel.pendingUninstall.flatMap { $0.origin == origin ? $0 : nil }
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0, pending != nil { viewModel.pendingUninstall = nil } }
            ),
            titleVisibility: .visible,
            presenting: pending
        ) { pending in
            Button(loc.f("apps.uninstallFmt", Fmt.bytes(Int64(pending.totalBytes))), role: .destructive) {
                Task {
                    await viewModel.confirmUninstall(pending)
                    if origin == .detail { dismiss() }
                }
            }
            Button(loc.s("common.cancel"), role: .cancel) { viewModel.pendingUninstall = nil }
        } message: { pending in
            Text(viewModel.confirmationMessage(for: pending))
        }
    }

    private var title: String {
        guard let pending else { return "" }
        if pending.apps.count == 1, let app = pending.apps.first {
            return loc.f("apps.confirmTitleFmt", app.name)
        }
        return loc.f("apps.batchConfirmFmt", Fmt.plural("plural.apps", pending.apps.count))
    }
}

private extension View {
    func uninstallConfirmation(viewModel: AppsViewModel,
                               origin: AppsViewModel.PendingUninstall.Origin) -> some View {
        modifier(UninstallConfirmation(viewModel: viewModel, origin: origin))
    }
}
