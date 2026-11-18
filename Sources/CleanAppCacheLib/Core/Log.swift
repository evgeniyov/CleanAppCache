import Foundation

/// Minimal append-only file logger. Writes to
/// `~/Library/Logs/CleanAppCache/app.log` off the calling thread, and also
/// prints to the console in debug builds. Replaces scattered `print()` calls so
/// diagnostics survive after the app quits.
///
/// Two rules this logger has to hold to, because of what the app does:
/// - **Redact.** Almost every message here interpolates a path, and the paths
///   this app handles are the contents of `~/.Trash` and `~/Downloads` — the
///   names of documents the user deliberately threw away. Home-relative paths
///   are enough to debug with and say much less.
/// - **Stay bounded.** An append-only file with no rotation is a growing,
///   permanent record of that.
public enum Log {
    /// `~/Library/Logs/CleanAppCache`. Internal because the Scanner keeps this
    /// folder out of the Logs category: it lives among the children of
    /// `~/Library/Logs` that the category offers for cleaning.
    ///
    /// Only a location: reading it creates nothing. `append` creates the folder
    /// on the first write, and again whenever it has gone missing.
    ///
    /// Under XCTest it is a scratch folder instead: the suite fails deletes on
    /// purpose ("refused permanent delete of /"), and those lines in the
    /// user's own log would read as real incidents.
    static let directory: URL? = AppPaths.logs

    private static let fileURL: URL? = directory?.appendingPathComponent("app.log")
    private static let rotatedURL: URL? = directory?.appendingPathComponent("app.log.1")

    /// Rotate at 1 MB, keeping one previous file. Two files bound the log at
    /// ~2 MB regardless of how long the app is used.
    private static let maxBytes = 1_048_576

    private static let queue = DispatchQueue(label: "com.cleanappcache.log")

    // Only ever touched inside `queue` (serial), so shared use is safe despite
    // ISO8601DateFormatter not being Sendable.
    nonisolated(unsafe) private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let homePath = FileManager.default.homeDirectoryForCurrentUser.path

    /// Replaces the user's home prefix with `~`. Call sites interpolate paths
    /// directly, so this runs over the whole message rather than per argument.
    static func redact(_ message: String) -> String {
        guard homePath.count > 1 else { return message }
        return message.replacingOccurrences(of: homePath, with: "~")
    }

    public static func info(_ message: String)  { write(message, level: "INFO") }
    public static func warn(_ message: String)  { write(message, level: "WARN") }
    public static func error(_ message: String) { write(message, level: "ERROR") }

    public static func write(_ message: String, level: String = "INFO") {
        let date = Date()
        let safe = redact(message)
        // Build the line and write it on the serial queue so the formatter and
        // file handle are never touched concurrently.
        queue.async {
            let line = "\(stamp.string(from: date)) [\(level)] \(safe)\n"
            let data = Data(line.utf8)
            #if DEBUG
            try? FileHandle.standardError.write(contentsOf: data)
            #endif
            guard let url = fileURL else { return }
            rotateIfNeeded(url)
            append(data, to: url)
        }
    }

    /// Deletes both the current and the rotated log. Wired to Settings so the
    /// record of what the user cleaned is theirs to erase.
    public static func clear() {
        queue.async {
            let fm = FileManager.default
            if let url = fileURL { try? fm.removeItem(at: url) }
            if let url = rotatedURL { try? fm.removeItem(at: url) }
        }
    }

    // MARK: - Private

    private static func rotateIfNeeded(_ url: URL) {
        let fm = FileManager.default
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size >= maxBytes, let rotated = rotatedURL else { return }
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: url, to: rotated)
    }

    /// Appends `data` to the file at `url`, creating the file (and its
    /// directory) when missing. Synchronous and not thread-safe: `write` calls
    /// it only on `queue`.
    ///
    /// The directory can disappear while the app runs (the user or another
    /// cleaner removes `~/Library/Logs/...`), and it does not exist before the
    /// first write. Neither opening nor creating a file works without its
    /// parent, so without the retry below every line would be dropped.
    static func append(_ data: Data, to url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            return
        }
        if create(url, with: data) { return }
        createDirectory(url.deletingLastPathComponent())
        create(url, with: data)
    }

    /// 0700: the folder holds a record of what the user deleted.
    private static func createDirectory(_ dir: URL) {
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    @discardableResult
    private static func create(_ url: URL, with data: Data) -> Bool {
        // 0600: the log names files the user deleted, so it should not be
        // readable by other accounts on the machine.
        FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
    }
}
