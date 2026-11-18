import SwiftUI

// MARK: - System Junk
//
// One of the eight sections that share `ScanResultView`, so this file is an
// adapter and not a screen: it turns `SystemJunkViewModel` into the rows and
// captions that view takes, and owns the two pieces of state that belong to the
// section rather than to the app — the selection and its **own** size filter.
//
// Two things the shared screen has no room for, kept around it:
//
//   • Full Disk Access. Mail's container and the MobileSync backup folder are
//     unreadable without it, and the scanner reports an unreadable directory
//     exactly like an empty one — "clean" there would be a false negative,
//     so that case never reaches `ScanResultView`.
//   • The confirmation. Seven categories at once is not a single click.

public struct SystemJunkView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var viewModel: SystemJunkViewModel

    @State private var selection: Set<UUID> = []
    /// Each section has its own size filter; it is never shared between sections.
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
                               hasScanned: viewModel.hasScanned,
                               isScanning: viewModel.isScanning,
                               scanDetail: viewModel.currentScan,
                               selection: $selection,
                               sizeFilter: $sizeFilter,
                               onScan: { viewModel.scan() },
                               onApply: { showCleanConfirm = true },
                               skipped: viewModel.skipped)
            }
        }
        .background(Palette.background)
        .onAppear { hasFullDiskAccess = FullDiskAccess.isGranted() }
        .onChange(of: viewModel.isScanning) { scanning in
            guard !scanning else { return }
            hasFullDiskAccess = FullDiskAccess.isGranted()
            // The view model pre-selects the safe categories at the end of every
            // scan; without this the work it did would be invisible, because the
            // selection the screen renders is the one owned here.
            selection = viewModel.selected
        }
        .confirmationDialog(
            loc.f("cleanup.confirmTitleFmt", Fmt.plural("plural.items", chosen.count)),
            isPresented: $showCleanConfirm, titleVisibility: .visible
        ) {
            // The label names the Trash, which is where `SystemJunkManager`
            // actually routes everything, and carries the volume.
            Button(loc.f("common.moveToTrashFmt", Fmt.bytes(chosenBytes)),
                   role: .destructive) { clean() }
            Button(loc.s("common.cancel"), role: .cancel) {}
        } message: {
            Text(loc.s("systemJunk.confirmMsg"))
        }
    }

    // MARK: Section description

    private var config: ScanResultConfig {
        ScanResultConfig(title: loc.s("systemJunk.title"),
                         describes: loc.s("systemJunk.subtitle"),
                         contextColumn: loc.s("scan.col.source"),
                         actionTitle: loc.s("scan.action.clean"),
                         warning: loc.s("scan.note.reversible"),
                         willFind: loc.s("systemJunk.checked"))
    }

    private var items: [ScanResultItem] {
        viewModel.entries.map { entry in
            ScanResultItem(id: entry.id,
                           title: loc.s(entry.category.titleKey),
                           path: sharedFolder(of: entry.urls),
                           context: loc.s("systemJunk.\(entry.category.rawValue).source"),
                           bytes: entry.totalSize)
        }
    }

    /// The shared screen puts one path under each row title, but a category here is a bundle
    /// of paths — up to a few hundred project folders under DerivedData. The row
    /// shows the deepest folder they all share instead of the first of them.
    private func sharedFolder(of urls: [URL]) -> String {
        guard let first = urls.first else { return "" }
        if urls.count == 1 {
            return (first.path as NSString).abbreviatingWithTildeInPath
        }
        var common = first.deletingLastPathComponent().pathComponents
        for url in urls.dropFirst() {
            let parts = url.deletingLastPathComponent().pathComponents
            var shared = 0
            while shared < min(common.count, parts.count), common[shared] == parts[shared] {
                shared += 1
            }
            common = Array(common.prefix(shared))
        }
        return (NSString.path(withComponents: common) as NSString).abbreviatingWithTildeInPath
    }

    // MARK: Access

    private var blockedByAccess: Bool {
        viewModel.hasScanned && !viewModel.isScanning
            && viewModel.entries.isEmpty && !hasFullDiskAccess
    }

    private var accessScreen: some View {
        ScreenBody {
            ScreenHeader(title: loc.s("systemJunk.title"))
            StateView(.noAccess(missing: loc.s("systemJunk.noAccess"),
                                openSettings: { FullDiskAccess.openSettings() },
                                scanAnyway: { viewModel.scan() }))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
        }
    }

    // MARK: Cleaning

    /// The screen recalculates the totals under the filter, so the action has to obey
    /// it too: the bottom bar counts only the rows the filter left on screen,
    /// and cleaning one it hid would delete something the user cannot see.
    private var chosen: [SystemJunkEntry] {
        viewModel.entries.filter {
            selection.contains($0.id) && $0.totalSize >= sizeFilter.minimumBytes
        }
    }

    private var chosenBytes: UInt64 {
        chosen.reduce(UInt64(0)) { $0 &+ $1.totalSize }
    }

    private func clean() {
        viewModel.selected = Set(chosen.map(\.id))
        Task {
            await viewModel.clean()
            // What survives the clean is what failed; it stays selected so the
            // retry is one click away.
            selection = viewModel.selected
        }
    }
}
