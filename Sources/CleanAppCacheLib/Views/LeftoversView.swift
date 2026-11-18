import SwiftUI
import CryptoKit

// MARK: - Leftovers
//
// The adapter that states this section's data and captions for `ScanResultView`.
//
// The section draws one row per abandoned bundle id: the id is the title, the
// folders it left behind are the path line, and the context column
// (`leftovers.col.removed`, "app removed") names the app the id belonged to.
// The shared shape has no expandable per-file list, search field or per-group
// trash button; the batch action and its confirmation are the only actions.

public struct LeftoversView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var viewModel: LeftoversViewModel

    @State private var selection: Set<UUID> = []
    /// The size filter belongs to the section, never shared.
    @State private var sizeFilter: ScanSizeFilter = .all
    @State private var showConfirm = false
    /// `FullDiskAccess.isGranted()` opens a file to probe TCC, so it is sampled
    /// on appear and after each scan rather than read during layout.
    @State private var hasFullDiskAccess = true

    public init() {}

    public var body: some View {
        content
            .background(Palette.background)
            .onAppear { hasFullDiskAccess = FullDiskAccess.isGranted() }
            .onChange(of: viewModel.isScanning) { scanning in
                // Re-probed after the scan: the user may have granted access in
                // System Settings while it was running.
                if !scanning { hasFullDiskAccess = FullDiskAccess.isGranted() }
            }
            .confirmationDialog(
                loc.f("leftovers.confirmBatchFmt", Fmt.plural("plural.appsGen", chosen.count)),
                isPresented: $showConfirm, titleVisibility: .visible
            ) {
                Button(loc.f("common.moveToTrashFmt", Fmt.bytes(selectedBytes)),
                       role: .destructive) {
                    viewModel.delete(chosen)
                    selection = []
                }
                Button(loc.s("common.cancel"), role: .cancel) {}
            } message: {
                Text(loc.s("trash.confirmMsg"))
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.hasScanned, !viewModel.isScanning,
           viewModel.groups.isEmpty, !hasFullDiskAccess {
            // "Nothing found" without Full Disk Access is not the same claim as
            // "nothing is there": Containers and the protected caches were never
            // readable. `ScanResultView` would call this clean.
            noAccess
        } else {
            ScanResultView(
                config: config,
                items: items,
                hasScanned: viewModel.hasScanned,
                isScanning: viewModel.isScanning,
                // `LeftoversManager.scan()` is one actor call: no fraction to
                // report and no cancellation point, so the bar sits at zero and
                // the scanning state offers no Cancel.
                scanProgress: 0,
                scanDetail: "~/Library",
                selection: $selection,
                sizeFilter: $sizeFilter,
                onScan: { viewModel.scan() },
                onApply: { showConfirm = true }
            )
        }
    }

    private var config: ScanResultConfig {
        ScanResultConfig(title: loc.s("nav.leftovers"),
                         describes: loc.s("leftovers.describes"),
                         contextColumn: loc.s("leftovers.col.removed"),
                         actionTitle: loc.s("scan.action.removeSelected"),
                         warning: loc.s("scan.note.reversible"),
                         willFind: loc.s("leftovers.willFind"))
    }

    private var noAccess: some View {
        ScreenBody {
            ScreenHeader(title: loc.s("nav.leftovers"))
            StateView(.noAccess(missing: loc.s("leftovers.noAccess"),
                                openSettings: { FullDiskAccess.openSettings() },
                                scanAnyway: { viewModel.scan() }))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
        }
    }

    // MARK: Rows

    private var items: [ScanResultItem] {
        viewModel.groups.map { group in
            ScanResultItem(id: ScanAdapterID.uuid(group.id),
                           title: group.id,
                           path: locations(group),
                           // An uncertain group says why instead of naming an
                           // app it may not belong to.
                           context: group.uncertain ? loc.s("leftovers.vendorInstalled") : group.displayName,
                           bytes: group.totalBytes,
                           // Ticked one by one, after a look, or not at all.
                           excludedFromSelectAll: group.uncertain)
        }
    }

    /// The ~/Library folders the id was found in, biggest first — `LeftoversManager`
    /// already sorts a group's files by size, so the folder holding the bulk of
    /// the leftovers leads the line.
    private func locations(_ group: LeftoverGroup) -> String {
        var seen: Set<String> = []
        var dirs: [String] = []
        for file in group.files {
            let dir = (file.url.deletingLastPathComponent().path as NSString)
                .abbreviatingWithTildeInPath
            if seen.insert(dir).inserted { dirs.append(dir) }
        }
        return dirs.joined(separator: " · ")
    }

    // MARK: Selection
    //
    // Resolved against the live list and through the same size filter the table
    // applies, so the dialog promises exactly what the bottom bar counted.

    private var chosen: [LeftoverGroup] {
        viewModel.groups.filter {
            selection.contains(ScanAdapterID.uuid($0.id))
                && $0.totalBytes >= sizeFilter.minimumBytes
        }
    }

    private var selectedBytes: UInt64 {
        chosen.reduce(UInt64(0)) { $0 &+ $1.totalBytes }
    }
}

// MARK: - Row identity for the scan-result adapters
//
// `ScanResultItem` is keyed by `UUID` and the selection is a set of those keys,
// so an item rebuilt with a fresh `UUID()` on every redraw would drop the user's
// selection mid-scroll. Models identified by a path or a bundle id get a
// deterministic key instead: the same string always yields the same UUID.
enum ScanAdapterID {
    static func uuid(_ key: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return digest.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }
}
