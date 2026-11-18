import SwiftUI
import AppKit

// MARK: - Large Files
//
// One table, three column filters — kind / modified / size — and nothing above
// it. A strip of a slider and two segmented controls above the table needs
// about 640pt and cannot fit the minimum window, so every filter lives in the
// column header it belongs to. Only one of their menus may be open
// at a time, which is what the single shared `openFilter` key enforces.
//
// Two deliberate details:
//
//   • the file name is 13pt **regular** — it is data, not a heading;
//   • the sort is size descending and there is no sort control, so the order the
//     view model already publishes is the order on screen.
//
// One control is *not* a filter: how big a file
// has to be for `find` to return it at all. That one cannot move into a column,
// because a column filter can only narrow rows that exist and this decides which
// rows are ever fetched. It sits in the screen header's trailing slot instead,
// next to the whole-disk chip, which
// is the same kind of value. Both discard the results when they change: `find`
// never returned what they excluded, so the list on screen cannot be relabelled
// under a threshold or a scope it was not produced with.

/// The "modified" column filter. Measured on the modification date, which is what the column
/// shows — the two must agree or the filter contradicts the value beside it.
private enum AgeBand: String, Codable, CaseIterable, Identifiable {
    case all, week, month, quarter, year

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .all:     return "common.all"
        case .week:    return "large.age.week"
        case .month:   return "large.age.month"
        case .quarter: return "large.age.quarter"
        case .year:    return "large.age.year"
        }
    }

    /// A file with no modification date cannot be shown to satisfy any band, so
    /// it drops out as soon as one is chosen rather than being claimed as a match.
    func admits(_ date: Date?) -> Bool {
        guard self != .all else { return true }
        guard let date else { return false }
        let days = Date().timeIntervalSince(date) / 86_400
        switch self {
        case .all:     return true
        case .week:    return days <= 7
        case .month:   return days <= 30
        case .quarter: return days >= 90
        case .year:    return days >= 365
        }
    }
}

/// The "size" column filter. A display filter over what the scan already found — not the
/// scan threshold, which lives in the view model.
private enum SizeBand: String, Codable, CaseIterable, Identifiable {
    case all, mb500, gb1, gb5, gb10

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .all:   return "common.all"
        case .mb500: return "large.size.500mb"
        case .gb1:   return "large.size.1gb"
        case .gb5:   return "large.size.5gb"
        case .gb10:  return "large.size.10gb"
        }
    }

    /// Decimal, like `Fmt` — so "from 1 GB" admits exactly what the size column
    /// prints as 1 GB and above.
    var minimumBytes: UInt64 {
        switch self {
        case .all:   return 0
        case .mb500: return 500_000_000
        case .gb1:   return 1_000_000_000
        case .gb5:   return 5_000_000_000
        case .gb10:  return 10_000_000_000
        }
    }
}

/// "4 months ago" for the modified column.
///
/// Cached per locale: a `RelativeDateTimeFormatter` costs about a millisecond to
/// build, and the column renders one per visible row per render.
@MainActor
private enum RelativeDate {
    private static var cached: (locale: Locale, formatter: RelativeDateTimeFormatter)?

