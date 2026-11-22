import Foundation

enum StorageClassification {
    struct Target: Sendable {
        let name: String
        let icon: String
        let url: URL
        var grouped = false
        var enumerationIssue: StorageAccessIssue? = nil
    }

    struct Measurement: Codable, Sendable {
        var bytes: [String: UInt64] = [:]
        var issues: [StorageAccessIssue] = []
        var timeLimited = false
        var probeFailed: Bool?

        var partial: Bool { !issues.isEmpty }
        var accessDenied: Bool { issues.contains { $0.reasonKey == "detail.accessDenied" } }
    }

    private static let homeFolders: [String: (String, String)] = [
        "Documents": ("Documents", "doc.text.fill"),
        "Downloads": ("Downloads", "arrow.down.circle.fill"),
        "Desktop": ("Desktop", "desktopcomputer"),
        "Movies": ("Movies", "film.fill"),
        "Music": ("Music", "music.note"),
        "Pictures": ("Pictures", "photo.fill")
    ]

    private static let libraryFolders: [String: (String, String)] = [
        "Caches": ("User Caches", "archivebox.fill"),
        "Logs": ("User Logs", "doc.text.magnifyingglass"),
        "Application Support": ("Application Support", "folder.fill"),
        "Mobile Documents": ("iCloud Drive", "icloud.fill"),
        "Developer": ("Developer", "hammer.fill"),
        "Containers": ("Containers", "shippingbox.fill"),
        "Group Containers": ("Containers", "shippingbox.fill"),
        "Mail": ("Mail and Messages", "envelope.fill"),
        "Messages": ("Mail and Messages", "envelope.fill")
    ]

    static let libraryCategoryNames = Set(libraryFolders.values.map { $0.0 } + [StorageCategory.otherLibrary.rawValue])

    static func fixedFolderPaths(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications")] +
            (Array(homeFolders.keys) + ["Applications", "Library/Caches", "Library/Logs"])
            .map { home.appendingPathComponent($0) }
    }

    /// Split the physical Data tree only at category boundaries. Its merged
    /// startup namespace also shows the System volume and can hide Data entries.
    static func targets(volume: URL, home: URL, readDirectory: (URL) throws -> [URL] = {
        try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
    }) -> [Target] {
        let volume = canonicalURL(volume)
        let root = volume.path
        let logicalHome = canonicalURL(home).path
        let homePath = root == "/" || logicalHome.hasPrefix(root + "/")
            ? logicalHome : root + logicalHome
        let library = homePath + "/Library"
        let branchPaths = [homePath, library] + ["Users", "private", "usr"].map { volume.appendingPathComponent($0).path }
        var disk = stat()
        guard stat(root, &disk) == 0 else { return [] }

        func visit(_ url: URL) -> [Target] {
            guard !Task.isCancelled else { return [] }
            let path = url.path
            let parent = url.deletingLastPathComponent().path
            let name = url.lastPathComponent
            var metadata = stat()
            let exists = lstat(path, &metadata) == 0
            let isDirectory = exists && metadata.st_mode & S_IFMT == S_IFDIR
            if exists && metadata.st_dev != disk.st_dev { return [] }
            var displayURL = url
            if root == StorageStartupVolume.dataPath, path.hasPrefix(root + "/") {
                // Prefer the familiar firmlink spelling only when it names the
                // exact same object. Data-only paths need the physical spelling.
                let logical = URL(fileURLWithPath: String(path.dropFirst(root.count)))
                var alias = stat()
                if exists && lstat(logical.path, &alias) == 0 &&
                    alias.st_dev == metadata.st_dev && alias.st_ino == metadata.st_ino {
                    displayURL = logical
                }
            }
            var enumerationIssue: StorageAccessIssue?
            if isDirectory && (path == root || branchPaths.contains(where: { $0 == path || $0.hasPrefix(path + "/") })) {
                do {
                    let children = try readDirectory(displayURL)
                    // Foundation can return a firmlink's logical child URL when
                    // enumerating its physical parent. Keep one namespace while
                    // finding the boundaries and use aliases only for measurement.
                    let prefix = path == "/" ? path : path + "/"
                    return children.map(\.lastPathComponent).sorted().flatMap {
                        visit(URL(fileURLWithPath: prefix + $0))
                    }
                } catch where path == library {
                    let posixCode = (error as? POSIXError)?.code
                    let denied = (error as? CocoaError)?.code == .fileReadNoPermission ||
                        posixCode == .EACCES || posixCode == .EPERM
                    enumerationIssue = StorageAccessIssue(path: displayURL.path,
                                                          reasonKey: denied ? "detail.accessDenied" : "detail.unavailable",
                                                          libraryEnumerationFailed: true)
                } catch {
                    // Keep the fallback target when the branch cannot be split.
                }
            }

            let category: (String, String)
            let grouped: Bool
            if name == "Applications" && (parent == root || parent == homePath) {
                category = ("Applications", "app.fill")
                grouped = true
            } else if parent == homePath, let folder = homeFolders[name] {
                category = folder
                grouped = !isDirectory
            } else if parent == library || path == library {
                category = libraryFolders[name] ?? ("Other Library", "books.vertical.fill")
                grouped = !isDirectory || ["Containers", "Mail and Messages", "Other Library"].contains(category.0)
            } else if parent == homePath || path == homePath {
                category = name.hasPrefix(".") ? ("Hidden folders", "eye.slash.fill") : ("Your folders", "folder.fill")
                grouped = true
            } else {
                category = ("System Data", "internaldrive.fill")
                grouped = true
            }
            return [Target(name: category.0, icon: category.1, url: displayURL, grouped: grouped,
                           enumerationIssue: enumerationIssue)]
        }
        return disjoint(visit(volume))
    }

