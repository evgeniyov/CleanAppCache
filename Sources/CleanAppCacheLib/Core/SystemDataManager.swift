import Foundation
import os

// MARK: - System Data demystifier
//
// Finder shows "System Data" as one opaque number. This module breaks it into
// the components that actually make it up — APFS/Time Machine local snapshots,
// swap/VM files, system caches and logs, Spotlight index, purgeable space —
// and lets the user act on the one thing that's safely actionable without
// admin rights: local Time Machine snapshots (via `tmutil`).

/// Why `tmutil` refused, reduced to the shapes the UI can act on. On newer
/// macOS several tmutil verbs are gated behind Full Disk Access or root and
/// say so on stderr — a refusal must not be presented as "no snapshots" or as
/// a silent non-update.
public enum TMUtilFailure: Equatable, Sendable {
    /// stderr named Full Disk Access — the FDA banner is the fix.
    case needsFullDiskAccess
    /// Refused for rights reasons (root / "Not permitted").
    case notPermitted
    /// Anything else; carries trimmed stderr (may be empty) for the log.
    case failed(String)
}

/// One local Time Machine (APFS) snapshot.
public struct TMSnapshot: Identifiable, Sendable {
    /// Full snapshot name, e.g. "com.apple.TimeMachine.2026-07-18-123456.local".
    public let id: String
    /// The date token `tmutil deletelocalsnapshots` expects ("2026-07-18-123456").
    public let dateToken: String
    public let date: Date?
}

/// One slice of the hidden "System Data" figure.
public struct SystemDataComponent: Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case purgeable      // space macOS can free on demand (incl. snapshots)
        case snapshots      // local TM snapshots (listed separately)
        case swapVM         // /private/var/vm — swap files + sleepimage
        case systemCaches   // /Library/Caches + /private/var/folders
        case systemLogs     // /private/var/log + /Library/Logs
        case spotlight      // Spotlight index (needs Full Disk Access)
        case updates        // staged macOS updates

        public var icon: String {
            switch self {
            case .purgeable:    return "arrow.3.trianglepath"
            case .snapshots:    return "camera.on.rectangle"
            case .swapVM:       return "memorychip"
            case .systemCaches: return "internaldrive"
            case .systemLogs:   return "doc.text"
            case .spotlight:    return "magnifyingglass.circle"
            case .updates:      return "arrow.down.circle"
            }
        }

        public var titleKey: String { "sysdata.\(rawValue).title" }
        public var descKey: String  { "sysdata.\(rawValue).desc" }
    }

    public var id: String { kind.rawValue }
    public let kind: Kind
    /// nil = size can't be measured (e.g. snapshot sizes are hidden by APFS).
    public let bytes: UInt64?
    /// Optional item count (e.g. number of snapshots / swap files).
    public let count: Int?

    public var formattedSize: String? {
        bytes.map { Fmt.bytes(Int64($0)) }
    }
}

