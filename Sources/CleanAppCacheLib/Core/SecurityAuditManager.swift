import Foundation

// MARK: - Security check model

/// One security-hygiene check. Everything here is READ-ONLY — the audit never
/// changes settings; it reports state and (when not passing) links the user to
/// the relevant System Settings pane so they can fix it themselves.
public struct SecurityCheck: Identifiable, Sendable {
    public enum Status: String, Sendable {
        case pass       // secure
        case fail       // insecure — should fix
        case warn       // not ideal / worth a look
        case unknown    // couldn't determine (e.g. sensor/setting unavailable)
    }

    public let id: String
    /// SF Symbol for the check.
    public let icon: String
    /// Localization keys (resolved in the view via Localizer).
    public let titleKey: String
    public let detailKey: String        // describes the current state
    public let fixHintKey: String?      // how to fix it (nil when passing)
    public let status: Status
    /// Optional System Settings deep link (`x-apple.systempreferences:…`).
    public let settingsURL: String?
}

// MARK: - Security audit manager

/// Pareto-style local security audit. Runs a set of read-only checks against
/// macOS security settings using public tools (`fdesetup`, `spctl`, `csrutil`,
/// `socketfilterfw`, `defaults`). No admin rights required; nothing is modified.
public actor SecurityAuditManager {
    public static let shared = SecurityAuditManager()
    private init() {}

    public func runAudit() async -> [SecurityCheck] {
        // Sequential: each check is a quick CLI call (tens of ms).
        let loginPreferences = Self.run("/usr/bin/defaults",
                                       ["export", "/Library/Preferences/com.apple.loginwindow", "-"])
            .map { Data($0.utf8) }
        let login = Self.loginChecks(propertyList: loginPreferences)
        return [
            fileVaultCheck(),
            firewallCheck(),
            gatekeeperCheck(),
            sipCheck(),
            login.automaticLogin,
            login.guest,
            softwareUpdateCheck(),
            screenLockCheck()
        ]
    }

    // MARK: - Individual checks

    /// Picks the detail string for a three-way check.
    ///
    /// `.unknown` gets its own message. Folding it into the "off" branch
    /// turns "the probe didn't run" into a
    /// confident, wrong claim that the user's disk is unencrypted or that SIP is
    /// disabled — the most alarming thing this screen can say, asserted from no
    /// evidence.
    private func detail(_ status: SecurityCheck.Status, _ base: String) -> String {
        switch status {
        case .pass:            return base + ".on"
        case .fail, .warn:     return base + ".off"
        case .unknown:         return base + ".unknown"
        }
    }

    private func fileVaultCheck() -> SecurityCheck {
        let out = Self.run("/usr/bin/fdesetup", ["status"])?.lowercased() ?? ""
        let status: SecurityCheck.Status =
            out.contains("filevault is on") ? .pass :
            out.contains("filevault is off") ? .fail : .unknown
        return SecurityCheck(
            id: "filevault", icon: "lock.shield",
            titleKey: "sec.filevault.title",
            detailKey: detail(status, "sec.filevault"),
            fixHintKey: status == .fail ? "sec.filevault.fix" : nil,
            status: status,
            settingsURL: "x-apple.systempreferences:com.apple.preference.security?FileVault"
        )
    }

    private func firewallCheck() -> SecurityCheck {
        let out = Self.run("/usr/libexec/ApplicationFirewall/socketfilterfw",
                           ["--getglobalstate"])?.lowercased() ?? ""
        let status: SecurityCheck.Status =
            out.contains("enabled") ? .pass :
            out.contains("disabled") ? .fail : .unknown
        return SecurityCheck(
            id: "firewall", icon: "firewall",
            titleKey: "sec.firewall.title",
            detailKey: detail(status, "sec.firewall"),
            fixHintKey: status == .fail ? "sec.firewall.fix" : nil,
            status: status,
            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Firewall"
        )
    }

    private func gatekeeperCheck() -> SecurityCheck {
        let out = Self.run("/usr/sbin/spctl", ["--status"])?.lowercased() ?? ""
        let status: SecurityCheck.Status =
            out.contains("assessments enabled") ? .pass :
            out.contains("assessments disabled") ? .fail : .unknown
        return SecurityCheck(
            id: "gatekeeper", icon: "checkmark.shield",
            titleKey: "sec.gatekeeper.title",
            detailKey: detail(status, "sec.gatekeeper"),
            fixHintKey: status == .fail ? "sec.gatekeeper.fix" : nil,
            status: status,
            settingsURL: "x-apple.systempreferences:com.apple.preference.security?General"
        )
    }

    private func sipCheck() -> SecurityCheck {
        let out = Self.run("/usr/bin/csrutil", ["status"])?.lowercased() ?? ""
        // "Custom Configuration" means some protections were turned off
        // individually — reported before the plain enabled/disabled test,
        // because that output still contains the word "enabled" and would
        // otherwise be waved through as fully protected.
        let status: SecurityCheck.Status =
            out.contains("custom configuration") ? .warn :
            out.contains("status: enabled") ? .pass :
            out.contains("status: disabled") ? .fail : .unknown
        return SecurityCheck(
            id: "sip", icon: "shield.lefthalf.filled",
            titleKey: "sec.sip.title",
            detailKey: detail(status, "sec.sip"),
            fixHintKey: (status == .fail || status == .warn) ? "sec.sip.fix" : nil,
            status: status,
            settingsURL: nil    // only changeable from Recovery
        )
    }

    /// Only a readable preferences domain establishes that a key is absent.
    /// A failed command or malformed plist provides no evidence of protection.
    nonisolated static func loginChecks(propertyList: Data?) -> (automaticLogin: SecurityCheck, guest: SecurityCheck) {
        let preferences = propertyList.flatMap {
            (try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil)) as? [String: Any]
        }
        let automaticStatus: SecurityCheck.Status
        if let preferences {
            if let value = preferences["autoLoginUser"] {
                if let user = value as? String {
                    automaticStatus = user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .pass : .fail
                } else { automaticStatus = .unknown }
            } else { automaticStatus = .pass }
        } else { automaticStatus = .unknown }
        let automaticLogin = SecurityCheck(
            id: "autologin", icon: "person.badge.key",
            titleKey: "sec.autologin.title",
            detailKey: automaticStatus == .fail ? "sec.autologin.on" :
                       automaticStatus == .pass ? "sec.autologin.off" : "sec.autologin.unknown",
            fixHintKey: automaticStatus == .fail ? "sec.autologin.fix" : nil,
            status: automaticStatus,
            // The System Settings extension ID, not the System Preferences-era
            // pane ID ("com.apple.preferences.users"): on 13+ the pane ID
            // doesn't resolve and Settings just opens wherever it last was.
            settingsURL: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension"
        )

        let guestStatus: SecurityCheck.Status
        if let preferences {
            if let value = preferences["GuestEnabled"] {
                if let enabled = value as? NSNumber, enabled == 1 { guestStatus = .warn }
                else if let enabled = value as? NSNumber, enabled == 0 { guestStatus = .pass }
                else { guestStatus = .unknown }
            } else { guestStatus = .pass }
        } else { guestStatus = .unknown }
        let guest = SecurityCheck(
            id: "guest", icon: "person.crop.circle.badge.questionmark",
            titleKey: "sec.guest.title",
            detailKey: guestStatus == .warn ? "sec.guest.on" :
                       guestStatus == .pass ? "sec.guest.off" : "sec.guest.unknown",
            fixHintKey: guestStatus == .warn ? "sec.guest.fix" : nil,
            status: guestStatus,
            settingsURL: "x-apple.systempreferences:com.apple.Users-Groups-Settings.extension"
        )
        return (automaticLogin, guest)
    }

    private func softwareUpdateCheck() -> SecurityCheck {
        // `softwareupdate --schedule` first. The `AutomaticCheckEnabled` key
        // is simply not written on current macOS — verified absent on macOS 27,
        // where `defaults read` exits 1 — so relying on it alone reports
        // "couldn't read the update setting" on every modern Mac while
        // automatic checking is in fact switched on.
        var status: SecurityCheck.Status = .unknown
        if let sched = Self.run("/usr/sbin/softwareupdate", ["--schedule"])?.lowercased() {
            if sched.contains("turned on") { status = .pass }
            else if sched.contains("turned off") { status = .warn }
        }
        if status == .unknown {
            let out = Self.run("/usr/bin/defaults",
                               ["read", "/Library/Preferences/com.apple.SoftwareUpdate", "AutomaticCheckEnabled"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if out == "1" { status = .pass }
            else if out == "0" { status = .warn }
        }
        return SecurityCheck(
            id: "updates", icon: "arrow.triangle.2.circlepath",
            titleKey: "sec.updates.title",
            detailKey: status == .pass ? "sec.updates.on" :
                       status == .warn ? "sec.updates.off" : "sec.updates.unknown",
            fixHintKey: status == .warn ? "sec.updates.fix" : nil,
            status: status,
            // The extension ID opens this pane on macOS 13 and later.
            settingsURL: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
        )
    }

    private func screenLockCheck() -> SecurityCheck {
        // `sysadminctl -screenLock status` is the supported query on current
        // macOS, and it reports on stderr — hence `mergeStderr`. It prints
        // "screenLock delay is <n> seconds"/"immediate" when a password is
        // required and "screenLock is off" when it is not.
        //
        // The old `com.apple.screensaver askForPassword` read is kept only as a
        // fallback for older systems: the key is absent on macOS 27 (verified),
        // so on its own this check answered "unknown" on every modern Mac.
        var status: SecurityCheck.Status = .unknown
        if let lock = Self.run("/usr/sbin/sysadminctl", ["-screenLock", "status"],
                               mergeStderr: true)?.lowercased() {
            if lock.contains("screenlock is off") { status = .warn }
            else if lock.contains("screenlock delay is") { status = .pass }
        }
        if status == .unknown {
            let out = Self.run("/usr/bin/defaults",
                               ["read", "com.apple.screensaver", "askForPassword"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if out == "1" { status = .pass }
            else if out == "0" { status = .warn }
        }
        return SecurityCheck(
            id: "screenlock", icon: "lock.display",
            titleKey: "sec.screenlock.title",
            detailKey: status == .pass ? "sec.screenlock.on" :
                       status == .warn ? "sec.screenlock.off" : "sec.screenlock.unknown",
            fixHintKey: status == .warn ? "sec.screenlock.fix" : nil,
            status: status,
            settingsURL: "x-apple.systempreferences:com.apple.preference.security?General"
        )
    }

    // MARK: - Subprocess helper

    /// Runs a tool and returns trimmed stdout, or nil on failure/non-zero exit.
    /// A watchdog terminates the process after `timeout` so a stuck tool can't
    /// hang the audit.
    /// `mergeStderr` folds stderr into the captured output — needed for tools
    /// like `sysadminctl`, which report their answer on stderr.
    private nonisolated static func run(_ launchPath: String,
                                        _ args: [String],
                                        timeout: TimeInterval = 6,
                                        mergeStderr: Bool = false) -> String? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = mergeStderr ? pipe : FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
        let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()
        guard task.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