    private static func canonicalURL(_ url: URL) -> URL {
        guard let path = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }

    static func disjoint(_ targets: [Target]) -> [Target] {
        var paths: Set<String> = []
        return targets.filter { target in
            let path = target.url.path
            guard path != "/", !paths.contains(path),
                  !paths.contains(where: { path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }) else { return false }
            paths.insert(path)
            return true
        }
    }

    static func measure(_ targets: [Target], volume: URL, timeout: TimeInterval = 600, background: Bool = false) async -> Measurement {
        var result = Measurement()
        var disk = stat()
        guard stat(volume.path, &disk) == 0 else {
            result.issues = targets.map { .init(path: $0.url.path, reasonKey: "detail.unavailable") }
            return result
        }

        var roots: [URL] = []
        for target in disjoint(targets) {
            let path = target.url.path
            var metadata = stat()
            if lstat(path, &metadata) != 0 {
                let code = errno
                if code == ENOENT { result.bytes[path] = 0 } else {
                    let reason = code == EACCES || code == EPERM ? "detail.accessDenied" : "detail.unavailable"
                    result.issues.append(.init(path: path, reasonKey: reason))
                }
            } else if metadata.st_dev != disk.st_dev {
                result.issues.append(.init(path: path, reasonKey: "detail.externalVolume"))
            } else if path.contains("\n") || path.contains("\r") {
                // du's line-oriented output cannot represent these roots unambiguously.
                result.issues.append(.init(path: path, reasonKey: "detail.unavailable"))
            } else {
                roots.append(target.url)
            }
        }
        guard !roots.isEmpty, !Task.isCancelled else { return result }

        // Keep one inode set across all categories. Do not follow symlinks or
        // descend into mount points from other volumes.
        let response = await DirectorySizeProbe.captureResponse(
            executable: URL(fileURLWithPath: background ? "/usr/sbin/taskpolicy" : "/usr/bin/du"),
            arguments: (background ? ["-b", "-g", "throttle", "/usr/bin/du"] : []) + ["-Pskx"] + roots.map(\.path),
            timeout: timeout,
            // A disk-wide traversal can encounter thousands of denied entries.
            environment: ["LC_ALL": "C"], diagnosticLimit: 1_048_576)
        let parsed = response.map { parse($0.data, roots: roots) } ?? [:]
        result.bytes.merge(parsed) { _, new in new }
        result.timeLimited = response?.timedOut == true
        result.probeFailed = response == nil || (response?.succeeded == false && parsed.isEmpty)
        // du prints a hard-linked root only once, under its first operand. A
        // clean exit with a root left out means its blocks are already counted.
        if response?.succeeded == true {
            for root in roots where parsed[root.path] == nil { result.bytes[root.path] = 0 }
        }

        var reportedRoots: Set<String> = []
        var unmatchedDiagnostic = false
        if let response {
            for line in String(decoding: response.diagnostics, as: UTF8.self).split(separator: "\n") {
                let diagnostic = line.dropFirst(4)
                guard line.hasPrefix("du: "), let separator = diagnostic.range(of: ": ", options: .backwards) else {
                    unmatchedDiagnostic = true
                    continue
                }
                let path = String(diagnostic[..<separator.lowerBound])
                let message = diagnostic[separator.upperBound...]
                guard let root = roots.first(where: { contains($0.path, path: path) }) else {
                    unmatchedDiagnostic = true
                    continue
                }
                let reason = message == "Permission denied" || message == "Operation not permitted"
                    ? "detail.accessDenied" : "detail.unavailable"
                let firstForRoot = reportedRoots.insert(root.path).inserted
                // Always keep evidence of a denial even when an earlier error
                // on the same root was of another kind.
                if firstForRoot || (reason == "detail.accessDenied" && !result.issues.contains {
                    $0.reasonKey == reason && contains(root.path, path: $0.path)
                }) {
                    result.issues.append(.init(path: path, reasonKey: reason))
                }
            }
            unmatchedDiagnostic = unmatchedDiagnostic || response.diagnosticsTruncated ||
                (!response.succeeded && !response.timedOut && response.diagnostics.isEmpty)
        }
        for root in roots where !reportedRoots.contains(root.path) && (result.bytes[root.path] == nil || unmatchedDiagnostic) {
            result.issues.append(.init(path: root.path, reasonKey: result.timeLimited ? "detail.timeBudget" : "detail.unavailable"))
        }
        return result
    }

