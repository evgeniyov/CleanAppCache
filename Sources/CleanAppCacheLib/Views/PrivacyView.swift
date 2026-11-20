import SwiftUI
import CryptoKit

// MARK: - Privacy
//
// An adapter onto `ScanResultView`. One row per browser: the item is the data
// that goes, the context column is the browser it belongs to — the column is
// titled "Browser", so the browser cannot also be the title.
//
// This is the one destructive section of the eight, and the bottom bar says so
// (`scan.note.privacy`: deleted with no way back, signed out of some sites). The
// manager keeps both halves of that promise — it collects cookies and site
// storage as well as history, and deletes permanently rather than into the
// Trash — so the dialog underneath agrees with the banner above it. It states
// the two consequences that cannot be undone (signed out, no way back) and does
// not mention the Trash, because nothing goes there.
//
// Two further safeguards:
//
//   • No dead end. A bare "Quit to clear" names no process and offers no way
//     out; a running browser is cleared by asking it to quit, waiting for it
//     to actually exit, and only then clearing.
//   • The confirmation, with the volume in the button.

public struct PrivacyView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var viewModel: PrivacyViewModel

    @State private var selection: Set<UUID> = []
    /// The size filter belongs to this section; it is not shared with the others.
    @State private var sizeFilter: ScanSizeFilter = .all
    @State private var showClearConfirm = false
    @State private var confirmation: ClearConfirmation?

    private struct ClearConfirmation {
        let entries: [BrowserEntry]
        let authorizedToQuit: Set<String>

        var names: String { entries.map(\.name).joined(separator: ", ") }
        var bytes: UInt64 { entries.reduce(0) { $0 &+ $1.totalSize } }
        var needsQuit: Bool { !authorizedToQuit.isEmpty }
    }

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
                               selection: $selection,
                               sizeFilter: $sizeFilter,
                               onScan: { viewModel.scan() },
                               onApply: prepareConfirmation,
                               skipped: viewModel.skipped)
                    .disabled(viewModel.isClearing)
            }
        }
        .background(Palette.background)
        .onAppear { hasFullDiskAccess = FullDiskAccess.isGranted() }
        .onChange(of: viewModel.isScanning) { scanning in
            guard !scanning, viewModel.hasScanned else { return }
            // Re-probed after every scan: granting access mid-session is the
            // whole point of the `noAccess` state's "Open Settings".
            hasFullDiskAccess = FullDiskAccess.isGranted()
        }
        .confirmationDialog(
            confirmation.map {
                loc.f($0.needsQuit ? "privacy.confirmQuitFmt" : "privacy.confirmClearFmt", $0.names)
            } ?? "",
            isPresented: $showClearConfirm, titleVisibility: .visible, presenting: confirmation
        ) { request in
            Button(request.needsQuit
                   ? loc.f("privacy.quitAndClearFmt", Fmt.bytes(request.bytes))
                   : loc.f("privacy.deleteForGoodFmt", Fmt.bytes(request.bytes)),
                   role: .destructive) {
                Task {
                    if await viewModel.clearHistory(for: request.entries, authorizedToQuit: request.authorizedToQuit) {
                        selection = []
                    }
                }
            }
            Button(loc.s("common.cancel"), role: .cancel) {}
        } message: { request in
            Text(loc.s(request.needsQuit ? "privacy.confirmQuitMsg" : "privacy.confirmClearMsg"))
        }
    }

    // MARK: Section description

    private var config: ScanResultConfig {
        ScanResultConfig(title: loc.s("nav.privacy"),
                         describes: loc.s("privacy.checked"),
                         contextColumn: loc.s("privacy.col.browser"),
                         actionTitle: loc.s("scan.action.clean"),
                         warning: loc.s("scan.note.privacy"),
                         warningIsDestructive: true,
                         willFind: loc.s("privacy.idleMessage"))
    }

    /// Browsers with nothing to clear are left out: they would count towards
    /// the "N items found" count and add a row measured "—". When every browser is
    /// empty the section is clean, which is the state that says so. A Firefox
    /// history database counts as something to clear although it is not
    /// measured: it stays on disk, so its size is not what the clear frees.
    private var found: [BrowserEntry] {
        viewModel.browsers.filter(\.hasData)
    }

    private var items: [ScanResultItem] {
        found.map { entry in
            ScanResultItem(id: rowID(entry.id),
                           title: loc.s("privacy.item"),
                           path: sharedFolder(of: entry.allFiles),
                           context: context(for: entry),
                           bytes: entry.totalSize)
        }
    }

    /// The column is the browser; a browser holding its own files says so here,
    /// because the row has no other place to carry a state.
    private func context(for entry: BrowserEntry) -> String {
        entry.isRunning ? "\(entry.name) · \(loc.s("privacy.running"))" : entry.name
    }

    /// Each row title has exactly one path under it. A browser spreads its history
    /// and its cookies over many files — and Firefox over several profiles —
    /// so the row shows the deepest folder they share.
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

    /// `BrowserEntry` is keyed by bundle id and `ScanResultItem` wants a `UUID`.
    /// Deriving one from the id keeps a row's identity — and with it the
    /// selection — across the rescan the view model runs after a batch.
    private func rowID(_ bundleID: String) -> UUID {
        var hasher = Insecure.MD5()
        hasher.update(data: Data(bundleID.utf8))
        let b = Array(hasher.finalize())
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    // MARK: Access

    /// Gates on "the scan found nothing to clear", not on `browsers.isEmpty`: the
    /// scan lists every *installed* browser, and Safari is always installed, so
    /// the array is never empty and an emptiness check could never fire. Without
    /// Full Disk Access every Safari path is TCC-protected and measures 0, which
    /// would render the green "all clean" state over history and cookies that
    /// simply could not be read. (Same pattern as SystemDataView.)
    private var blockedByAccess: Bool {
        viewModel.hasScanned && !viewModel.isScanning && !hasFullDiskAccess
            && !viewModel.browsers.contains(where: \.hasData) && !viewModel.skipped.needsNotice
    }

    private var accessScreen: some View {
        ScreenBody {
            ScreenHeader(title: loc.s("nav.privacy"))
            StateView(.noAccess(missing: loc.s("privacy.noAccessMissing"),
                                openSettings: { FullDiskAccess.openSettings() },
                                scanAnyway: { viewModel.scan() }))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
        }
    }

    // MARK: Clearing

    /// The totals are recalculated under the filter, so the action has to obey
    /// it too: the bottom bar counts only the rows the filter left on screen,
    /// and clearing one it hid would touch something the user cannot see.
    private var chosen: [BrowserEntry] {
        found.filter {
            selection.contains(rowID($0.id)) && $0.totalSize >= sizeFilter.minimumBytes
        }
    }

    private func prepareConfirmation() {
        guard !viewModel.isScanning, !viewModel.isClearing else { return }
        let entries = chosen
        guard !entries.isEmpty else { return }
        let running = entries.filter { PrivacyManager.blockingProcess(for: $0.id) != nil }
        confirmation = ClearConfirmation(entries: entries, authorizedToQuit: Set(running.map(\.id)))
        showClearConfirm = true
    }
}
