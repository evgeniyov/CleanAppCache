import SwiftUI

// MARK: - Startup items
//
// The adapter that states this section's data and captions for `ScanResultView`.
//
// Startup items are not measured in **seconds** (a "delay" column, values like
// "+4.2 s", a "+12.4 s to boot" total, a "speeds up launch by 4.2 s" bar), because
// macOS publishes no such number — `launchctl print` has no per-job start duration,
// the unified log times a service's *lifetime* and only on exit, and process
// start time minus login time is launchd's queue, not the item's cost. The
// reasoning and the sources are on `StartupManager.programBytes`.
//
// Passing `seconds: 0` would render all four of those as "—": a screen whose
// headline metric is a dash. So the section drops the unit it cannot
// measure and states what it does know, all of it read from the machine:
//
//   • per row  — how the entry is triggered (`runAtLoad` + launchd's override
//     database) and whose it is (`scope`), plus the on-disk size of the program
//     it launches;
//   • in the subtitle — how many of the found entries actually start at login;
//   • in the bottom bar — how many items the button is about to switch off.
//
// Nothing here is modelled or scaled from anything else. What the app cannot
// measure it does not print.

public struct StartupView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var viewModel: StartupViewModel

    @State private var selection: Set<UUID> = []
    /// Unused by this section — startup items have no size filter — but
    /// `ScanResultView` takes the binding for all eight.
    @State private var sizeFilter: ScanSizeFilter = .all
    @State private var showConfirm = false

    /// Program sizes measured by the last scan, keyed by `StartupItem.id`. Kept
    /// here rather than on the item so that the view model rebuilding an item on
    /// toggle cannot blank the column.
    @State private var programBytes: [String: UInt64] = [:]

    public init() {}

    public var body: some View {
        content
            .background(Palette.background)
            // The sizes are measured inside `scan()`, so they are ready the moment
            // scanning ends; this only carries them across the actor boundary.
            // Keyed on `isScanning` so it re-reads exactly when a scan finishes.
            .task(id: viewModel.isScanning) {
                programBytes = await StartupManager.shared.programBytes
            }
            .confirmationDialog(
                confirmTitle,
                isPresented: $showConfirm, titleVisibility: .visible
            ) {
                Button(loc.s("startup.action")) { apply() }
                Button(loc.s("common.cancel"), role: .cancel) {}
            } message: {
                Text(confirmMessage)
            }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.hasScanned, !viewModel.isScanning,
           viewModel.items.isEmpty, viewModel.loginItemsDenied {
            // Nothing found *and* Automation was refused: an empty list here is
            // a missing permission, not a clean machine. `ScanResultView` would
            // call it clean.
            noAccess
        } else {
            ScanResultView(
                config: config,
                items: items,
                hasScanned: viewModel.hasScanned,
                isScanning: viewModel.isScanning,
                // `StartupManager.scan()` is one non-cancellable actor call and
                // publishes no progress, so there is nothing to advance the bar
                // and nothing for a Cancel button to stop.
                scanProgress: 0,
                scanDetail: Self.scannedLocations,
                selection: $selection,
                sizeFilter: $sizeFilter,
                onScan: { viewModel.scan() },
                onApply: { showConfirm = true }
            )
        }
    }

    private var config: ScanResultConfig {
        ScanResultConfig(title: loc.s("nav.startup"),
                         describes: describes,
                         contextColumn: loc.s("startup.col.impact"),
                         actionTitle: loc.s("startup.action"),
                         warning: loc.s("scan.note.startup"),
                         willFind: loc.s("startup.willFind"),
                         metric: .launchImpact)
    }

    /// The subtitle's trailing half. `.launchImpact` leaves the middle slot — a
    /// volume in the other seven sections — to the section itself, so the count
    /// that actually belongs to the startup section goes here: how many of the entries
    /// found are set to start at login. That is `runAtLoad` confirmed against
    /// launchd's override database, not a guess.
    ///
    /// Login items are invisible without Automation access, so a table drawn
    /// without them is silently incomplete. The layout has no room for a separate
    /// banner, and this is the line that describes what the section
    /// actually covers — so it says it here, and drops the count, which would be
    /// counting an admittedly partial list.
    private var describes: String {
        if viewModel.loginItemsDenied { return loc.s("startup.describesDenied") }
        guard !viewModel.items.isEmpty else { return loc.s("startup.describes") }
        let atLogin = viewModel.items.filter { $0.isEnabled && $0.runAtLoad }.count
        return loc.f("startup.atLoginFmt", Fmt.count(atLogin))
            + " · " + loc.s("startup.describes")
    }

    private static let scannedLocations =
        "~/Library/LaunchAgents · /Library/LaunchAgents · /Library/LaunchDaemons"

    private var noAccess: some View {
        ScreenBody {
            ScreenHeader(title: loc.s("nav.startup"))
            StateView(.noAccess(missing: loc.s("startup.automationHint"),
                                openSettings: { viewModel.openAutomationSettings() },
                                scanAnyway: { viewModel.scan() }))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card()
        }
    }

    // MARK: Rows

    private var items: [ScanResultItem] {
        viewModel.items.map { item in
            ScanResultItem(id: ScanAdapterID.uuid(item.id),
                           title: item.displayName,
                           // Which binary the entry actually starts — the launchd
                           // label only when there is no program to name.
                           path: item.program.isEmpty
                               ? item.label
                               : (item.program as NSString).abbreviatingWithTildeInPath,
                           context: impact(item),
                           // Size of exactly the path printed above, so the figure
                           // is checkable in Finder. Missing program → 0 → "—".
                           bytes: programBytes[item.id] ?? 0)
        }
    }

    /// The launch-impact column (`startup.col.impact`) — the two facts launchd actually reports about an
    /// entry: what triggers it, and whose it is. The scope is the half that says
    /// whether the user can switch it off without an administrator.
    private func impact(_ item: StartupItem) -> String {
        let trigger: String
        if !item.isEnabled          { trigger = loc.s("startup.disabled") }
        else if item.runAtLoad      { trigger = loc.s("startup.runAtLoad") }
        else                        { trigger = loc.s("startup.onDemand") }
        return trigger + " · " + loc.s(Self.scopeKey(item.scope))
    }

    private static func scopeKey(_ scope: StartupItem.Scope) -> String {
        switch scope {
        case .loginItem:   return "startup.scope.loginItem"
        case .userAgent:   return "startup.scope.userAgent"
        case .globalAgent: return "startup.scope.globalAgent"
        case .daemon:      return "startup.scope.daemon"
        }
    }

    // MARK: Selection

    /// No size filter to honour here — this section has none.
    private var chosen: [StartupItem] {
        viewModel.items.filter { selection.contains(ScanAdapterID.uuid($0.id)) }
    }

    /// "Disable selected" (`startup.action`) — the apps stay where they are,
    /// only the autostart goes. The view model owns what that means per scope.
    private func apply() {
        viewModel.turnOff(chosen)
        selection = []
    }

    /// Counts only what the action changes, and says beforehand when daemons
    /// in the selection need an administrator password.
    private var confirmTitle: String {
        loc.f("startup.confirmDisableFmt", StartupViewModel.actionable(chosen).count)
    }

    private var confirmMessage: String {
        let daemons = StartupViewModel.actionable(chosen).filter(\.needsAdmin).count
        guard daemons > 0 else { return loc.s("scan.note.startup") }
        return loc.s("scan.note.startup") + "\n\n"
            + loc.f("startup.confirmAdminFmt", Fmt.plural("plural.items", daemons))
    }
}