    static func text(_ date: Date?) -> String {
        guard let date else { return Fmt.none }
        let locale = Localizer.shared.locale
        let formatter: RelativeDateTimeFormatter
        if let existing = cached, existing.locale == locale {
            formatter = existing.formatter
        } else {
            let made = RelativeDateTimeFormatter()
            made.unitsStyle = .full
            made.locale = locale
            cached = (locale, made)
            formatter = made
        }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

public struct LargeFilesView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var viewModel: LargeFilesViewModel

    @State private var kindFilter: FileKind?
    @State private var ageFilter: AgeBand = .all
    @State private var sizeFilter: SizeBand = .all
    /// One menu open at a time. All three filters share this key.
    @State private var openFilter: String?

    /// Why the last scan came back empty.
    ///
    /// `LargeFilesViewModel.scanForLargeFiles` swallows every failure
    /// (`catch { return [] }`) and publishes no error, so "empty" and "broken"
    /// arrive as the same value. The view reconstructs the reason once, when the
    /// scan ends — otherwise a missing `find` or an unreadable root would render
    /// as the "clean" empty state, which is a lie about the disk.
    @State private var emptyReason: EmptyReason = .clean
    @State private var lastScanDate: Date?
    /// A cancelled scan is not a clean disk.
    @State private var scanCancelled = false
    /// The scope the files on screen came from. Changing the chip discards the
    /// results, so the view model's scope always names what was measured — and
    /// unlike view `@State` it survives the tab switch that recreates this view,
    /// so a whole-disk finding is not relabelled as a home-folder one on return.
    private struct SearchConfiguration: Codable {
        let scope: LargeFilesViewModel.SearchScope
        let folder: URL?
        let minimum: LargeFilesViewModel.MinSize
        let lastUsed: LargeFilesViewModel.AgeFilter
        let kind: FileKind?
        let modified: AgeBand
        let resultSize: SizeBand
    }

    private var profiles: some View {
        SearchProfilesMenu(key: "searchProfiles.largeFiles",
                           configuration: SearchConfiguration(
                            scope: viewModel.searchScope, folder: viewModel.customSearchFolder,
                            minimum: viewModel.minSize, lastUsed: viewModel.ageFilter, kind: kindFilter,
                            modified: ageFilter, resultSize: sizeFilter),
                           chooseFolder: { url in discardResults { viewModel.setCustomSearchFolder(url) } },
                           run: runProfile)
            .disabled(viewModel.isDeleting)
    }

    private func runProfile(_ profile: SearchConfiguration) {
        discardResults {
            viewModel.setSearchScope(profile.scope)
            if let folder = profile.folder { viewModel.setCustomSearchFolder(folder) }
            viewModel.setMinSize(profile.minimum)
            viewModel.ageFilter = profile.lastUsed
        }
        kindFilter = profile.kind
        ageFilter = profile.modified
        sizeFilter = profile.resultSize
        runScan()
    }

    /// Mirrors `largeFileResultLimit` in the view model, which caps the result
    /// set before it is published. The count is not exposed, so the footnote that
    /// labels the truncation has to know it here.
    private let resultCap = 500

    private enum EmptyReason: Equatable {
        case clean
        case noAccess
        case failure(path: String, code: String)
    }

    public init() {}

    /// checkbox 20 | file | kind 104 | modified 128 | size 80.
    private var spec: TableSpec {
        TableSpec([
            TableCol("check", width: Metric.checkboxGlyph),
            TableCol("file", title: loc.s("large.col.file")),
            TableCol("kind", title: loc.s("large.col.kind"), width: 104),
            TableCol("changed", title: loc.s("large.col.changed"), width: 128),
            TableCol("size", title: loc.s("large.col.size"), width: 80, alignment: .trailing),
        ])
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScreenBody {
                header
                content
            }
            if viewModel.selectedCount > 0 {
                bottomBar
            }
        }
        .background(Palette.background)
        .animation(Motion.panelReveal, value: viewModel.selectedCount > 0)
        // Clicking anywhere else closes the open filter menu.
        .onTapGesture { openFilter = nil }
        // Without this, leaving the tab leaves a whole-disk `find` running orphaned.
        // Through the view's own cancel, so `finishScan` cannot mistake the
        // kill for a scan that ended and diagnose its emptiness.
        .onDisappear { cancelScan() }
        .onChange(of: viewModel.isScanning) { scanning in
            if !scanning { finishScan() }
        }
    }

    // MARK: Header

    private var header: some View {
        ScreenHeader(title: loc.s("large.title"), subtitle: subtitle) {
            if !viewModel.isScanning {
                HStack(spacing: 8) {
                    scanParameters
                    profiles
                    if hasResults && hasActiveFilter {
                        Button(loc.s("common.resetFilters")) { resetFilters() }
                            .buttonStyle(.secondaryAction)
                    }
                    // The scan action sits in the centre of the empty state, so
                    // this appears only once there is something to rescan.
                    if hasResults {
                        Button(loc.s("common.rescan")) { runScan() }
                            .buttonStyle(.secondaryAction)
                    }
                }
            }
        }
    }

    /// The two scan inputs, in the order they read: how big, then how far.
    ///
    /// `SegmentedControl` is the component for a closed set of mutually
    /// exclusive values, and `.fixedSize()` keeps it hugging its labels — a
    /// segmented control is greedy by default and would eat the whole header.
    private var scanParameters: some View {
        HStack(spacing: 8) {
            SegmentedControl(selection: minSizeBinding,
                             options: LargeFilesViewModel.MinSize.allCases.map {
                                 SegmentOption(value: $0, label: loc.s($0.titleKey))
                             })
                .fixedSize()
                // The table has a size column filter of its own, over the results.
                // The tooltip is what tells the two apart.
                .help(loc.s("scan.minSize"))

            // Whole-disk scanning has no other entry point in the app, so the
            // scope is offered here as a chip.
            if let folder = viewModel.customSearchFolder {
                Button { change(scope: .home) } label: {
                    Label(folder.lastPathComponent, systemImage: "xmark.circle")
                        .lineLimit(1)
                }
                .help(folder.path)
            } else {
                Chip(loc.s("large.wholeDisk"),
                     isOn: viewModel.searchScope == .entireDisk) {
                    change(scope: viewModel.searchScope == .entireDisk ? .home : .entireDisk)
                }
            }
        }
    }

