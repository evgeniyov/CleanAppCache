import Foundation
import AppKit

/// Tells the user why items were not removed, one toast per kind of obstacle,
/// each with the one action that can resolve it.
///
/// "Couldn't delete: 3" was the whole report before: it gave no reason and no
/// way forward, and a root-owned folder, a privacy refusal and a SIP-protected
/// file each need a different answer.
@MainActor
public enum RemovalReport {

    public static func present(failed: [URL], obstacles: [URL: RemovalObstacle],
                               escalation: EscalationOutcome?, permanent: Bool) {
        guard !failed.isEmpty else { return }
        let loc = Localizer.shared
        var groups: [RemovalObstacle: [URL]] = [:]
        for url in failed { groups[obstacles[url] ?? .other, default: []].append(url) }

        for obstacle in RemovalObstacle.allCases {
            guard let urls = groups[obstacle], !urls.isEmpty else { continue }
            let count = Fmt.plural("plural.objects", urls.count)
            switch obstacle {
            case .needsAdmin:
                presentNeedsAdmin(urls, count: count, escalation: escalation)
            case .privacyProtected:
                // An app bundle is guarded by App Management; everything else
                // this app reaches for is behind Full Disk Access.
                let bundles = urls.contains { $0.pathExtension.lowercased() == "app" }
                ToastCenter.shared.show(Toast(
                    style: .warning,
                    title: loc.f("removal.privacyFmt", count),
                    message: explanation(loc.s(bundles ? "removal.appManagementHint" : "removal.fdaHint"), urls: urls),
                    actionTitle: loc.s("removal.openSettings"),
                    duration: 12,
                    action: { bundles ? openAppManagementSettings() : FullDiskAccess.openSettings() }
                ))
            case .systemProtected:
                ToastCenter.shared.show(Toast(
                    style: .warning,
                    title: loc.f("removal.systemFmt", count),
                    message: explanation(loc.s("removal.systemHint"), urls: urls),
                    duration: 9
                ))
            case .locked:
                ToastCenter.shared.show(Toast(
                    style: .warning,
                    title: loc.f("removal.lockedFmt", count),
                    message: explanation(loc.s("removal.lockedHint"), urls: urls),
                    actionTitle: loc.s("common.revealInFinder"),
                    duration: 12,
                    action: { reveal(urls) }
                ))
            case .inUse:
                ToastCenter.shared.show(Toast(
                    style: .warning,
                    title: loc.f("removal.inUseFmt", count),
                    message: explanation(loc.s("removal.inUseHint"), urls: urls),
                    duration: 9
                ))
            case .changedSinceScan:
                ToastCenter.shared.show(Toast(
                    style: .warning,
                    title: loc.f("removal.changedSinceScanFmt", count),
                    message: explanation(loc.s("removal.rescanHint"), urls: urls),
                    duration: 12
                ))
            case .other:
                ToastCenter.shared.show(Toast(
                    style: .error,
                    title: loc.f(permanent ? "toast.deleteFailedFmt" : "trash.failedFmt", urls.count),
                    message: explanation(nil, urls: urls),
                    actionTitle: loc.s("common.revealInFinder"),
                    duration: 9,
                    action: { reveal(urls) }
                ))
            }
        }
    }

    private static func presentNeedsAdmin(_ urls: [URL], count: String, escalation: EscalationOutcome?) {
        let loc = Localizer.shared
        switch escalation {
        case .cancelled:
            ToastCenter.shared.show(Toast(
                style: .warning,
                title: loc.f("removal.adminCancelledFmt", count),
                message: explanation(nil, urls: urls),
                duration: 9
            ))
        case .automationDenied:
            ToastCenter.shared.show(Toast(
                style: .warning,
                title: loc.s("removal.automationDenied"),
                message: explanation(loc.s("removal.automationHint"), urls: urls),
                actionTitle: loc.s("removal.openSettings"),
                duration: 12,
                action: openAutomationSettings
            ))
        case .completed, .failed, nil:
            ToastCenter.shared.show(Toast(
                style: .warning,
                title: loc.f("removal.needsAdminFmt", count),
                message: explanation(loc.s("removal.needsAdminHint"), urls: urls),
                actionTitle: loc.s("common.revealInFinder"),
                duration: 12,
                action: { reveal(urls) }
            ))
        }
    }

    /// Include concrete paths so several simultaneous cleanup warnings can be
    /// tied back to the affected items. Keep large batches bounded.
    static func explanation(_ hint: String?, urls: [URL]) -> String {
        let paths = urls.prefix(3).map { ($0.path as NSString).abbreviatingWithTildeInPath }
        let suffix = urls.count > 3 ? " …" : ""
        return [hint, paths.joined(separator: "; ") + suffix]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func reveal(_ urls: [URL]) {
        let existing = urls.filter { !RemovalCheck.isMissing($0) }
        NSWorkspace.shared.activateFileViewerSelecting(existing.isEmpty ? urls : existing)
    }

    static func openAppManagementSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