public actor SystemDataManager {
    public static let shared = SystemDataManager()

    /// Runs a tool. Tests replace it so no snapshot is listed or deleted on
    /// the machine that runs them.
    typealias Runner = @Sendable (_ launchPath: String, _ args: [String]) -> ProcResult?
    private let runner: Runner

    private init() { runner = { SystemDataManager.run($0, $1) } }

    init(runner: @escaping Runner) { self.runner = runner }

    // MARK: Scan

    public struct ScanOutcome: Sendable {
        public let components: [SystemDataComponent]
        /// nil = tmutil refused to answer — a different claim from "no
        /// snapshots", and the UI must not collapse the two.
        public let snapshots: [TMSnapshot]?
    }

    public func scan() async -> ScanOutcome {
        let snapshots = listSnapshots()

        var components: [SystemDataComponent] = []

        // Purgeable: the gap between "available for important usage" (what
        // Finder reports as free) and plain available capacity.
        if let purgeable = purgeableBytes() {
            components.append(SystemDataComponent(kind: .purgeable, bytes: purgeable, count: nil))
        }

        // Snapshot sizes are not exposed by APFS without root — report count,
        // size stays nil (the UI explains they're usually inside "purgeable").
        // When tmutil refused, the count is unknown too: nil, never 0.
        components.append(SystemDataComponent(kind: .snapshots, bytes: nil, count: snapshots?.count))

        // Swap + sleepimage: few large files — sum them directly.
        let vm = directSize(of: "/private/var/vm")
        components.append(SystemDataComponent(kind: .swapVM, bytes: vm.bytes, count: vm.count))

        // Bigger trees: measure via the shared batched-du path (cached, timed).
        let sized = await StorageManager.shared.bulkDirectorySizes(
            urls: [
                URL(fileURLWithPath: "/Library/Caches"),
                URL(fileURLWithPath: "/private/var/folders"),
                URL(fileURLWithPath: "/private/var/log"),
                URL(fileURLWithPath: "/Library/Logs"),
                URL(fileURLWithPath: "/System/Volumes/Data/.Spotlight-V100"),
                // /Library/Updates is vestigial on macOS 13+ — staged OS
                // updates live on the Update volume. Both are measured; du
                // degrades to whatever it can read.
                URL(fileURLWithPath: "/Library/Updates"),
                URL(fileURLWithPath: "/System/Volumes/Update")
            ],
            timeout: 45
        )
        func sum(_ paths: [String]) -> UInt64? {
            let total = paths.reduce(UInt64(0)) { $0 + (sized[$1] ?? 0) }
            return total > 0 ? total : nil
        }
        components.append(SystemDataComponent(
            kind: .systemCaches,
            bytes: sum(["/Library/Caches", "/private/var/folders"]), count: nil))
        components.append(SystemDataComponent(
            kind: .systemLogs,
            bytes: sum(["/private/var/log", "/Library/Logs"]), count: nil))
        components.append(SystemDataComponent(
            kind: .spotlight,
            bytes: sum(["/System/Volumes/Data/.Spotlight-V100"]), count: nil))
        components.append(SystemDataComponent(
            kind: .updates,
            bytes: sum(["/Library/Updates", "/System/Volumes/Update"]), count: nil))

        // Largest first; unknown sizes at their natural (enum) position end.
        let ordered = components.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        return ScanOutcome(components: ordered, snapshots: snapshots)
    }

    // MARK: Purgeable

    private func purgeableBytes() -> UInt64? {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]),
        let plain = v.volumeAvailableCapacity,
        let important = v.volumeAvailableCapacityForImportantUsage,
        important > Int64(plain)
        else { return nil }
        return UInt64(important - Int64(plain))
    }

    // MARK: Direct sizing (small dirs)

    private func directSize(of path: String) -> (bytes: UInt64?, count: Int?) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]
        ) else { return (nil, nil) }
        var total: UInt64 = 0
        var n = 0
        for url in contents {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
            let size = v?.totalFileAllocatedSize ?? v?.fileSize ?? 0
            if size > 0 { total += UInt64(size); n += 1 }
        }
        return (total > 0 ? total : nil, n > 0 ? n : nil)
    }

    // MARK: Snapshots (tmutil)

    /// nil = tmutil refused (non-zero exit, or it couldn't be launched);
    /// [] = it answered and there are none. The old `nil → []` collapse made
    /// every permissions refusal read as "0 snapshots" — a wrong claim.
    func listSnapshots() -> [TMSnapshot]? {
        guard let res = runner("/usr/bin/tmutil", ["listlocalsnapshots", "/"]) else { return nil }
        guard res.status == 0 else {
            Log.warn("tmutil listlocalsnapshots exit \(res.status): \(res.stderr)")
            return nil
        }
        let out = res.stdout
        let formatter = DateFormatter()
        // A fixed machine format: without the POSIX locale and the Gregorian
        // calendar a Buddhist or Japanese system calendar misreads the year.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.timeZone = .current

        var result: [TMSnapshot] = []
        for line in out.split(separator: "\n") {
            let name = line.trimmingCharacters(in: .whitespaces)
            // Expected: com.apple.TimeMachine.2026-07-18-123456.local
            guard name.hasPrefix("com.apple.TimeMachine.") else { continue }
            var token = String(name.dropFirst("com.apple.TimeMachine.".count))
            if token.hasSuffix(".local") { token = String(token.dropLast(".local".count)) }
            result.append(TMSnapshot(id: name, dateToken: token, date: formatter.date(from: token)))
        }
        return result.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Deletes one local snapshot. nil = success; otherwise why tmutil refused.
    public func deleteSnapshot(_ snapshot: TMSnapshot) -> TMUtilFailure? {
        guard let res = runner("/usr/bin/tmutil",
                               ["deletelocalsnapshots", snapshot.dateToken]) else {
            return .failed("")
        }
        guard res.status != 0 else { return nil }
        Log.warn("tmutil deletelocalsnapshots exit \(res.status) for \(snapshot.dateToken): \(res.stderr)")
        return Self.classify(res.stderr)
    }

    /// Asks Time Machine to thin local snapshots (reclaim up to ~everything,
    /// urgency 4). Documented to work without admin rights — but newer macOS
    /// still refuses on stderr in some configurations, hence the typed failure.
    /// nil = the command ran successfully.
    public func thinAllSnapshots() -> TMUtilFailure? {
        guard let res = runner("/usr/bin/tmutil",
                               ["thinlocalsnapshots", "/", "999999999999", "4"]) else {
            return .failed("")
        }
        guard res.status != 0 else { return nil }
        Log.warn("tmutil thinlocalsnapshots exit \(res.status): \(res.stderr)")
        return Self.classify(res.stderr)
    }

    /// Maps a tmutil stderr message onto the failure the UI can act on. The
    /// strings are the ones tmutil actually prints when a verb is gated behind
    /// Full Disk Access or root on 13+.
    nonisolated static func classify(_ stderr: String) -> TMUtilFailure {
        let lower = stderr.lowercased()
        if lower.contains("full disk access") { return .needsFullDiskAccess }
        if lower.contains("not permitted") || lower.contains("root") { return .notPermitted }
        return .failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Subprocess helper (timeout-guarded)

    struct ProcResult {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    /// nil only when the tool is missing or could not be launched. A non-zero
    /// exit comes back as a result — stderr is the caller's evidence for *why*
    /// tmutil refused, and discarding it (the old `nullDevice`) made a
    /// permissions refusal indistinguishable from an empty answer.
    private nonisolated static func run(_ launchPath: String,
                                        _ args: [String],
                                        timeout: TimeInterval = 30) -> ProcResult? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do { try task.run() } catch { return nil }

        let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // stderr is drained concurrently (readabilityHandler runs on its own
        // queue): reading both pipes to end from one thread deadlocks once
        // either fills its 64 KB buffer. The handler is @Sendable, so the
        // buffer sits behind a lock rather than a captured var.
        let errBuf = OSAllocatedUnfairLock(initialState: Data())
        let errDrained = DispatchSemaphore(value: 0)
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                errDrained.signal()
            } else {
                errBuf.withLock { $0.append(chunk) }
            }
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        errDrained.wait()
        watchdog.cancel()

        return ProcResult(stdout: String(decoding: outData, as: UTF8.self),
                          stderr: errBuf.withLock { String(decoding: $0, as: UTF8.self) },
                          status: task.terminationStatus)
    }
}
