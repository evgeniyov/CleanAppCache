import Foundation
import SwiftUI
import AppKit

@MainActor
public final class AppsViewModel: ObservableObject {

    public enum SortMode: String, CaseIterable, Identifiable {
        case nameAsc   = "sort.nameAsc"
        case nameDesc  = "sort.nameDesc"
        case sizeDesc  = "sort.sizeDesc"
        case sizeAsc   = "sort.sizeAsc"
        public var id: String { rawValue }
    }

    @Published public var apps: [InstalledApp] = []
    @Published public var isLoading = false
    @Published public var searchText = ""
    @Published public var sortMode: SortMode = .nameAsc
    @Published public var selectedApp: InstalledApp?
    @Published public var isUninstalling = false
    @Published public var loadProgress: Double = 0
    /// Whether the user has run a scan yet (drives the idle vs. list state).
    @Published public var hasScanned = false

    private let appManager = AppManager.shared

    public var filteredApps: [InstalledApp] {
        var result = searchText.isEmpty
            ? apps
            : apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        switch sortMode {
        case .nameAsc:  result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDesc: result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .sizeDesc: result.sort { $0.totalSize > $1.totalSize }
        case .sizeAsc:  result.sort { $0.totalSize < $1.totalSize }
        }
        return result
    }

    public init() {}

    /// Selects the app in Finder (opens its containing folder, highlighted).
    public func revealInFinder(_ app: InstalledApp) {
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    /// Localized "installed on" date, or "—" when unknown.
    public func installDateText(_ app: InstalledApp) -> String {
        // Shared, cached formatter — building one per row per render cost
        // tens of milliseconds on a list of a few hundred apps.
        Localizer.shared.date(app.installDate)
    }

    /// The running scan. Kept so Cancel stops it for real and so a result
    /// that lands after a newer scan started is dropped instead of replacing
    /// the newer list (and silently clearing the selection made on it).
    private var scanTask: Task<Void, Never>?

    /// Starts loading the app list (used by the Scan / Rescan button).
    public func loadApps() {
        scanTask?.cancel()
        isLoading = true
        hasScanned = true
        loadProgress = 0

        scanTask = Task { [weak self, appManager] in
            let result = await appManager.findInstalledApps(progress: { [weak self] current, total, _ in
                Task { @MainActor [weak self] in
                    self?.loadProgress = Double(current) / Double(max(total, 1))
                }
            })
            guard let self, !Task.isCancelled else { return }
            self.apps = result
            // Every InstalledApp gets a fresh UUID per scan, so a surviving
            // selection matches nothing — it kept a phantom bottom bar up,
            // promising deletions the uninstall could never perform.
            self.batchSelection.removeAll()
            self.isLoading = false
            self.loadProgress = 1.0
            self.scanTask = nil
        }
    }

    /// Stops the scan. The enumeration itself runs to its end inside
    /// `AppManager`, but its result is discarded.
    public func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isLoading = false
    }

    // MARK: - Uninstall

    /// An uninstall waiting for the user's confirmation, with the facts the
    /// dialog has to state before anything is deleted.
    public struct PendingUninstall: Identifiable {
        public enum Origin { case list, detail }

        public let id = UUID()
        public let origin: Origin
        public let checks: [AppManager.UninstallCheck]

        public var apps: [InstalledApp] { checks.map(\.app) }
        public var totalBytes: UInt64 { apps.reduce(0) { $0 + $1.totalSize } }
        public var needsAdmin: [InstalledApp] { checks.filter(\.needsAdmin).map(\.app) }
        public var running: [InstalledApp] { checks.filter(\.isRunning).map(\.app) }
        /// Apps whose associated files stay because another copy uses them.
        public var sharedData: [InstalledApp] {
            checks.filter { $0.sharedWith != nil || $0.app.sharedDataWith != nil }.map(\.app)
        }
    }

    @Published public var pendingUninstall: PendingUninstall?
    /// True while the pre-uninstall check runs — it walks each bundle, which
    /// takes a moment for a large one.
    @Published public var isPreparing = false

    /// Checks `targets` and then asks for confirmation through
    /// `pendingUninstall`.
    public func prepareUninstall(_ targets: [InstalledApp], from origin: PendingUninstall.Origin) {
        guard !targets.isEmpty, !isPreparing, !isUninstalling, !isBatchWorking else { return }
        isPreparing = true
        Task {
            let checks = await appManager.check(targets)
            self.isPreparing = false
            self.pendingUninstall = PendingUninstall(origin: origin, checks: checks)
        }
    }

    /// The confirmation's explanatory text: permanence first, then only the
    /// facts that apply — a password prompt, apps that will be quit, data
    /// that stays.
    public func confirmationMessage(for pending: PendingUninstall) -> String {
        let loc = Localizer.shared
        var parts: [String] = []
        if pending.apps.count == 1, let app = pending.apps.first {
            parts.append(loc.f("apps.confirmMsgFmt", app.name,
                               Fmt.plural("plural.files", app.associatedFiles.count)))
        } else {
            parts.append(loc.s("apps.batchConfirmMsg"))
        }
        parts.append(loc.s("apps.sharedContainersKept"))
        if !pending.needsAdmin.isEmpty {
            parts.append(loc.f("apps.confirmAdminFmt", Self.names(pending.needsAdmin)))
        }
        if !pending.running.isEmpty {
            parts.append(loc.f("apps.confirmQuitFmt", Self.names(pending.running)))
        }
        if !pending.sharedData.isEmpty {
            parts.append(loc.f("apps.confirmSharedFmt", Self.names(pending.sharedData)))
        }
        return parts.joined(separator: "\n\n")
    }

