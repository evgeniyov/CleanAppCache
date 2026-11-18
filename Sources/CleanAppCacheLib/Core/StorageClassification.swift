import Foundation

/// These are folder scopes, not file-type searches: an app or build inside
/// Documents belongs to Documents. The unassigned balance has no browse root.
enum StorageClassification {
    struct Target: Sendable {
        let name: String
        let icon: String
        let url: URL
    }

    struct Measurement: Sendable {
        var bytes: [String: UInt64] = [:]
        var partial = false
        var issues: [StorageAccessIssue] = []
    }

    static func targets(home: URL) -> [Target] {
        let folders = [
            ("User Apps", "app.badge.checkmark", "Applications"),
            ("Documents", "doc.text.fill", "Documents"),
            ("Downloads", "arrow.down.circle.fill", "Downloads"),
            ("Desktop", "desktopcomputer", "Desktop"),
            ("User Caches", "archivebox.fill", "Library/Caches"),
            ("User Logs", "doc.text.magnifyingglass", "Library/Logs"),
            ("Movies", "film.fill", "Movies"),
            ("Music", "music.note", "Music"),
            ("Pictures", "photo.fill", "Pictures")
        ]
        return [Target(name: "Applications", icon: "app.fill", url: URL(fileURLWithPath: "/Applications"))]
            + folders.map { Target(name: $0.0, icon: $0.1, url: home.appendingPathComponent($0.2)) }
    }

    static func disjoint(_ targets: [Target]) -> [Target] {
        var paths: [String] = []
        return targets.filter { target in
            let path = target.url.standardizedFileURL.path
            guard path != "/", !path.contains("\n"), !path.contains("\r"),
                  !paths.contains(where: { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }) else { return false }
            paths.append(path)
            return true
        }
    }

    static func measure(_ targets: [Target], volume: URL, timeout: TimeInterval = 45) async -> Measurement {
        var result = Measurement()
        var volumeMetadata = stat()
        guard stat(volume.path, &volumeMetadata) == 0 else { result.partial = true; return result }
        var roots: [URL] = []
        for target in disjoint(targets) {
            var metadata = stat()
            guard lstat(target.url.path, &metadata) == 0 else {
                if errno == ENOENT { result.bytes[target.url.path] = 0 }
                else {
                    result.partial = true
                    result.issues.append(.init(path: target.url.path, reasonKey: "detail.accessDenied"))
                }
                continue
            }
            // Never follow a category symlink onto another scope or volume.
            guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_dev == volumeMetadata.st_dev else {
                result.partial = true
                result.issues.append(.init(path: target.url.path, reasonKey: "detail.externalVolume"))
                continue
            }
            roots.append(target.url)
        }
        guard !roots.isEmpty, !Task.isCancelled else { return result }
        // One invocation attributes hard links to the first matching scope.
        // -x prevents descendants on external mounts joining the startup disk.
        guard let response = await DirectorySizeProbe.captureResponse(
            executable: URL(fileURLWithPath: "/usr/bin/du"),
            arguments: ["-skx"] + roots.map(\.path), timeout: timeout) else {
            result.partial = true
            return result
        }
        let parsed = parse(response.data, roots: roots)
        result.bytes.merge(parsed) { _, new in new }
        result.partial = result.partial || !response.succeeded || parsed.count != roots.count
        for root in roots where parsed[root.path] == nil {
            result.issues.append(.init(path: root.path, reasonKey: response.timedOut ? "detail.timeBudget" : "detail.unavailable"))
        }
        for line in String(decoding: response.diagnostics, as: UTF8.self).split(separator: "\n").prefix(32) {
            // du diagnostics identify descendants that could not be read. Do
            // not parse localized prose as a successful byte measurement.
            let text = String(line)
            if let root = roots.first(where: { text.contains($0.path) }) {
                let path = text.hasPrefix("du: ") ? String(text.dropFirst(4)).components(separatedBy: ": ").first ?? root.path : root.path
                let key = text.contains("Permission denied") || text.contains("Operation not permitted") ? "detail.accessDenied" : "detail.unavailable"
                result.issues.append(.init(path: path, reasonKey: key))
            }
        }
        return result
    }

    static func parse(_ data: Data, roots: [URL]) -> [String: UInt64] {
        let allowed = Set(roots.map(\.path))
        var sizes: [String: UInt64] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"), let kb = UInt64(line[..<tab]), kb <= UInt64.max / 1024 else { continue }
            let path = String(line[line.index(after: tab)...])
            if allowed.contains(path) { sizes[path] = kb * 1024 }
        }
        return sizes
    }

    static func breakdown(targets: [Target], measurement: Measurement, total: UInt64, used: UInt64) -> [StorageBreakdown] {
        let scopes = disjoint(targets)
        let known = scopes.reduce(UInt64(0)) { sum, target in
            let (value, overflow) = sum.addingReportingOverflow(measurement.bytes[target.url.path] ?? 0)
            return overflow ? UInt64.max : value
        }
        let reconciled = known <= used
        var rows = scopes.map { target in
            StorageBreakdown(name: target.name, icon: target.icon, bytes: measurement.bytes[target.url.path] ?? 0,
                             path: target.url.path, percentOfTotal: total > 0 ? Double(measurement.bytes[target.url.path] ?? 0) / Double(total) : 0,
                             sizeKnown: measurement.bytes[target.url.path] != nil, isPartial: measurement.partial,
                             reconciled: reconciled, accessIssues: measurement.issues.filter { $0.path == target.url.path || $0.path.hasPrefix(target.url.path + "/") })
        }
        rows.append(StorageBreakdown(name: "Other", icon: "questionmark.folder.fill", bytes: reconciled ? used - known : 0,
                                     path: "", percentOfTotal: total > 0 && reconciled ? Double(used - known) / Double(total) : 0,
                                     sizeKnown: reconciled, isPartial: measurement.partial, isResidual: true,
                                     reconciled: reconciled, accessIssues: measurement.issues))
        return rows.sorted { $0.bytes > $1.bytes }
    }
}
