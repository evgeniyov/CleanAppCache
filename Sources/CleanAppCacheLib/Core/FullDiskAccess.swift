import Foundation
import AppKit

/// Helpers around macOS "Full Disk Access" (TCC). Without it, many locations
/// such as `~/Library/Caches/com.apple.*`, Safari data and Containers can't be
/// measured or cleaned, which silently skews results.
public enum FullDiskAccess {

    /// Reliable probe for whether the app holds Full Disk Access.
    ///
    /// The canonical FDA indicator is the user's TCC database
    /// (`~/Library/Application Support/com.apple.TCC/TCC.db`): it always exists
    /// on a normal install, and *opening it for reading* succeeds only when the
    /// process has Full Disk Access. We attempt an actual read (a couple of
    /// bytes) rather than just `fileExists`, because the file is present but
    /// unreadable without FDA. We fall back to directory-enumeration probes if
    /// the database is somehow missing.
    public static func isGranted() -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // Primary signal: can we open the TCC database for reading?
        let tccDB = home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        if fm.fileExists(atPath: tccDB) {
            if let fh = FileHandle(forReadingAtPath: tccDB) {
                defer { try? fh.close() }
                // Reading even a single byte requires FDA; failure throws/returns nil.
                if (try? fh.read(upToCount: 1)) != nil {
                    return true
                }
            }
            return false
        }

        // Fallback: try enumerating a protected directory.
        let probes = [
            "Library/Safari",
            "Library/Application Support/MobileSync"
        ].map { home.appendingPathComponent($0).path }

        for path in probes where fm.fileExists(atPath: path) {
            return (try? fm.contentsOfDirectory(atPath: path)) != nil
        }

        // Genuinely undetermined (TCC.db and both probe dirs missing). Don't claim
        // access we couldn't verify: returning `true` here hides the FDA hint and
        // lets scans silently under-report protected dirs as empty. Prefer showing
        // the (dismissible) hint over reporting wrong sizes.
        return false
    }

    /// Opens System Settings at Privacy & Security → Full Disk Access.
    @MainActor
    public static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
