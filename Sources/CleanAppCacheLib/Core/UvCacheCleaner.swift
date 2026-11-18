import Foundation
import Darwin

/// uv owns its cache format and locking protocol. Direct deletion, including
/// through DeletionService, races readers and can unlink the shared lock.
/// The only destructive primitive here is the documented `uv cache clean`,
/// without --force: https://docs.astral.sh/uv/concepts/cache/#cache-safety
struct UvCacheCleaner: Sendable {
    static let definitionID = "uv-cache"
    let home: URL
    let environment: [String: String]
    let executable: URL?
    let timeout: TimeInterval

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         executable: URL? = nil, discoverExecutable: Bool = true,
         timeout: TimeInterval = 30) {
        self.home = home
        self.environment = environment
        self.executable = executable ?? (discoverExecutable ? Self.findExecutable(home: home, environment: environment) : nil)
        self.timeout = timeout
    }

    struct Location: Sendable {
        let url: URL
        let reasonKey: String?
    }

    struct Outcome: Sendable {
        let succeeded: Bool
        let freedBytes: UInt64
        let reasonKey: String?
    }

    static func findExecutable(home: URL, environment: [String: String]) -> URL? {
        // Finder launches do not inherit the interactive shell's PATH.
        let candidates = [home.appendingPathComponent(".local/bin/uv").path,
                          "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
            + (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }
                .map { String($0) + "/uv" }
        return candidates.map { URL(fileURLWithPath: $0) }.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    /// Let uv parse TOML and its own environment precedence. The app has no
    /// project context; resolve from home, not the app's launch directory.
    func location() -> Location {
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            return Location(url: fallbackURL, reasonKey: "dev.uv.unavailable")
        }
        let result = run(executable, arguments: ["cache", "dir", "--offline", "--color", "never",
                                                "--directory", home.path], environment: discoveryEnvironment)
        guard result.succeeded else {
            return Location(url: fallbackURL, reasonKey: "dev.uv.configuration")
        }
        guard let path = Self.cachePath(from: result.output) else {
            return Location(url: fallbackURL, reasonKey: "dev.uv.configuration")
        }
        return Location(url: URL(fileURLWithPath: path).standardizedFileURL, reasonKey: nil)
    }

    static func cachePath(from output: String) -> String? {
        // Only the CLI's record terminator is removable; spaces and tabs are
        // legal filename characters, including at the end of a directory name.
        var bytes = Array(output.utf8)
        if bytes.last == 10 {
            bytes.removeLast()
            if bytes.last == 13 { bytes.removeLast() }
        }
        let path = String(decoding: bytes, as: UTF8.self)
        guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r"), !path.contains("\0") else { return nil }
        return path
    }

    private var fallbackURL: URL {
        if let path = environment["UV_CACHE_DIR"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        if let path = environment["XDG_CACHE_HOME"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path).appendingPathComponent("uv").standardizedFileURL
        }
        return home.appendingPathComponent(".cache/uv")
    }

    private var discoveryEnvironment: [String: String] {
        var result = environment
        // Discover the persistent cache even when an inherited invocation uses
        // a temporary cache; never create or clean a no-cache temporary tree.
        for key in ["UV_NO_CACHE", "UV_WORKING_DIR", "UV_PROJECT"] { result.removeValue(forKey: key) }
        return result
    }

    static func cleanArguments(for url: URL) -> [String] {
        ["cache", "clean", "--cache-dir", url.path, "--offline", "--no-config",
         "--no-progress", "--color", "never"]
    }

    var cleanEnvironment: [String: String] {
        // No inherited UV_* option may redirect or disable the selected cache.
        var result = environment.filter { !$0.key.hasPrefix("UV_") }
        result["UV_LOCK_TIMEOUT"] = "2"
        return result
    }

    /// A tag alone is not proof of ownership: also require the resolved
    /// configuration, a real directory and scan-time object/parent identities.
    static func validCache(_ url: URL, identity: RemovalIdentity?) -> Bool {
        guard let identity, identity.matches(url), identity.object.mode & S_IFMT == S_IFDIR,
              PathGuard.reject(url) == nil else { return false }
        // uv caches contain Git clones and a phony sdists-v*/.git marker.
        // Generic deletion refuses those markers. The uv-specific physical
        // walk permits this managed root and its Git metadata, keeps every
        // other protection, and treats descendant links as leaves.
        guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
              children.allSatisfy({ child in
                  let name = child.lastPathComponent
                  if ["CACHEDIR.TAG", ".lock", ".gitignore"].contains(name) { return true }
                  if name.range(of: "^\\.tmp[A-Za-z0-9]+$", options: .regularExpression) != nil { return true }
                  return name.range(of: "^(archive|binaries|builds|environments|flat-index|git|interpreter|python|simple|sdists|wheels)-v[0-9]+$",
                                    options: .regularExpression) != nil
              }) else { return false }
        let lock = url.appendingPathComponent(".lock")
        return FileSnapshot(at: lock)?.isRegularFile == true && hasCacheTag(url)
            && PathGuard.rejectUvCacheTree(url) == nil && identity.matches(url)
    }

    private static func hasCacheTag(_ root: URL) -> Bool {
        let tag = root.appendingPathComponent("CACHEDIR.TAG")
        guard FileSnapshot(at: tag)?.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: tag) else { return false }
        defer { try? handle.close() }
        let signature = Data("Signature: 8a477f597d28d172789f06886806bc55".utf8)
        return (try? handle.read(upToCount: signature.count)) == signature
    }

    /// Generic deletion cannot safely remove an unknown nested uv cache. The
    /// marker check remains active when uv is absent or its configuration moves.
    /// An incomplete walk is not permission to remove the unverified remainder.
    static func containsCacheOrUnverified(_ url: URL, limit: Int = 200_000) -> Bool {
        func cacheRoot(_ root: URL) -> Bool {
            hasCacheTag(root) && FileSnapshot(at: root.appendingPathComponent(".lock"))?.isRegularFile == true
        }
        var ancestor = url.standardizedFileURL.resolvingSymlinksInPath()
        while true {
            if cacheRoot(ancestor) { return true }
            // Foundation can append ".." when removing the last component of
            // a root URL derived from a child; equality alone does not terminate.
            if ancestor.path == "/" { break }
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { break }
            ancestor = parent
        }
        guard let snapshot = FileSnapshot(at: url) else { return !RemovalCheck.isMissing(url) }
        guard snapshot.mode & S_IFMT == S_IFDIR else { return false }
        let unreadable = CancellationFlag()
        guard let entries = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
            errorHandler: { _, _ in unreadable.cancel(); return false }) else { return true }
        var count = 0
        for case let child as URL in entries {
            count += 1
            if count > limit || unreadable.isCancelled { return true }
            if child.lastPathComponent == "CACHEDIR.TAG", cacheRoot(child.deletingLastPathComponent()) { return true }
        }
        return unreadable.isCancelled
    }

    func clean(_ item: DevJunkItem, isInUse: @Sendable (URL) -> Bool) -> Outcome {
        func refused(_ key: String) -> Outcome { Outcome(succeeded: false, freedBytes: 0, reasonKey: key) }
        let location = location()
        if let reason = location.reasonKey { return refused(reason) }
        guard let executable,
              location.url.standardizedFileURL.path == item.url.standardizedFileURL.path,
              Self.validCache(item.url, identity: item.uvIdentity) else { return refused("dev.uv.changed") }
        guard !isInUse(item.url) else { return refused("dev.uv.busy") }
        // Old uv versions without cache locks must not become a direct-delete fallback.
        let help = run(executable, arguments: ["cache", "clean", "--help"], environment: cleanEnvironment)
        guard help.succeeded, help.output.contains("--force"), help.output.contains("in-use"),
              ["--offline", "--no-config", "--cache-dir", "--no-progress"].allSatisfy(help.output.contains) else {
            return refused("dev.uv.unsupported")
        }
        guard let before = Scanner.shared.calculateSizes(at: [item.url])[item.url.path],
              let reclaimable = try? FileManager.default.allocatedSize(of: item.url, reclaiming: true),
              Self.validCache(item.url, identity: item.uvIdentity) else {
            return refused("dev.uv.changed")
        }
        guard !isInUse(item.url) else { return refused("dev.uv.busy") }
        let result = run(executable, arguments: Self.cleanArguments(for: item.url), environment: cleanEnvironment)
        // du measures allocated bytes and deduplicates hard links. Cap the
        // estimate by the existing service's reclaimable-size accounting to
        // exclude multiply linked files. APFS clone extents remain an estimate;
        // the UI must not promise an equivalent increase in disk free space.
        // A failed/partial command never receives a freed-space credit.
        let after = Scanner.shared.calculateSizes(at: [item.url])[item.url.path]
            ?? (RemovalCheck.isMissing(item.url) ? 0 : nil)
        guard result.succeeded, let after else {
            let diagnostic = result.diagnostic.lowercased()
            let busy = (result.timedOut && diagnostic.contains("cache is currently in-use"))
                || diagnostic.contains("waiting for lock")
                || diagnostic.contains("could not acquire lock")
            return refused(busy ? "dev.uv.busy" : "dev.uv.failed")
        }
        return Outcome(succeeded: true, freedBytes: min(before > after ? before - after : 0, reclaimable), reasonKey: nil)
    }

    private struct CommandResult {
        let succeeded: Bool
        let output: String
        let diagnostic: String
        let timedOut: Bool
    }

    /// Both pipes are drained independently; only a bounded prefix is retained.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func drain(_ handle: FileHandle) {
            while let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty {
                lock.lock()
                let remaining = max(0, 16_384 - bytes.count)
                bytes.append(contentsOf: chunk.prefix(remaining))
                lock.unlock()
            }
        }
        var string: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private func run(_ executable: URL, arguments: [String], environment: [String: String]) -> CommandResult {
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        task.environment = environment
        task.currentDirectoryURL = home
        task.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        task.standardOutput = pipe
        // Diagnostics can contain private paths/configuration. Retain only a
        // bounded prefix for classification; never log it or show raw output.
        let errors = Pipe()
        task.standardError = errors
        do { try task.run() } catch {
            return CommandResult(succeeded: false, output: "", diagnostic: "", timedOut: false)
        }
        let diagnostic = Output()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global().async {
            diagnostic.drain(errors.fileHandleForReading)
            readers.leave()
        }
        let expired = CancellationFlag()
        let watchdog = DispatchWorkItem {
            if task.isRunning {
                expired.cancel()
                // uv has no child process for cache operations. SIGKILL bounds
                // lock waits even when SIGTERM is intercepted by the runtime.
                kill(task.processIdentifier, SIGKILL)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let output = Output()
        output.drain(pipe.fileHandleForReading)
        task.waitUntilExit()
        watchdog.cancel()
        readers.wait()
        return CommandResult(succeeded: !expired.isCancelled && task.terminationStatus == 0,
                             output: output.string, diagnostic: diagnostic.string, timedOut: expired.isCancelled)
    }
}