    private static func contains(_ root: String, path: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
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

    static func breakdown(targets: [Target], measurement: Measurement, volumes: StorageAPFSVolumes? = nil,
                          total: UInt64, used: UInt64, hasFullDiskAccess: Bool = false) -> [StorageBreakdown] {
        let scopes = Dictionary(grouping: disjoint(targets), by: \.name)
        let folderRows = scopes.values.compactMap { targets -> StorageBreakdown? in
            guard let first = targets.first else { return nil }
            let members = targets.map { target in
                let path = target.url.path
                let size = measurement.bytes[path]
                var issues = measurement.issues.filter { contains(path, path: $0.path) }
                // A successful or cached size probe does not establish which categories are present.
                if let issue = target.enumerationIssue { issues.insert(issue, at: 0) }
                var metadata = stat()
                let isDirectory = lstat(path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFDIR
                return StorageItemDetail(url: target.url, size: size ?? 0, isDirectory: isDirectory,
                                         sizeKnown: size != nil, isPartial: size == nil || !issues.isEmpty,
                                         unavailableReason: issues.first { $0.path == path && $0.reasonKey == "detail.accessDenied" }?.reasonKey,
                                         accessIssues: issues)
            }
            let contents: StorageBreakdown.Contents = first.grouped || members.count > 1
                ? .group(members) : .folder(first.url.path)
            return StorageBreakdown(name: first.name, icon: first.icon, contents: contents,
                                    bytes: sum(members.map(\.size)), total: total,
                                    sizeKnown: members.contains(where: \.sizeKnown),
                                    isPartial: members.contains(where: \.isPartial), accessIssues: members.flatMap(\.accessIssues))
        }
        var rows = folderRows
        if let volumes {
            rows.append(StorageBreakdown(name: "macOS and Service Volumes", icon: "internaldrive.fill",
                                         contents: .volumes(volumes.members), bytes: sum(volumes.members.compactMap(\.bytes)),
                                         total: total, sizeKnown: !volumes.isPartial || volumes.members.contains { $0.bytes != nil },
                                         isPartial: volumes.isPartial))
        }

        let known = sum(rows.map(\.bytes))
        if known > used {
            // APFS clones can share extents that du attributes to both files.
            // Preserve the observed sizes and show the mismatch instead of scaling.
            for index in rows.indices { rows[index].reconciled = false }
        } else if known < used {
            let reason: StorageBreakdown.RemainderReason = measurement.accessDenied && !hasFullDiskAccess
                ? .protected : .unmeasured
            rows.append(StorageBreakdown(name: reason.rawValue, icon: "questionmark.folder.fill",
                                         contents: .remainder(reason), bytes: used - known, total: total,
                                         sizeKnown: true, isPartial: false, accessIssues: measurement.issues))
        }
        return rows.sorted { $0.bytes == $1.bytes ? $0.name < $1.name : $0.bytes > $1.bytes }
    }

    private static func sum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { sum, value in
            let (next, overflow) = sum.addingReportingOverflow(value)
            return overflow ? UInt64.max : next
        }
    }
}
