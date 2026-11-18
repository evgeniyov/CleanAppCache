import SwiftUI

// MARK: - Developer
//
// An adapter onto `ScanResultView`, like the other seven sections. Curated tool
// caches and per-project build artifacts are one list here: `node_modules` of a
// dead project sits next to the npm cache, sorted by what it costs. Splitting
// them across two tabs would hide half the volume behind the second one.
//
// The consequence line says the deletion is permanent, not "move to Trash".
// `DevCleanManager` cleans through `DeletionService`, which unlinks — nothing
// here can be fished back out of the Trash. The bottom bar must state whether
// the action is reversible, and it must state the truth, so this section
// carries the irreversible sentence and the danger tint.

public struct DeveloperView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var viewModel: DeveloperViewModel

    @State private var selection: Set<UUID> = []
    /// Each section keeps its own size filter; it is not shared between sections.
    @State private var sizeFilter: ScanSizeFilter = .all
    @State private var showCleanConfirm = false

    /// Probed on appear and after each scan rather than from `body`:
    /// `isGranted()` opens a file, and `body` runs on every selection change.
    @State private var hasFullDiskAccess = true

    public init() {}

    public var body: some View {
        Group {
            if blockedByAccess {
                accessScreen
            } else {
                ScanResultView(config: config,
                               items: items,
                               hasScanned: hasScanned,
                               isScanning: isScanning,
                               scanDetail: viewModel.currentScan,
                               selection: $selection,
                               sizeFilter: $sizeFilter,
                               onScan: { scan() },
                               onApply: { showCleanConfirm = true },
                               selectedBytes: chosenBytes)
            }
        }
        .background(Palette.background)
        .onAppear { hasFullDiskAccess = FullDiskAccess.isGranted() }
        .onChange(of: viewModel.isLoading) { loading in
            guard !loading else { return }
            hasFullDiskAccess = FullDiskAccess.isGranted()
            // The view model pre-selects the safe caches at the end of every
            // cache scan. Project artifacts are never auto-selected — deleting
            // one costs a rebuild — so the merged selection starts there.
            selection = viewModel.selected
        }
        .confirmationDialog(
            loc.f("cleanup.confirmTitleFmt", Fmt.plural("plural.items", chosenCaches.count + chosenProjects.count)),
            isPresented: $showCleanConfirm, titleVisibility: .visible
        ) {
            Button(loc.f("common.deleteFmt", Fmt.bytes(chosenBytes)),
                   role: .destructive) { clean() }
            Button(loc.s("common.cancel"), role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: Section description

    private var config: ScanResultConfig {
        ScanResultConfig(title: loc.s("dev.title"),
                         describes: loc.s("dev.describes"),
                         contextColumn: loc.s("scan.col.tool"),
                         actionTitle: loc.s("scan.action.clean"),
                         // Not "move to Trash": see the note at the top of the file.
                         warning: loc.s("consequence.permanent"),
                         warningIsDestructive: true,
                         willFind: loc.s("dev.willFind"))
    }

    /// Both lists in one, largest first. The ids are the view model's own, so a
    /// row's selection survives a re-render and maps straight back onto the
    /// two `Set<UUID>` the view model cleans from.
    private var items: [ScanResultItem] {
        // An unsafe cache is flagged on its row and left out of "Select all":
        // its delete loses data, and a bulk tick would carry it into the
        // dialog unread.
        let caches = viewModel.items.map { item in
            ScanResultItem(id: item.id,
                           title: loc.s(item.titleKey),
                           path: (item.url.path as NSString).abbreviatingWithTildeInPath,
                           context: loc.s("dev.mode.caches"),
                           bytes: item.size,
                           detail: loc.s(item.detailKey),
                           caution: item.cleanupUnavailableReasonKey.map { loc.s($0) }
                               ?? (item.safe ? nil : loc.s("dev.caution")),
                           excludedFromSelectAll: !item.safe)
        }
        let projects = viewModel.projects.map { item in
            ScanResultItem(id: item.id,
                           title: item.projectName,
                           // The artifact directory, not the project folder —
                           // this is the path the delete actually removes.
                           path: (item.url.path as NSString).abbreviatingWithTildeInPath,
                           context: loc.s(item.kindKey),
                           bytes: item.size,
                           detail: loc.f("dev.projectChangedFmt", loc.date(item.projectModified)))
        }
        return (caches + projects).sorted { $0.bytes > $1.bytes }
    }

    private var isScanning: Bool { viewModel.isLoading || viewModel.isScanningProjects }

    /// One list means one scan: the section has results only once both halves
    /// have run, or the table would claim a total that is missing the other half.
    private var hasScanned: Bool { viewModel.hasScanned && viewModel.hasScannedProjects }

    private func scan() {
        viewModel.scan()
        viewModel.scanProjects()
    }

    // MARK: Access
    //
    // Only the caches half needs Full Disk Access: a few curated locations
    // (Docker.raw, OrbStack's data.img) live inside other apps' containers,
    // which TCC hides. The projects scan walks the home folder and skips
    // ~/Library entirely, so it is unaffected — which is why "scan anyway" is
    // mandatory here, not optional.

    private var blockedByAccess: Bool { !hasScanned && !isScanning && !hasFullDiskAccess }

    private var accessScreen: some View {
        ScreenBody {
            ScreenHeader(title: loc.s("dev.title"))
            StateView(.noAccess(missing: loc.s("dev.noAccess.missing"),
                                openSettings: { FullDiskAccess.openSettings() },
                                scanAnyway: { scan() }))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
        }
    }

    // MARK: Cleaning

    /// The totals are recalculated under the size filter, so the action has to obey
    /// it too: the bottom bar counts only the rows the filter left on screen,
    /// and deleting one it hid would remove something the user cannot see.
    private var chosenCaches: [DevJunkItem] {
        viewModel.items.filter {
            selection.contains($0.id) && $0.size >= sizeFilter.minimumBytes
        }
    }

    private var chosenProjects: [ProjectArtifact] {
        viewModel.projects.filter {
            selection.contains($0.id) && $0.size >= sizeFilter.minimumBytes
        }
    }

    /// What the delete frees. A selected row inside another selected row is
    /// not counted again: deleting the outer one takes it along.
    private var chosenBytes: UInt64 {
        let sized = chosenCaches.map { ($0.url, $0.size) } + chosenProjects.map { ($0.url, $0.size) }
        return DevCleanManager.outermost(sized) { $0.0 }.reduce(UInt64(0)) { $0 &+ $1.1 }
    }

    /// Each kind explains itself: an unsafe cache by name, with what is lost
    /// for good; a safe cache comes back with the tool, an artifact with the
    /// next build. The loss comes first and stays apart from the sentence
    /// that promises regeneration, which does not cover it.
    private var confirmMessage: String {
        var parts: [String] = []
        let unsafe = chosenCaches.filter { !$0.safe }
        if !unsafe.isEmpty {
            let lines = unsafe.map {
                loc.f("dev.confirmLossLineFmt", loc.s($0.titleKey), loc.s($0.lossKey))
            }
            parts.append(([loc.s("dev.confirmLossMsg")] + lines).joined(separator: "\n"))
        }
        if chosenCaches.contains(where: \.safe) {
            parts.append(loc.s(unsafe.isEmpty ? "dev.confirmMsg" : "dev.confirmOthersMsg"))
        }
        if !chosenProjects.isEmpty { parts.append(loc.s("dev.projects.confirmMsg")) }
        return parts.joined(separator: "\n\n")
    }

    private func clean() {
        viewModel.selected = Set(chosenCaches.map(\.id))
        viewModel.selectedProjects = Set(chosenProjects.map(\.id))
        Task {
            await viewModel.clean()
            await viewModel.cleanProjects()
            // What survives is what failed; it stays selected so the retry is
            // one click away.
            selection = viewModel.selected.union(viewModel.selectedProjects)
        }
    }
}