    private static func names(_ apps: [InstalledApp]) -> String {
        apps.map { "«\($0.name)»" }.joined(separator: ", ")
    }

    /// Runs the confirmed uninstall and reports it in one summary.
    public func confirmUninstall(_ pending: PendingUninstall) async {
        pendingUninstall = nil
        let targets = pending.apps
        guard !targets.isEmpty, !isUninstalling, !isBatchWorking else { return }
        isUninstalling = true
        isBatchWorking = true
        let loc = Localizer.shared

        let results = await appManager.uninstall(
            targets, adminPrompt: loc.f("apps.adminPromptFmt",
                              Self.names(pending.needsAdmin.isEmpty ? targets : pending.needsAdmin)))

        var removedApps: [InstalledApp] = []
        var freed: UInt64 = 0
        var removedItems = 0
        var bundleFailures: [URL] = []
        var bundleObstacles: [URL: RemovalObstacle] = [:]
        var assocFailures: [URL] = []
        var assocObstacles: [URL: RemovalObstacle] = [:]
        var stillRunning: [InstalledApp] = []
        var changedApps: [InstalledApp] = []
        var cancelled: [InstalledApp] = []
        var blocked = 0

        for r in results {
            freed += r.freedBytes
            removedItems += r.associatedRemoved + (r.bundleRemoved ? 1 : 0)
            assocFailures += r.associatedFailed
            for url in r.associatedFailed { assocObstacles[url] = r.associatedObstacles[url] }
            if r.bundleRemoved {
                removedApps.append(r.app)
            } else if r.bundleChanged {
                changedApps.append(r.app)
            } else if r.stillRunning {
                stillRunning.append(r.app)
            } else if r.bundleBlocked {
                blocked += 1
            } else if r.escalation == .cancelled {
                cancelled.append(r.app)
            } else {
                bundleFailures.append(r.app.url)
                bundleObstacles[r.app.url] = r.bundleObstacle ?? .other
            }
        }

        let removedIDs = Set(removedApps.map(\.url))
        apps.removeAll { removedIDs.contains($0.url) }
        batchSelection.subtract(removedApps.map(\.id))
        if !removedApps.isEmpty {
            await StorageManager.shared.invalidate(
                deleted: removedApps.flatMap { [$0.url] + $0.associatedFiles.map(\.url) })
            CleanupHistory.shared.log(.uninstaller, items: removedItems, freedBytes: freed)
        }
        isUninstalling = false
        isBatchWorking = false
        if let open = selectedApp, removedIDs.contains(open.url) { selectedApp = nil }

        let freedText = Fmt.bytes(Int64(freed))
        if removedApps.count == 1, results.count == 1, let app = removedApps.first {
            ToastCenter.shared.success(loc.f("apps.uninstalledFmt", app.name), loc.f("apps.freedFmt", freedText))
        } else if !removedApps.isEmpty {
            ToastCenter.shared.success(loc.f("apps.batchDoneFmt", Fmt.plural("plural.apps", removedApps.count), freedText))
        }
        if !stillRunning.isEmpty {
            ToastCenter.shared.show(Toast(
                style: .warning,
                title: loc.f("apps.stillRunningFmt", Self.names(stillRunning)),
                message: loc.s("apps.stillRunningHint"),
                duration: 10
            ))
        }
        if !changedApps.isEmpty {
            ToastCenter.shared.show(Toast(
                style: .warning,
                title: loc.f("apps.changedSinceScanFmt", Self.names(changedApps)),
                message: loc.s("apps.rescanBeforeRemoval"),
                duration: 12
            ))
        }
        if !cancelled.isEmpty {
            ToastCenter.shared.show(Toast(
                style: .warning,
                title: loc.f("apps.adminCancelledFmt", Self.names(cancelled)),
                message: loc.s("apps.adminCancelledHint"),
                duration: 10
            ))
        }
        if blocked > 0 {
            ToastCenter.shared.error(loc.f("guard.blockedFmt", Fmt.plural("plural.protectedPaths", blocked)))
        }
        RemovalReport.present(failed: bundleFailures, obstacles: bundleObstacles,
                              escalation: nil, permanent: true)
        RemovalReport.present(failed: assocFailures, obstacles: assocObstacles,
                              escalation: nil, permanent: true)
    }

    // MARK: - Batch selection

    @Published public var batchSelection: Set<UUID> = []
    @Published public var isBatchWorking = false

    public func toggleBatch(_ app: InstalledApp) {
        if batchSelection.contains(app.id) { batchSelection.remove(app.id) }
        else { batchSelection.insert(app.id) }
    }

    public var batchApps: [InstalledApp] { apps.filter { batchSelection.contains($0.id) } }
    public var batchSize: UInt64 { batchApps.reduce(0) { $0 + $1.totalSize } }
    public var formattedBatchSize: String {
        Fmt.bytes(Int64(batchSize))
    }
}
