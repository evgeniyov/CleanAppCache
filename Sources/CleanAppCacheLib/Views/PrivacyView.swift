import SwiftUI
import AppKit
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
    /// Whether any chosen browser was alive when the dialog opened — see
    /// `probeRunning()`.
    @State private var anyRunning = false
    /// A clear can span several browsers and a quit, so it outlives the view
    /// model's per-entry `clearingID`.
    @State private var isClearing = false
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
                               onApply: {
                                   guard !isClearing else { return }
                                   anyRunning = probeRunning()
                                   showClearConfirm = true
                               })
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
            confirmTitle, isPresented: $showClearConfirm, titleVisibility: .visible
        ) {
            // The volume goes in the button. A running browser changes the
            // button, because the clear then starts by quitting it.
            //
            // Not `common.moveToTrashFmt`, which the six recoverable sections
            // use: nothing here goes to the Trash, and a button that says it
            // does is the one thing the user would read before pressing.
            Button(anyRunning
                   ? loc.f("privacy.quitAndClearFmt", Fmt.bytes(chosenBytes))
                   : loc.f("privacy.deleteForGoodFmt", Fmt.bytes(chosenBytes)),
                   role: .destructive) { clearChosen() }
            Button(loc.s("common.cancel"), role: .cancel) {}
        } message: {
            Text(loc.s(anyRunning ? "privacy.confirmQuitMsg" : "privacy.confirmClearMsg"))
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
    /// selection — across the rescan the view model runs after every clear.
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
            && !viewModel.browsers.contains(where: \.hasData)
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

    private var chosenBytes: UInt64 {
        chosen.reduce(UInt64(0)) { $0 &+ $1.totalSize }
    }

    /// Live, not the flag the scan captured: the user may have opened the
    /// browser since, and the dialog has to describe what will actually happen.
    ///
    /// Probed once, when the dialog opens, and held in `anyRunning` for as long
    /// as it is up: `blockingProcess` walks the process list and asks
    /// LaunchServices where the app lives, which is far too much to repeat on
    /// every evaluation of the body. The delete re-checks it for real anyway —
    /// this answer only has to be right at the moment the user is asked.
    private func probeRunning() -> Bool {
        chosen.contains { $0.isRunning || PrivacyManager.blockingProcess(for: $0.id) != nil }
    }

    /// The title names the browsers rather than counting rows: with at most
    /// five of them the list is short, and "Clear items (2)?" would not
    /// tell the user which two sessions they are about to lose.
    private var confirmTitle: String {
        let names = chosen.map(\.name).joined(separator: ", ")
        return loc.f(anyRunning ? "privacy.confirmQuitFmt" : "privacy.confirmClearFmt", names)
    }

    /// Nothing here is reachable without a tick and a confirmation: `chosen` is
    /// the intersection of the user's selection with the rows the size filter
    /// left visible, and the only caller is the destructive button in the
    /// dialog above.
    private func clearChosen() {
        let targets = chosen
        guard !targets.isEmpty else { return }
        isClearing = true
        Task {
            for entry in targets {
                if let app = runningApp(for: entry) {
                    // A request, never a kill: the browser still gets to ask
                    // about unsaved pages, and it is allowed to refuse.
                    app.terminate()
                    guard await waitForExit(of: entry.id) else {
                        ToastCenter.shared.error(loc.f("privacy.quitFailedFmt", entry.name))
                        continue
                    }
                }
                // Refuse rather than half-delete, and say why: a helper process
                // still holding the profile leaves nothing on screen to explain
                // a row that did not change.
                guard let ready = unblocked(entry) else {
                    ToastCenter.shared.error(loc.f("privacy.quitFailedFmt", entry.name))
                    continue
                }
                await viewModel.clearHistory(for: ready)
            }
            selection = []
            isClearing = false
        }
    }

    /// `PrivacyViewModel` gates the clear on the `isRunning` flag captured
    /// during the scan, which is stale once we have watched the process leave.
    /// Re-check the live process list and only then hand over an entry that
    /// says the browser is gone: the guard's intent — never touch a running
    /// browser's files — is preserved, and it is measured against the
    /// present instead of against the last scan. `PrivacyManager` repeats the
    /// same check immediately before deleting, so this cannot be the only one.
    private func unblocked(_ entry: BrowserEntry) -> BrowserEntry? {
        guard PrivacyManager.blockingProcess(for: entry.id) == nil else { return nil }
        var ready = entry
        ready.isRunning = false
        return ready
    }

    /// Polls the live process list rather than holding the
    /// `NSRunningApplication`, so it also catches a browser that comes straight
    /// back up. `blockingProcess` waits for the helpers too: Chromium's
    /// renderers keep the cookie jar open for a moment after the main app is
    /// gone, and that moment is when a delete corrupts the profile.
    private func waitForExit(of bundleID: String) async -> Bool {
        for _ in 0..<40 {                                   // ~10s at 250ms
            if PrivacyManager.blockingProcess(for: bundleID) == nil { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return PrivacyManager.blockingProcess(for: bundleID) == nil
    }

    private func runningApp(for entry: BrowserEntry) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == entry.id }
    }
}