    private var minSizeBinding: Binding<LargeFilesViewModel.MinSize> {
        Binding(get: { viewModel.minSize }, set: { change(minSize: $0) })
    }

    private func change(minSize new: LargeFilesViewModel.MinSize) {
        guard new != viewModel.minSize else { return }
        discardResults { viewModel.setMinSize(new) }
    }

    private func change(scope new: LargeFilesViewModel.SearchScope) {
        guard new != viewModel.searchScope || viewModel.customSearchFolder != nil else { return }
        discardResults { viewModel.setSearchScope(new) }
    }

    /// Applies a scan-parameter change and puts the screen back into its idle
    /// state, so the next scan is the user's decision rather than a silent
    /// relabelling of the last one.
    ///
    /// `scanCancelled` is raised first: `finishScan` runs whenever `isScanning`
    /// falls, and the view model drops an in-flight scan here. That is not a scan
    /// that ended, so its emptiness must not be diagnosed as "clean" or, worse,
    /// send `diagnoseEmptyResult` to open the TCC database for nothing.
    private func discardResults(_ apply: () -> Void) {
        scanCancelled = true
        apply()
        lastScanDate = nil
        emptyReason = .clean
        // The three column filters narrow results that are gone; carrying
        // them over would greet the next scan with "nothing matches".
        resetFilters()
    }

    /// "Found 12 files · 51.04 GB · home folder search" — counted over
    /// what is actually on screen, so it agrees with the table under every filter.
    private var subtitle: String? {
        guard hasResults else { return nil }
        let shown = visible
        let bytes = shown.reduce(UInt64(0)) { $0 &+ $1.size }
        return loc.f("scan.subtitleFmt",
                     Fmt.plural("plural.files", shown.count),
                     Fmt.bytes(bytes),
                     scopeNote)
    }

    private var scopeNote: String {
        if let folder = viewModel.customSearchFolder { return folder.path }
        return loc.s(viewModel.searchScope == .home ? "large.scope.home" : "large.scope.disk")
    }

    private var hasResults: Bool {
        viewModel.hasScanned && !viewModel.isScanning && !viewModel.files.isEmpty
    }

    // MARK: Filtering

    /// The view model publishes the list already sorted by size descending, the
    /// order the screen shows; the three column filters narrow it without reordering it.
    private var visible: [LargeFile] {
        viewModel.filteredFiles.filter { file in
            (kindFilter == nil || FileKind.of(file.name) == kindFilter)
                && ageFilter.admits(file.modified)
                && file.size >= sizeFilter.minimumBytes
        }
    }

    private var hasActiveFilter: Bool {
        kindFilter != nil || ageFilter != .all || sizeFilter != .all
    }

    /// What `.filterEmpty` names as the filter that matched nothing.
    private var activeFilterSummary: String {
        var parts: [String] = []
        if let kindFilter { parts.append(loc.s(kindFilter.titleKey)) }
        if ageFilter != .all { parts.append(loc.s(ageFilter.titleKey)) }
        if sizeFilter != .all { parts.append(loc.s(sizeFilter.titleKey)) }
        return parts.joined(separator: " · ")
    }

    private func resetFilters() {
        kindFilter = nil
        ageFilter = .all
        sizeFilter = .all
        openFilter = nil
    }

    // MARK: Content — table or state

