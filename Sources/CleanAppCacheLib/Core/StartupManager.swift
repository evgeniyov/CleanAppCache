import Foundation

// MARK: - Startup item model

public struct StartupItem: Identifiable, Sendable {
    public enum Scope: String, Sendable {
        case loginItem      // "Open at Login" app — managed via System Events
        case userAgent      // ~/Library/LaunchAgents  — user can toggle freely
        case globalAgent    // /Library/LaunchAgents    — off per user, no admin
        case daemon         // /Library/LaunchDaemons   — needs admin
    }

    /// Stable ID based on the plist path so items can be replaced in-place.
    public var id: String { plistURL.path }
    public let label: String          // launchd label or file name
    public let program: String        // executable path / first program argument
    public let plistURL: URL
    public let scope: Scope
    public let runAtLoad: Bool
    /// Whether launchd will actually start this item — the *effective* state,
    /// which is launchd's override database when it has an entry for the label
    /// and the plist's `Disabled` key otherwise. See `StartupManager.overrides`.
    public let isEnabled: Bool

    /// Only a daemon needs an administrator to turn off: it runs in the
    /// system domain. A global agent runs in each user's own GUI domain, and
    /// launchd lets a user switch a job off there for themselves.
    public var needsAdmin: Bool { scope == .daemon }

    /// A friendlier name: the owning .app's name if the program lives inside an
    /// app bundle, otherwise the last meaningful component of the label.
    public var displayName: String {
        if let range = program.range(of: ".app/") {
            let appPath = String(program[..<range.lowerBound]) + ".app"
            return (appPath as NSString).lastPathComponent
                .replacingOccurrences(of: ".app", with: "")
        }
        // "com.google.keystone.agent" → "keystone"
        let parts = label.split(separator: ".")
        if parts.count >= 2 { return parts.dropLast().last.map(String.init) ?? label }
        return label
    }
}

// MARK: - Startup manager

