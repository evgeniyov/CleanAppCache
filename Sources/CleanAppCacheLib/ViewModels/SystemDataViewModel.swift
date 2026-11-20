import Foundation
import AppKit

@MainActor
public final class SystemDataViewModel: ObservableObject {
    @Published public var components: [SystemDataComponent] = []
    @Published public var snapshots: [TMSnapshot] = []
    /// True when tmutil refused to list snapshots. The snapshots row must then
    /// say "couldn't read", never claim zero — a refusal and an empty list are
    /// different answers.
    @Published public var snapshotsUnreadable = false
    /// Set when a snapshot operation was refused for want of Full Disk Access;
    /// the view renders the FDA banner off this until dismissed.
    @Published public var snapshotAccessDenied = false
    @Published public var isScanning = false
    @Published public var hasScanned = false
    @Published public var isDeletingSnapshot = false

    public var isBusy: Bool { isScanning || isDeletingSnapshot }

    private let manager: SystemDataManager
    private let scanSystemData: @Sendable () async -> SystemDataManager.ScanOutcome

    public convenience init() {
        self.init(manager: .shared, scan: { await SystemDataManager.shared.scan() })
    }

    init(manager: SystemDataManager, scan: @escaping @Sendable () async -> SystemDataManager.ScanOutcome) {
        self.manager = manager
        self.scanSystemData = scan
    }

    public func scan() {
        guard !isBusy else { return }
        isScanning = true
        hasScanned = true
        Task { await refresh() }
    }

    private func refresh() async {
        let outcome = await scanSystemData()
        components = outcome.components
        snapshots = outcome.snapshots ?? []
        snapshotsUnreadable = outcome.snapshots == nil
        isScanning = false
    }

    @discardableResult
    public func deleteSnapshot(_ snapshot: TMSnapshot) -> Bool {
        guard !isBusy, snapshots.contains(where: { $0.id == snapshot.id }) else { return false }
        isDeletingSnapshot = true
        Task {
            if let failure = await manager.deleteSnapshot(snapshot) {
                show(failure)
            } else {
                snapshots.removeAll { $0.id == snapshot.id }
                ToastCenter.shared.success(Localizer.shared.s("sysdata.snapshotDeleted"))
            }
            isDeletingSnapshot = false
        }
        return true
    }

    public func thinAllSnapshots() {
        guard !isBusy, !snapshots.isEmpty else { return }
        isDeletingSnapshot = true
        Task {
            if let failure = await manager.thinAllSnapshots() {
                show(failure)
            } else {
                ToastCenter.shared.success(Localizer.shared.s("sysdata.thinDone"))
            }
            // Keep all actions blocked until Time Machine's updated list is published.
            isScanning = true
            await refresh()
            isDeletingSnapshot = false
        }
    }

    /// Surfaces a tmutil refusal for what it is. The generic "couldn't delete"
    /// toast stays for the anonymous case; a rights refusal names its cause,
    /// and the FDA one additionally raises the banner with the fix.
    private func show(_ failure: TMUtilFailure) {
        let loc = Localizer.shared
        switch failure {
        case .needsFullDiskAccess:
            snapshotAccessDenied = true
            ToastCenter.shared.error(loc.s("sysdata.snapshotError.fda"))
        case .notPermitted:
            ToastCenter.shared.error(loc.s("sysdata.snapshotError.notPermitted"))
        case .failed:
            ToastCenter.shared.error(loc.s("sysdata.snapshotDeleteFailed"))
        }
    }

    public func snapshotDateText(_ snapshot: TMSnapshot) -> String {
        guard let date = snapshot.date else { return snapshot.dateToken }
        return Self.stamp(for: Localizer.shared.locale).string(from: date)
    }

    /// One formatter per locale. Building a `DateFormatter` is an ICU setup;
    /// this runs once per snapshot row on every re-render.
    private static var stampCache: (locale: Locale, formatter: DateFormatter)?

    private static func stamp(for locale: Locale) -> DateFormatter {
        if let cached = stampCache, cached.locale == locale { return cached.formatter }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = locale
        stampCache = (locale, f)
        return f
    }
}