    @ViewBuilder
    private var content: some View {
        if viewModel.isScanning {
            StateView(.scanning(
                // The view model reports the path it is stat-ing but no progress
                // fraction, so the bar stays at zero rather than inventing one.
                percent: 0,
                category: loc.s("large.scanning"),
                path: viewModel.currentScanPath,
                cancel: { cancelScan() }
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .card()
        } else if !viewModel.hasScanned {
            idleState
        } else if viewModel.files.isEmpty {
            emptyState
        } else if visible.isEmpty {
            // The filter, not the disk, is what is empty.
            StateView(.filterEmpty(
                total: viewModel.files.count,
                query: activeFilterSummary,
                reset: { resetFilters() }
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .card()
        } else {
            table
        }
    }

    private var idleState: some View {
        StateView(.idle(
            section: loc.s("large.title"),
            willFind: loc.s("large.idle"),
            scan: { runScan() }
        ))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }

    @ViewBuilder
    private var emptyState: some View {
        if scanCancelled {
            idleState
        } else {
            switch emptyReason {
            case .clean:
                StateView(.clean(
                    checked: loc.f("large.checkedFmt", scopeNote, viewModel.minSizeText),
                    lastScan: lastScanDate,
                    rescan: { runScan() }
                ))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()

            case .noAccess:
                StateView(.noAccess(
                    missing: loc.s("fda.subtitle"),
                    openSettings: { FullDiskAccess.openSettings() },
                    scanAnyway: { runScan() }
                ))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()

            case let .failure(path, code):
                StateView(.failure(
                    path: path,
                    code: code,
                    retry: { runScan() },
                    copyDetails: nil
                ))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
            }
        }
    }

    // MARK: Table

    private var table: some View {
        // Once per pass: `spec` runs five `loc.s()` calls and builds the column
        // array, and was doing so again for every one of 500 rows.
        let spec = self.spec
        return VStack(spacing: 0) {
            TableHeader(spec, customKeys: ["kind", "changed", "size"]) { key in
                switch key {
                case "kind":
                    ColumnFilter(title: loc.s("large.col.kind"),
                                 // The kind filter carries "no filter" as nil, so
                                 // its value type is the optional kind itself.
                                 options: FileKind.allCases.map {
                                     SegmentOption<FileKind?>(value: $0, label: loc.s($0.titleKey))
                                 },
                                 selection: $kindFilter,
                                 allValue: nil,
                                 allTitle: loc.s("common.all"),
                                 columnKey: "kind",
                                 openKey: $openFilter)

                case "changed":
                    ColumnFilter(title: loc.s("large.col.changed"),
                                 options: AgeBand.allCases.dropFirst().map {
                                     SegmentOption(value: $0, label: loc.s($0.titleKey))
                                 },
                                 selection: $ageFilter,
                                 allValue: .all,
                                 allTitle: loc.s("common.all"),
                                 columnKey: "changed",
                                 openKey: $openFilter)
                        // The dates macOS reports are approximate; the tooltip
                        // carries that caveat.
                        .help(loc.s("large.ageNote"))

                default:
                    ColumnFilter(title: loc.s("large.col.size"),
                                 options: SizeBand.allCases.dropFirst().map {
                                     SegmentOption(value: $0, label: loc.s($0.titleKey))
                                 },
                                 selection: $sizeFilter,
                                 allValue: .all,
                                 allTitle: loc.s("common.all"),
                                 columnKey: "size",
                                 openKey: $openFilter)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            // The open menu is an overlay on the header; without this the rows
            // below it paint over the menu.
            .zIndex(1)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, file in
                        row(file, spec: spec).staggeredAppear(index: index)
                    }
                    footnotes
                }
            }
            .quickLookOnSpace(focusedFileURL)
            .background(revealShortcut)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }

    private func row(_ file: LargeFile, spec: TableSpec) -> some View {
        let kind = FileKind.of(file.name)
        let isOn = viewModel.selected.contains(file.id)
        // Whether this process could actually move the file to the Trash. `find`
        // over the whole disk returns root-owned files the user cannot delete;
        // without this they look identical to their own documents and simply fail
        // at deletion time. The scanner answers this once; asking `FileManager`
        // here would put a syscall on the main thread per visible row per re-render.
        let blocked = !file.isDeletable

        return TableRow(spec: spec,
                        height: Metric.rowDetailed,
                        isSelected: isOn,
                        // Describes what activating *this row* does: a blocked row
                        // cannot be collected for deletion.
                        accessibility: blocked
                            ? loc.f("large.a11y.reveal", file.name)
                            : loc.f("large.a11y.select", file.name),
                        action: {
                            if blocked {
                                reveal(file)
                            } else {
                                viewModel.toggle(file)
                            }
                        }) {
            RowCheckbox(isOn: isOn, blocked: blocked)
                .column(spec, "check")

            VStack(alignment: .leading, spacing: 2) {
                // 13pt regular. The name is data, not a heading.
                Text(file.name)
                    .font(Typo.body)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.path)
                    .font(Typo.numeric(11, weight: .regular))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .column(spec, "file")

            HStack(spacing: 7) {
                CategorySwatch(color: kind.color, size: 7)
                Text(loc.s(kind.titleKey))
                    .font(Typo.secondary)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            .column(spec, "kind")

            Text(RelativeDate.text(file.modified))
                .font(Typo.numeric(12, weight: .regular))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .column(spec, "changed")

            Text(Fmt.bytes(file.size))
                .font(Typo.numeric(13))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .column(spec, "size")
        }
        .contextMenu {
            Button(loc.s("common.quickLook")) { QuickLook.shared.toggle(url: file.url) }
            Button(loc.s("common.revealInFinder")) { reveal(file) }
            Button(loc.s("common.open")) { NSWorkspace.shared.open(file.url) }
        }
    }

    /// Every truncation is labelled, and the keyboard actions are written down
    /// where the table ends instead of living only in a right-click menu.
    @ViewBuilder
    private var footnotes: some View {
        if hiddenSelectedCount > 0 {
            // Selection survives filtering, so the bar could offer to trash files
            // that are not on screen. Name them and offer the way back.
            TableFootnoteRow(
                text: loc.f("large.hiddenSelectedFmt", Fmt.plural("plural.files", hiddenSelectedCount)),
                actionTitle: loc.s("common.resetFilters"),
                action: { resetFilters() }
            )
        }
        if viewModel.files.count >= resultCap, let smallest = viewModel.files.last {
            TableFootnoteRow(
                text: loc.f("large.cappedFmt", Fmt.count(resultCap), smallest.formattedSize)
            )
        }
        TableFootnoteRow(text: loc.s("large.keyHints"))
    }

    // MARK: Selection helpers

    /// Space-key Quick Look, and the ⌘↩ target, follow the largest selected file.
    private var focusedFileURL: URL? {
        visible.first(where: { viewModel.selected.contains($0.id) })?.url
    }

    /// ⌘↩ reveals that file in Finder. The footnote advertises the shortcut, so
    /// it has to exist; Space already had the same treatment via `quickLookOnSpace`.
    private var revealShortcut: some View {
        Button("") {
            if let url = focusedFileURL {
                NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
            }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .opacity(0)
        .allowsHitTesting(false)
        .disabled(focusedFileURL == nil)
    }

    private var hiddenSelectedCount: Int {
        let shown = Set(visible.map(\.id))
        return viewModel.selected.subtracting(shown).count
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        BottomActionBar(
            selectionLabel: loc.s("common.selected"),
            selectionValue: viewModel.formattedSelectedSize,
            selectionCount: Fmt.plural("plural.files", viewModel.selectedCount),
            // Reversible: `deleteSelected` goes through TrashService, and the
            // toast it raises offers an undo, so it keeps the accent fill;
            // `dangerFill` is reserved for deletion without a way back.
            consequence: loc.s("cleanup.consequence.trash"),
            consequenceIsDestructive: false
        ) {
            if viewModel.isDeleting {
                ProgressView().controlSize(.small)
            }
            Button(loc.s("large.toTrash")) {
                Task { await viewModel.deleteSelected() }
            }
            .buttonStyle(.primaryAction)
            .disabled(viewModel.isDeleting)
        }
    }

    // MARK: Scan lifecycle

    private func runScan() {
        scanCancelled = false
        viewModel.startScan()
    }

    private func cancelScan() {
        scanCancelled = true
        viewModel.cancelScan()
    }

    private func finishScan() {
        guard !scanCancelled else { return }
        lastScanDate = Date()
        emptyReason = viewModel.files.isEmpty ? diagnoseEmptyResult() : .clean
    }

    /// Names the two ways the view model's `catch { return [] }` is reached, so a
    /// broken scan reads as a failure instead of as an empty disk.
    private func diagnoseEmptyResult() -> EmptyReason {
        let fm = FileManager.default
        if !fm.isExecutableFile(atPath: "/usr/bin/find") {
            return .failure(path: "/usr/bin/find", code: "ENOENT")
        }
        if !fm.isReadableFile(atPath: scanRoot) {
            return .failure(path: scanRoot, code: "EACCES")
        }
        // Probed once per scan, never per render: it opens the TCC database.
        if viewModel.customSearchFolder == nil && !FullDiskAccess.isGranted() {
            return .noAccess
        }
        return .clean
    }

    private var scanRoot: String { viewModel.searchRoot.path }

    private func reveal(_ file: LargeFile) {
        NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
    }
}