public actor StartupManager {
    public static let shared = StartupManager()
    private init() {}

    /// True when the last scan couldn't read login items because macOS Automation
    /// permission (System Events) was denied — the UI shows a hint to fix it.
    public private(set) var loginItemsDenied = false

    /// On-disk size of the program each entry launches, keyed by `StartupItem.id`
    /// — the one launch-related quantity this app can actually measure. Filled by
    /// `scan()`, read by `StartupView`.
    ///
    /// The natural per-item figure for the startup table would be a launch cost
    /// in **seconds**. macOS does not report one, and nothing here may invent it:
    ///
    ///   • `launchctl print gui/<uid>/<label>` carries `runs`, `pid`, `last exit
    ///     code`, jetsam limits — and no start duration. The only timing in that
    ///     output, `bringup time`, belongs to the *domain*, not to a job.
    ///   • launchd's unified log records `ran for <n>ms` when a service *exits* —
    ///     total lifetime, not launch cost. Those are debug records, evicted
    ///     within the hour, and `log show` costs seconds per call, so they could
    ///     not feed a table even if they said the right thing.
    ///   • A process's start time minus login time measures launchd's scheduling
    ///     queue, not what the item costs.
    ///
    /// Keying by `id` (the plist / app path) rather than by array index keeps the
    /// map valid after the view model rebuilds an item on toggle.
    public private(set) var programBytes: [String: UInt64] = [:]

    /// A program's size changes only when its app is updated, so each path is
    /// walked once per app run. Without this a rescan would re-enumerate every
    /// login item's `.app` bundle again.
    private var programSizeCache: [String: UInt64] = [:]

    // MARK: Scan

    public func scan() async -> [StartupItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sources: [(URL, StartupItem.Scope)] = [
            (home.appendingPathComponent("Library/LaunchAgents"), .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents"),       .globalAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"),      .daemon)
        ]

        // Effective enable/disable state, read once per scan.
        let gui = Self.readOverrides(domain: "gui/\(getuid())")
        let system = Self.readOverrides(domain: "system")

        var items: [StartupItem] = []
        let fm = FileManager.default
        for (dir, scope) in sources {
            guard let contents = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { continue }
            let overrides = scope == .daemon ? system : gui
            for url in contents where url.pathExtension == "plist" {
                if let item = parse(url: url, scope: scope, overrides: overrides) {
                    items.append(item)
                }
            }
        }

        // "Open at Login" apps (Shottr, Bitrix, …) aren't launchd plists — they
        // live in the login-items / Background Task Management list. Read them via
        // System Events so the section is actually complete.
        let login = await Self.fetchLoginItems()
        loginItemsDenied = login.denied
        items.append(contentsOf: login.items)

        items.sort {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }

        // Measured on the scan, never on the sampling path: a login item's program
        // is an `.app` bundle, and walking one is far too slow for a 2 s timer.
        // Here the UI is already showing its scanning state.
        var sizes: [String: UInt64] = [:]
        for item in items {
            let size = programSize(item.program)
            if size > 0 { sizes[item.id] = size }   // 0 → absent → the table shows "—"
        }
        programBytes = sizes

        return items
    }

    /// On-disk allocated size of the program an entry launches: the executable
    /// itself for a launchd job, the whole `.app` for a login item — that is, of
    /// exactly the path the row displays, so the figure is checkable in Finder.
    /// 0 when the program is gone, which the table renders as "—" rather than as
    /// an invented number: a missing measurement never displays as a figure.
    private func programSize(_ path: String) -> UInt64 {
        // Only absolute paths are measurable; a bare command name would silently
        // resolve to nothing, and guessing a location would be a fabrication.
        guard path.hasPrefix("/") else { return 0 }
        if let cached = programSizeCache[path] { return cached }
        let size = (try? FileManager.default.allocatedSize(of: URL(fileURLWithPath: path))) ?? 0
        programSizeCache[path] = size
        return size
    }

    // MARK: Login items (System Events)

    /// Enumerates the user's login items through System Events. Returns
    /// `denied` when the Automation permission was refused, so the UI can
    /// guide the user instead of silently showing nothing.
    ///
    /// Runs in an `osascript` child off the main thread: the first request
    /// raises the Automation consent prompt, and System Events can take
    /// seconds to launch, which in-process `NSAppleScript` on the main actor
    /// spent with the window frozen.
    static func fetchLoginItems() async -> (items: [StartupItem], denied: Bool) {
        let source = """
        on run argv
            tell application "System Events"
                set output to ""
                repeat with li in login items
                    set n to ""
                    set p to ""
                    try
                        set n to name of li
                    end try
                    try
                        set p to (path of li) as text
                    end try
                    set output to output & n & tab & p & linefeed
                end repeat
                return output
            end tell
        end run
        """
        let output = await Task.detached(priority: .userInitiated) {
            AppleScriptRunner.run(source, arguments: [], timeout: AppleScriptRunner.interactiveTimeout)
        }.value
        guard output.succeeded else {
            // -1743: Automation control of System Events is not allowed.
            let denied = output.automationDenied || output.errorNumber == -600
            if !denied { Log.warn("Login items AppleScript failed: \(output.stderr)") }
            return ([], denied)
        }
        return (parseLoginItems(output.stdout), false)
    }

    /// One `name<TAB>path` line per login item, as the script above prints them.
    static func parseLoginItems(_ text: String) -> [StartupItem] {
        var items: [StartupItem] = []
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let parts = line.components(separatedBy: "\t")
            guard let name = parts.first else { continue }
            let path = parts.count > 1 ? parts[1] : ""
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            if trimmedName.isEmpty && path.isEmpty { continue }
            let appURL = URL(fileURLWithPath: path.isEmpty ? "/" : path)
            let label = trimmedName.isEmpty ? appURL.lastPathComponent : trimmedName
            items.append(StartupItem(
                label: label,
                program: path,
                plistURL: appURL,          // used for reveal + a stable id
                scope: .loginItem,
                runAtLoad: true,
                isEnabled: true))
        }
        return items
    }

    /// Removes a login item by its System Events name. Returns true on success.
    /// The name travels as `argv`, so no quoting can turn it into script code.
    static func removeLoginItem(named name: String) async -> Bool {
        let source = """
        on run argv
            tell application "System Events" to delete (every login item whose name is (item 1 of argv))
        end run
        """
        return await Task.detached(priority: .userInitiated) {
            AppleScriptRunner.run(source, arguments: [name], timeout: AppleScriptRunner.interactiveTimeout)
        }.value.succeeded
    }

    public func removeLoginItem(_ item: StartupItem) async -> Bool {
        await Self.removeLoginItem(named: item.label)
    }

    // MARK: Enable / Disable

    /// Turns an agent on or off for this user without changing any file.
    /// - launchd's per-user override is written, which decides the next login.
    /// - The job is booted in or out of the running session.
    /// - Returns `true` on success, `false` if anything fails.
    ///
    /// The agent's plist belongs to whoever installed it and stays byte for
    /// byte as it was: its `Disabled` key is only the initial value, which the
    /// override replaces, and rewriting a vendor's file (a binary plist turned
    /// into XML, a new inode) is a change on disk the Startup screen promises
    /// not to make.
    @discardableResult
    public func setEnabled(_ enabled: Bool, for item: StartupItem) async -> Bool {
        setEnabled(enabled, for: item, launchctl: { Self.runLaunchctl($0) })
    }

    /// `launchctl` replaces the real tool so tests never write the user's
    /// launchd override database.
    @discardableResult
    func setEnabled(_ enabled: Bool, for item: StartupItem,
                    launchctl: ([String]) -> String?) -> Bool {
        guard item.scope == .userAgent || item.scope == .globalAgent else { return false }
        // `bootstrap` loads the job from this plist. One that cannot be read
        // does not describe a job launchd can load, so nothing is changed.
        guard let data = try? Data(contentsOf: item.plistURL),
              (try? PropertyListSerialization.propertyList(from: data, format: nil)) is [String: Any]
        else { return false }

        let domain = "gui/\(getuid())"

        // 1. Write launchd's override for the label. This is what decides
        //    whether the agent starts at login; an existing override (System
        //    Settings writes them) would otherwise win while the row showed the
        //    opposite state, so its failure fails the whole call.
        //    `launchctl enable/disable` exits 0 even for unloaded labels, so
        //    the guard adds no false failures; nil means spawn failure,
        //    non-zero exit, or the watchdog killing a wedged launchd.
        guard launchctl([enabled ? "enable" : "disable",
                         "\(domain)/\(item.label)"]) != nil
        else { return false }

        // 2. Apply to the running session. `load`/`unload` are deprecated on
        //    modern macOS; `bootstrap`/`bootout` into the per-user GUI domain are
        //    the supported equivalents. Failure is non-fatal — step 1
        //    already persists the change across reboots.
        _ = launchctl(enabled
            ? ["bootstrap", domain, item.plistURL.path]
            : ["bootout",   domain, item.plistURL.path])

        return true
    }

    /// Turns daemons off in the system domain as root, after one
    /// administrator password for the whole batch, with `prompt` as the
    /// dialog's explanation. Returns the labels launchd now reports disabled.
    ///
    /// Only labels made of reverse-DNS characters reach the shell, each
    /// quoted; `bootout` stops a running daemon now, `disable` keeps it from
    /// starting again.
    public func disableDaemons(_ items: [StartupItem], prompt: String) async
        -> (disabled: Set<String>, outcome: EscalationOutcome) {
        let labels = items.filter { $0.scope == .daemon }.map(\.label).filter(Self.isSafeLabel)
        guard !labels.isEmpty else { return ([], .failed) }
        let command = labels.map { label in
            let target = AppleScriptRunner.shellQuoted("system/" + label)
            return "/bin/launchctl disable \(target); /bin/launchctl bootout \(target) 2>/dev/null"
        }.joined(separator: "; ") + "; true"
        let output = await Task.detached(priority: .userInitiated) {
            AppleScriptRunner.runPrivileged(command, prompt: prompt)
        }.value
        let outcome: EscalationOutcome = output.succeeded ? .completed
            : output.userCancelled ? .cancelled : .failed
        if outcome == .failed { Log.error("Disabling daemons failed: \(output.stderr)") }
        let overrides = Self.readOverrides(domain: "system")
        return (Set(labels.filter { overrides[$0] == false }), outcome)
    }

    static func isSafeLabel(_ label: String) -> Bool {
        !label.isEmpty && label.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0)
        }
    }

    // MARK: Parse

    func parse(url: URL, scope: StartupItem.Scope,
               overrides: [String: Bool] = [:]) -> StartupItem? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any]
        else {
            // Unreadable plist — surface it by file name, mark as enabled.
            return StartupItem(
                label: url.deletingPathExtension().lastPathComponent,
                program: url.path, plistURL: url, scope: scope,
                runAtLoad: false, isEnabled: true)
        }

        let label     = (plist["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
        var program   = (plist["Program"] as? String) ?? ""
        if program.isEmpty,
           let args = plist["ProgramArguments"] as? [String],
           let first = args.first { program = first }
        let runAtLoad = (plist["RunAtLoad"] as? Bool) ?? false

        // The plist's `Disabled` key is only the *initial* value. Once a label
        // appears in launchd's override database — which is what `launchctl
        // enable/disable` and the Login Items toggle in System Settings write —
        // the override decides, and the plist key is ignored.
        //
        // Trusting the plist alone reports the opposite of the truth on a real
        // machine: `homebrew.mxcl.mysql` ships `Disabled = true` in its plist and
        // would be listed as "off" while `launchctl print` shows it running at
        // login, because the override says enabled.
        let isEnabled = overrides[label] ?? ((plist["Disabled"] as? Bool) != true)

        return StartupItem(
            label: label,
            program: program.isEmpty ? url.path : program,
            plistURL: url, scope: scope,
            runAtLoad: runAtLoad, isEnabled: isEnabled)
    }

    // MARK: launchd override database

    /// Effective enabled state per label from `launchctl print-disabled <domain>`.
    ///
    /// Output looks like:
    /// ```
    /// disabled services = {
    ///     "com.example.agent" => disabled
    ///     "homebrew.mxcl.mysql" => enabled
    /// }
    /// ```
    /// Labels absent from the result have no override and fall back to the plist.
    /// Older macOS prints `=> true/false` instead; both spellings are accepted.
    static func readOverrides(domain: String) -> [String: Bool] {
        guard let out = runLaunchctl(["print-disabled", domain]) else { return [:] }
        var result: [String: Bool] = [:]
        for line in out.split(separator: "\n") {
            guard let arrow = line.range(of: "=>") else { continue }
            let rawLabel = line[..<arrow.lowerBound]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = line[arrow.upperBound...]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard !rawLabel.isEmpty else { continue }
            if value.hasPrefix("disabled") || value.hasPrefix("true") {
                result[rawLabel] = false
            } else if value.hasPrefix("enabled") || value.hasPrefix("false") {
                result[rawLabel] = true
            }
        }
        return result
    }

    /// Runs `launchctl` and returns stdout, or nil on failure. A watchdog keeps a
    /// wedged launchd from hanging the scan.
    @discardableResult
    static func runLaunchctl(_ args: [String], timeout: TimeInterval = 5) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()
        guard task.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
