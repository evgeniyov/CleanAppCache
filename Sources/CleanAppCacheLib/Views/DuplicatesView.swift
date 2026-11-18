import SwiftUI

// MARK: - Duplicates
//
// One of the eight sections that share `ScanResultView`; everything below is the
// adapter that states this section's data and its captions.
//
// The row is a **group**, not a copy: the title is the file, the context
// column (copies) says how many there are and how big one is, the path line lists
// the folders holding them, and the measured value is the waste — what deleting
// the extras gives back. There is no per-copy table with keep / move-to-Trash
// verdicts; the promise such verdicts would carry — one copy always
// survives — is the bottom bar's consequence line and the dialog's message.
//
// What the shared row template has no column for is the pair of values that decide what
// the scan even looks at: **where** it searches and **how small** a file it is
// willing to hash. Without them the view model's defaults are the only
// possible scan — `~/Downloads` at 5 MB — so the section would answer one question
// and call it "duplicates on your Mac". They are inputs, not filters over
// results, so they are not column filters: they sit in the screen header's
// trailing slot, the place other screens use for a chip and a search field.

public struct DuplicatesView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var viewModel: DuplicatesViewModel

    @State private var selection: Set<UUID> = []
    /// The size filter belongs to the section, never shared.
    @State private var sizeFilter: ScanSizeFilter = .all
    @State private var showConfirm = false
    @State private var scopeAccess: ScopeAccess = .ok

    public init() {}

    public var body: some View {
        content
            .disabled(viewModel.isDeleting)
            .background(Palette.background)
            .onAppear { scopeAccess = Self.probe(viewModel.searchRoot) }
            .onDisappear { viewModel.cancelScan() }
            .confirmationDialog(
                loc.f("dup.confirmTitleFmt", Fmt.plural("plural.files", extraCopies)),
                isPresented: $showConfirm, titleVisibility: .visible
            ) {
                // The rule decides which copy survives, so the user picks it
                // here, where the choice is read, rather than in a setting.
                Button(loc.s("dup.keepNewest"), role: .destructive) {
                    Task { await apply(keep: .newest) }
                }
                Button(loc.s("dup.keepOldest"), role: .destructive) {
                    Task { await apply(keep: .oldest) }
                }
                Button(loc.s("common.cancel"), role: .cancel) {}
            } message: {
                Text(loc.s("dup.confirmMsg") + "\n\n"
                     + loc.f("dup.confirmBytesFmt", Fmt.bytes(selectedBytes)))
            }
    }

    @ViewBuilder
    private var content: some View {
        // A scope that is missing or unreadable would otherwise look exactly like
        // a folder with no duplicates in it. `ScanResultView` has no vocabulary for
        // either, so the two permission states stay here.
        if scopeAccess != .ok, viewModel.result == nil, !viewModel.isScanning {
            blocked
        } else {
            ScanResultView(
                config: config,
                items: items,
                hasScanned: viewModel.result != nil,
                isScanning: viewModel.isScanning,
                // `DuplicateFinder` reports a running file count, never a
                // fraction of the work, so the bar has nothing to advance on.
                scanProgress: 0,
                scanDetail: viewModel.currentPath,
                selection: $selection,
                sizeFilter: $sizeFilter,
                onScan: { viewModel.startScan() },
                onApply: { showConfirm = true },
                onCancel: { viewModel.cancelScan() },
                parameters: AnyView(scanParameters),
                skipped: viewModel.result?.skipped ?? ScanSkipSummary()
            )
        }
    }

    // MARK: Scan parameters

    /// Scope and threshold, as two `SegmentedControl`s — the app's component for a
    /// closed set of mutually exclusive values. `.fixedSize()` keeps them hugging
    /// their labels; without it a segmented control is greedy and would swallow
    /// the header.
    private var scanParameters: some View {
        HStack(spacing: 8) {
            if let folder = viewModel.customSearchFolder {
                Button { change(scope: .downloads) } label: {
                    Label(folder.lastPathComponent, systemImage: "xmark.circle")
                        .lineLimit(1)
                }
                .help(folder.path)
            } else {
                SegmentedControl(selection: scopeBinding,
                                 options: DuplicatesViewModel.Scope.allCases.map {
                                     SegmentOption(value: $0, label: loc.s($0.titleKey))
                                 })
                    .fixedSize()
                    .help(loc.s("dup.scopeLabel"))
            }

            SegmentedControl(selection: minSizeBinding,
                             options: DuplicatesViewModel.MinSize.allCases.map {
                                 SegmentOption(value: $0, label: loc.s($0.titleKey))
                             })
                .fixedSize()
                // The segments read as a size ladder but not as *which* size, and
                // the table has a size filter of its own — the tooltip is what
                // separates the scan threshold from the filter over results.
                .help(loc.s("scan.minSize"))
            profiles
        }
    }

    private struct SearchConfiguration: Codable {
        let scope: DuplicatesViewModel.Scope
        let folder: URL?
        let minimum: DuplicatesViewModel.MinSize
        let resultSize: ScanSizeFilter
    }

    private var profiles: some View {
        SearchProfilesMenu(key: "searchProfiles.duplicates",
                           configuration: SearchConfiguration(
                            scope: viewModel.scope, folder: viewModel.customSearchFolder,
                            minimum: viewModel.minSize, resultSize: sizeFilter),
                           chooseFolder: selectFolder, run: runProfile)
    }

    private func selectFolder(_ url: URL) {
        viewModel.setCustomSearchFolder(url)
        selection = []
        scopeAccess = Self.probe(viewModel.searchRoot)
    }

    private func runProfile(_ profile: SearchConfiguration) {
        viewModel.setScope(profile.scope)
        if let folder = profile.folder { viewModel.setCustomSearchFolder(folder) }
        viewModel.setMinSize(profile.minimum)
        selection = []
        sizeFilter = profile.resultSize
        scopeAccess = Self.probe(viewModel.searchRoot)
        if scopeAccess == .ok { viewModel.startScan() }
    }

    private var scopeBinding: Binding<DuplicatesViewModel.Scope> {
        Binding(get: { viewModel.scope }, set: { change(scope: $0) })
    }

    private var minSizeBinding: Binding<DuplicatesViewModel.MinSize> {
        Binding(get: { viewModel.minSize }, set: { change(minSize: $0) })
    }

    /// A new scope is a new question: the groups on screen came from a folder the
    /// user has moved away from, and the row selection points at group ids
    /// that will not exist after the next scan. The view model drops the result;
    /// this drops the selection and asks the new folder whether it is readable,
    /// which is the one thing the probe cannot answer from the scope it last checked.
    private func change(scope new: DuplicatesViewModel.Scope) {
        guard new != viewModel.scope || viewModel.customSearchFolder != nil else { return }
        viewModel.setScope(new)
        selection = []
        scopeAccess = Self.probe(viewModel.searchRoot)
    }

    private func change(minSize new: DuplicatesViewModel.MinSize) {
        guard new != viewModel.minSize else { return }
        viewModel.setMinSize(new)
        selection = []
    }

    private var config: ScanResultConfig {
        ScanResultConfig(title: loc.s("nav.duplicates"),
                         describes: loc.s("dup.describes"),
                         contextColumn: loc.s("dup.col.copies"),
                         actionTitle: loc.s("dup.action"),
                         warning: loc.s("dup.note"),
                         willFind: loc.s("dup.willFind"))
    }

    // MARK: Rows

    private var items: [ScanResultItem] {
        viewModel.groups.map { group in
            // `DuplicateGroup.id` is minted once per scan, so the selection
            // survives every redraw.
            ScanResultItem(id: group.id,
                           title: group.files.first?.name ?? Fmt.none,
                           path: locations(group),
                           context: loc.f("dup.contextFmt",
                                          Fmt.plural("plural.copies", group.count),
                                          Fmt.bytes(group.size)),
                           bytes: group.wastedBytes,
                           // Which copy stays, named before anything is moved.
                           detail: DuplicatesViewModel.survivor(of: group, keep: .newest).map {
                               loc.f("dup.keepsFmt", ($0.url.path as NSString).abbreviatingWithTildeInPath)
                           } ?? "")
        }
    }

    /// «~/Pictures, ~/Desktop, ~/Downloads» — the copies share a name and differ
    /// only in where they live, so the row's path line is that set of folders.
    private func locations(_ group: DuplicateGroup) -> String {
        var seen: Set<String> = []
        var dirs: [String] = []
        for file in group.files {
            let dir = (file.url.deletingLastPathComponent().path as NSString)
                .abbreviatingWithTildeInPath
            if seen.insert(dir).inserted { dirs.append(dir) }
        }
        return dirs.joined(separator: ", ")
    }

    // MARK: Selection
    //
    // The size filter is applied here as well as inside `ScanResultView`: the
    // bottom bar counts what the filter leaves visible, and the dialog must
    // promise exactly what the deletion will touch.

    private var chosen: [DuplicateGroup] {
        viewModel.groups.filter {
            selection.contains($0.id) && $0.wastedBytes >= sizeFilter.minimumBytes
        }
    }

    private var extraCopies: Int {
        chosen.reduce(0) { $0 + max(0, $1.count - 1) }
    }

    private var selectedBytes: UInt64 {
        chosen.reduce(UInt64(0)) { $0 &+ $1.wastedBytes }
    }

    /// Marks the extra copies of the chosen groups and hands them to the view
    /// model. `autoSelect` owns the ordering for which copy survives — with a
    /// deterministic tiebreak for the `cp -p` case — so it is taken there
    /// rather than repeated here; this only narrows it to the ticked groups.
    private func apply(keep rule: DuplicatesViewModel.KeepRule) async {
        let targets = Set(chosen.map(\.id))
        viewModel.autoSelect(keep: rule)
        var marked = viewModel.selectedForDeletion
        for group in viewModel.groups where !targets.contains(group.id) {
            for file in group.files { marked.remove(file.id) }
        }
        viewModel.selectedForDeletion = marked
        await viewModel.deleteSelected()
        selection = []
    }

    // MARK: Scope reachability
    //
    // Probe the scope before a scan so TCC failures have an immediate action.
    // The scan's own coverage report handles failures after this snapshot.
    // The probe runs on appear, never from a body.

    private enum ScopeAccess: Equatable { case ok, missing, denied }

    private var blocked: some View {
        ScreenBody {
            // The parameters belong here too: an unreadable scope is precisely
            // the moment the user needs to pick a different one, and this branch
            // renders instead of `ScanResultView`, not inside it.
            ScreenHeader(title: loc.s("nav.duplicates")) { scanParameters }
            Group {
                if scopeAccess == .missing {
                    StateView(.failure(path: viewModel.searchRoot.path,
                                       code: "ENOENT",
                                       retry: { retryScope() }))
                } else {
                    StateView(.noAccess(missing: loc.f("dup.noAccessFmt", scopeLabel),
                                        openSettings: { FullDiskAccess.openSettings() },
                                        scanAnyway: { viewModel.startScan() }))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .card()
        }
    }

    private func retryScope() {
        scopeAccess = Self.probe(viewModel.searchRoot)
        if scopeAccess == .ok { viewModel.startScan() }
    }

    private static func probe(_ url: URL) -> ScopeAccess {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return .missing }
        return (try? fm.contentsOfDirectory(atPath: url.path)) == nil ? .denied : .ok
    }

    private var scopeLabel: String {
        if let folder = viewModel.customSearchFolder { return folder.path }
        switch viewModel.scope {
        case .home:      return loc.s("dscope.home")
        case .downloads: return loc.s("dscope.downloads")
        case .documents: return loc.s("dscope.documents")
        case .desktop:   return loc.s("dscope.desktop")
        }
    }
}
