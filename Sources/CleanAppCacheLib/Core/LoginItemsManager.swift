import Foundation
import ServiceManagement

// MARK: - Login Items Manager
//
// Manages the app's own login-item registration via SMAppService (macOS 13+).
// SMAppService.mainApp registers/unregisters the running app bundle itself —
// no helper tool needed, no root required. The entry appears in
// System Settings → General → Login Items under "Open at Login".

@MainActor
public final class LoginItemsManager: ObservableObject {
    public static let shared = LoginItemsManager()

    @Published public private(set) var status: SMAppService.Status = .notRegistered

    private init() {
        refresh()
    }

    public var isEnabled: Bool { status == .enabled }

    /// True while this copy runs Gatekeeper-translocated — launched straight
    /// from the DMG (or another quarantined folder), macOS executes it from a
    /// randomized read-only mount under /private/var/…/AppTranslocation/.
    /// `SMAppService.register()` always throws for such a bundle, on every
    /// macOS version: the mount point is different on each launch, so there is
    /// nothing stable to register. The settings row renders a "run it from
    /// Applications" state off this instead of a toggle that silently fails.
    public var isTranslocated: Bool {
        Bundle.main.bundleURL.path.contains("/AppTranslocation/")
    }

    public func refresh() {
        status = SMAppService.mainApp.status
    }

    /// Enable or disable the app as a login item.
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Bool {
        // Registering a translocated bundle can only throw (see
        // `isTranslocated`) — don't let the error vanish into `return false`.
        guard !isTranslocated else { return false }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
            return true
        } catch {
            refresh()
            return false
        }
    }

    public var statusDescription: String {
        switch status {
        case .enabled:           return "loginitems.status.enabled"
        case .requiresApproval:  return "loginitems.status.requiresApproval"
        case .notRegistered:     return "loginitems.status.notRegistered"
        case .notFound:          return "loginitems.status.notFound"
        @unknown default:        return "loginitems.status.notRegistered"
        }
    }
}
