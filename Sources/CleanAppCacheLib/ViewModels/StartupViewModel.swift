import Foundation
import SwiftUI
import AppKit

@MainActor
public final class StartupViewModel: ObservableObject {
    @Published public var items: [StartupItem] = []
    @Published public var isScanning = false
    @Published public var hasScanned = false
    @Published public var searchText = ""
    /// True when login items couldn't be read (Automation permission denied).
    @Published public var loginItemsDenied = false

    private let manager = StartupManager.shared

    public init() {}

    public var filtered: [StartupItem] {
        guard !searchText.isEmpty else { return items }
        return items.filter {
            $0.label.localizedCaseInsensitiveContains(searchText) ||
            $0.program.localizedCaseInsensitiveContains(searchText)
        }
    }

    public func scan() {
        guard !isScanning else { return }
        isScanning = true
        hasScanned = true
        Task {
            let result = await manager.scan()
            self.items = result
            self.loginItemsDenied = await manager.loginItemsDenied
            self.isScanning = false
        }
    }

    /// Opens Automation settings so the user can allow System Events control,
    /// which is required to read/manage login items.
    public func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Items `turnOff` would change: login items, and agents or daemons
    /// that are still on. An already-disabled job has nothing to switch off.
    public static func actionable(_ chosen: [StartupItem]) -> [StartupItem] {
        chosen.filter { $0.scope == .loginItem || $0.isEnabled }
    }

    /// Switches the chosen items off, each the way its kind allows, and
    /// reports the batch in one summary:
    /// - a login item leaves the login-items list (System Events);
    /// - an agent — the user's own or one in `/Library/LaunchAgents` — gets a
    ///   per-user launchd override and leaves the running session;
    /// - daemons are disabled in the system domain as root, after one
    ///   administrator password for all of them.
    public func turnOff(_ chosen: [StartupItem]) {
        let targets = Self.actionable(chosen)
        guard !targets.isEmpty else { return }
        let loc = Localizer.shared
        Task {
            var done: [StartupItem] = []
            var failed: [StartupItem] = []

            for item in targets where item.scope == .loginItem {
                if await manager.removeLoginItem(item) { done.append(item) } else { failed.append(item) }
            }
            for item in targets where item.scope == .userAgent || item.scope == .globalAgent {
                if await manager.setEnabled(false, for: item) { done.append(item) } else { failed.append(item) }
            }
            let daemons = targets.filter { $0.scope == .daemon }
            var cancelled = false
            if !daemons.isEmpty {
                let prompt = loc.f("startup.adminPromptFmt",
                                   daemons.map { "«\($0.displayName)»" }.joined(separator: ", "))
                let result = await manager.disableDaemons(daemons, prompt: prompt)
                cancelled = result.outcome == .cancelled
                for item in daemons {
                    if result.disabled.contains(item.label) { done.append(item) }
                    else if !cancelled { failed.append(item) }
                }
            }

            let removed = Set(done.filter { $0.scope == .loginItem }.map(\.id))
            let switched = Set(done.filter { $0.scope != .loginItem }.map(\.id))
            items = items.compactMap { item in
                if removed.contains(item.id) { return nil }
                guard switched.contains(item.id) else { return item }
                return StartupItem(label: item.label, program: item.program,
                                   plistURL: item.plistURL, scope: item.scope,
                                   runAtLoad: item.runAtLoad, isEnabled: false)
            }

            if !done.isEmpty {
                ToastCenter.shared.success(loc.f("startup.turnedOffFmt", Fmt.plural("plural.items", done.count)))
            }
            if cancelled {
                ToastCenter.shared.show(Toast(
                    style: .warning,
                    title: loc.f("removal.adminCancelledFmt", Fmt.plural("plural.items", daemons.count)),
                    duration: 9
                ))
            }
            if !failed.isEmpty {
                ToastCenter.shared.error(
                    loc.f("startup.turnOffFailedFmt",
                          failed.map { "«\($0.displayName)»" }.joined(separator: ", ")))
            }
        }
    }

    public func revealInFinder(_ item: StartupItem) {
        NSWorkspace.shared.selectFile(item.plistURL.path, inFileViewerRootedAtPath: "")
    }
}
