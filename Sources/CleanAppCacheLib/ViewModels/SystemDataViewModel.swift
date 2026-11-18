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

    private let manager = SystemDataManager.shared

    public init() {}

    public func scan() {
        guard !isScanning else { return }
        isScanning = true
        hasScanned = true
        Task {
            let outcome = await manager.scan()
            self.components = outcome.components
            self.snapshots = outcome.snapshots ?? []
            self.snapshotsUnreadable = outcome.snapshots == nil
            self.isScanning = false
        }
    }

    public func deleteSnapshot(_ snapshot: TMSnapshot) {
        guard !isDeletingSnapshot else { return }
        isDeletingSnapshot = true
        Task {
            if let failure = await manager.deleteSnapshot(snapshot) {
                show(failure)
            } else {
                snapshots.removeAll { $0.id == snapshot.id }
                ToastCenter.shared.success(Localizer.shared.s("sysdata.snapshotDeleted"))
            }
            self.isDeletingSnapshot = false
        }
    }

    public func thinAllSnapshots() {
        guard !isDeletingSnapshot else { return }
        isDeletingSnapshot = true
        Task {
            if let failure = await manager.thinAllSnapshots() {
                show(failure)
            } else {
                ToastCenter.shared.success(Localizer.shared.s("sysdata.thinDone"))
            }
            self.isDeletingSnapshot = false
            // Re-scan to reflect what Time Machine actually reclaimed.
            self.isScanning = true
            let outcome = await manager.scan()
            self.components = outcome.components
            self.snapshots = outcome.snapshots ?? []
            self.snapshotsUnreadable = outcome.snapshots == nil
            self.isScanning = false
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
