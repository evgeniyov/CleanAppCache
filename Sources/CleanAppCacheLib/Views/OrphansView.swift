import SwiftUI

// MARK: - Orphaned background items
//
// The adapter that states this section's data and captions for `ScanResultView`.
//
// Launch agents, daemons and privileged helpers whose owning app is gone. The
// section uses the shared row — label, plist path, and the context column
// (`orphan.col.type`) carrying the scope — plus one batch action instead of per-row Trash
// and "Rights…" buttons. The scope name is what tells the two apart: everything
// but a user agent (`orphan.scope.userAgent`) lives under /Library and needs an administrator, and
// those are the rows this screen cannot delete on its own.

public struct OrphansView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var viewModel: OrphansViewModel

    @State private var selection: Set<UUID> = []
    /// The size filter belongs to the section, never shared.
    @State private var sizeFilter: ScanSizeFilter = .all
    @State private var showConfirm = false

    public init() {}

    public var body: some View {
        ScanResultView(
            config: config,
            items: items,
            hasScanned: viewModel.hasScanned,
            isScanning: viewModel.isScanning,
            // `OrphanScanner.scan()` publishes no fraction and no current path,
            // and holds no cancellation point, so the bar sits at zero until the
            // result lands and the state offers no Cancel.
            scanProgress: 0,
            scanDetail: Self.scannedLocations,
            selection: $selection,
            sizeFilter: $sizeFilter,
            onScan: { viewModel.scan() },
            onApply: { showConfirm = true }
        )
        .background(Palette.background)
        .confirmationDialog(
            loc.f("orphan.confirmBatchFmt", chosen.count),
            isPresented: $showConfirm, titleVisibility: .visible
        ) {
            Button(loc.s("orphan.remove"), role: .destructive) { apply() }
            Button(loc.s("common.cancel"), role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var config: ScanResultConfig {
        ScanResultConfig(title: loc.s("nav.orphans"),
                         describes: loc.s("orphan.describes"),
                         contextColumn: loc.s("orphan.col.type"),
                         actionTitle: loc.s("scan.action.removeSelected"),
                         warning: loc.s("scan.note.reversible"),
                         willFind: loc.s("orphan.willFind"))
    }

    /// What the scan actually reads — real content for the scanning state's path
    /// line, since there is no per-file progress to show.
    private static let scannedLocations =
        "~/Library/LaunchAgents · /Library/LaunchAgents · /Library/LaunchDaemons"

    // MARK: Rows

    private var items: [ScanResultItem] {
        viewModel.items.map { item in
            ScanResultItem(id: ScanAdapterID.uuid(item.id),
                           title: item.label,
                           path: (item.url.path as NSString).abbreviatingWithTildeInPath,
                           context: item.uncertain ? loc.s("leftovers.vendorInstalled") : loc.s(item.scopeKey),
                           bytes: item.size,
                           // A system job or a helper stops software working
                           // when removed by mistake; each is ticked by hand.
                           excludedFromSelectAll: item.needsAdmin || item.uncertain)
        }
    }

    // MARK: Selection

    private var chosen: [OrphanItem] {
        viewModel.items.filter {
            selection.contains(ScanAdapterID.uuid($0.id))
                && $0.size >= sizeFilter.minimumBytes
        }
    }

    /// The dialog says beforehand how much of the selection needs a password:
    /// items under `/Library` go to the Trash through Finder, which asks.
    private var confirmMessage: String {
        let admin = chosen.filter(\.needsAdmin).count
        guard admin > 0 else { return loc.s("orphan.confirmMsg") }
        return loc.s("orphan.confirmMsg") + "\n\n"
            + loc.f("orphan.confirmAdminFmt", Fmt.plural("plural.objects", admin))
    }

    private func apply() {
        viewModel.remove(chosen)
        selection = []
    }
}
