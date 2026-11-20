import Foundation

/// Something the Developer section deletes: a tool cache or a project artifact.
/// The two share one delete path, so the nesting guard covers both.
protocol DevCleanable: Sendable {
    var id: UUID { get }
    var url: URL { get }
    var size: UInt64 { get }
    var removalIdentity: RemovalIdentity? { get }
}

public struct DevJunkItem: Identifiable, Sendable, Equatable, DevCleanable {
    public let id = UUID()
    /// Stable id of the curated location. The name, the description and, for
    /// unsafe items, the loss sentence are localization keys built from it,
    /// because the manager is off the main actor and cannot localize.
    public let definitionID: String
    public let url: URL
    public let size: UInt64
    /// Safe = a pure cache/build artifact that regenerates automatically.
    /// Unsafe = deleting it loses something no tool puts back by itself: data,
    /// a download that needs the network, or a build that cannot be redone.
    /// Unsafe items are never preselected and never ticked by "Select all".
    public let safe: Bool
    public var cleanupUnavailableReasonKey: String? = nil
    var uvIdentity: RemovalIdentity? = nil
    var removalIdentity: RemovalIdentity?

    init(definitionID: String, url: URL, size: UInt64, safe: Bool) {
        self.definitionID = definitionID
        self.url = url
        self.size = size
        self.safe = safe
        removalIdentity = RemovalIdentity(at: url)
    }

    public var titleKey: String { Self.titleKey(definitionID) }
    public var detailKey: String { "dev.item.\(definitionID).detail" }
    /// What the delete destroys for good. Defined for unsafe items only.
    public var lossKey: String { "dev.item.\(definitionID).loss" }

    static func titleKey(_ definitionID: String) -> String { "dev.item.\(definitionID).title" }

    public var path: String { url.path }
    public var formattedSize: String {
        Fmt.bytes(Int64(size))
    }

    public static func == (lhs: DevJunkItem, rhs: DevJunkItem) -> Bool {
        lhs.url == rhs.url
    }
}

/// A per-project build artifact found on disk (node_modules, Rust target,
/// SwiftPM .build) with the project's last-touched date — surfaces "dead
/// projects" whose artifacts silently hold gigabytes.
public struct ProjectArtifact: Identifiable, Sendable, DevCleanable {
    public enum Kind: String, Sendable {
        case node       // node_modules
        case cargo      // Rust target/
        case swiftpm    // SwiftPM .build/
    }

    public let id = UUID()
    public let url: URL              // the artifact directory itself
    public let projectName: String   // parent folder name
    public let projectPath: String
    public let kind: Kind
    public let size: UInt64
    public let projectModified: Date?
    var removalIdentity: RemovalIdentity?

    init(url: URL, projectName: String, projectPath: String, kind: Kind,
         size: UInt64, projectModified: Date?) {
        self.url = url
        self.projectName = projectName
        self.projectPath = projectPath
        self.kind = kind
        self.size = size
        self.projectModified = projectModified
        removalIdentity = RemovalIdentity(at: url)
    }

    public var kindKey: String { "dev.kind.\(kind.rawValue)" }
    public var formattedSize: String {
        Fmt.bytes(Int64(size))
    }
}

public actor DevCleanManager {
    public static let shared = DevCleanManager()
    private let isInUse: @Sendable (URL) -> Bool
    private let uvIsInUse: @Sendable () -> Bool
    private let uvCleaner: UvCacheCleaner
    private(set) var uvFailureKey: String?
    private(set) var lastRemovalResult: DeletionService.Result?
    private var observedUvRoots: Set<URL> = []
    init(isInUse: @escaping @Sendable (URL) -> Bool = { AppActivityGuard.developerIsInUse($0) },
         uvIsInUse: @escaping @Sendable () -> Bool = { AppActivityGuard.uvIsInUse() },
         uvCleaner: UvCacheCleaner = UvCacheCleaner()) {
        self.isInUse = isInUse
        self.uvIsInUse = uvIsInUse
        self.uvCleaner = uvCleaner
    }

    struct Definition: Sendable {
        /// Stable key: `DevJunkItem.definitionID`, and the middle of the
        /// item's localization keys. Renaming one orphans its strings.
        let id: String
        let relativePath: String   // relative to the user's home directory
        let safe: Bool
    }

    /// Curated, well-known developer cache and build-artifact locations. Each
    /// is deleted permanently through `DeletionService`, except uv, which
    /// requires its own lock-aware cache-clean command.
    /// Safe ones regenerate on next use; unsafe ones do not come back by
    /// themselves and carry a loss sentence the confirmation quotes.
    ///
    /// No entry may lie inside another: both would be selected, the inner size
    /// would be counted twice and its delete would fail on a path already gone.
    /// `outermost(_:url:)` guards the delete path against that anyway.
    static let definitions: [Definition] = [
        .init(id: "derivedData", relativePath: "Library/Developer/Xcode/DerivedData", safe: true),
        .init(id: "archives", relativePath: "Library/Developer/Xcode/Archives", safe: false),
        .init(id: "iosDeviceSupport", relativePath: "Library/Developer/Xcode/iOS DeviceSupport", safe: true),
        .init(id: "watchosDeviceSupport", relativePath: "Library/Developer/Xcode/watchOS DeviceSupport", safe: true),
        // Includes the per-runtime dyld caches in its `dyld` subfolder.
        .init(id: "simulatorCaches", relativePath: "Library/Developer/CoreSimulator/Caches", safe: true),
        .init(id: "swiftpm", relativePath: "Library/Caches/org.swift.swiftpm", safe: true),
        .init(id: "cocoapods", relativePath: "Library/Caches/CocoaPods", safe: true),
        .init(id: "carthage", relativePath: "Library/Caches/org.carthage.CarthageKit", safe: true),
        .init(id: "npm", relativePath: ".npm", safe: true),
        .init(id: "yarn", relativePath: "Library/Caches/Yarn", safe: true),
        .init(id: "pip", relativePath: "Library/Caches/pip", safe: true),
        // The path is a discovery fallback; uv resolves environment and TOML
        // overrides. Symlink installations depend on this cache, so opt in.
        .init(id: "uv-cache", relativePath: ".cache/uv", safe: false),
        .init(id: "gradleCaches", relativePath: ".gradle/caches", safe: true),
        .init(id: "gradleWrappers", relativePath: ".gradle/wrapper/dists", safe: true),
        .init(id: "maven", relativePath: ".m2/repository", safe: false),
        .init(id: "pubCache", relativePath: ".pub-cache", safe: false),
        .init(id: "homebrew", relativePath: "Library/Caches/Homebrew", safe: true),
        .init(id: "goBuild", relativePath: "Library/Caches/go-build", safe: true),
        .init(id: "goModules", relativePath: "go/pkg/mod", safe: false),
        .init(id: "cargoRegistry", relativePath: ".cargo/registry/cache", safe: true),
        .init(id: "android", relativePath: ".android/cache", safe: true),
        .init(id: "sdkman", relativePath: ".sdkman/archives", safe: true),
        .init(id: "simulatorDevices", relativePath: "Library/Developer/CoreSimulator/Devices", safe: false),
        // Sparse VM disk images: `du` reports the real on-disk usage, not the
        // huge apparent size. Deleting destroys every container and machine.
        .init(id: "docker", relativePath: "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", safe: false),
        .init(id: "orbstack", relativePath: ".orbstack/data/data.img", safe: false)
    ]

    private static let maxConcurrent = 6

    /// `progress` receives the localization key of the name of the location
    /// being measured.
    public func scan(progress: (@Sendable (String) -> Void)? = nil) async -> [DevJunkItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        progress?(DevJunkItem.titleKey(UvCacheCleaner.definitionID))
        let uv = scanUvCache()
        let existing = Self.definitions.filter {
            let url = home.appendingPathComponent($0.relativePath)
            return $0.id != UvCacheCleaner.definitionID
                && FileManager.default.fileExists(atPath: url.path)
                && (uv.map { !Self.overlaps(url, $0.url) } ?? true)
        }

        var items: [DevJunkItem] = uv.map { [$0] } ?? []
        await withTaskGroup(of: DevJunkItem?.self) { group in
            var next = 0
            func addTask(_ def: Definition) {
                group.addTask {
                    progress?(DevJunkItem.titleKey(def.id))
                    let url = home.appendingPathComponent(def.relativePath)
                    guard let identity = RemovalIdentity(at: url) else { return nil }
                    let size = Scanner.shared.calculateSize(at: url)
                    guard size > 0, identity.matches(url) else { return nil }
                    var item = DevJunkItem(definitionID: def.id, url: url, size: size, safe: def.safe)
                    item.removalIdentity = identity
                    return item
                }
            }

            while next < min(Self.maxConcurrent, existing.count) {
                addTask(existing[next]); next += 1
            }
            while let result = await group.next() {
                if let item = result { items.append(item) }
                if next < existing.count { addTask(existing[next]); next += 1 }
            }
        }

        return items.sorted { $0.size > $1.size }
    }

    /// Refresh this row after cleaning: uv may retain its root/lock or another
    /// process may already have repopulated the cache after releasing the lock.
    func scanUvCache() -> DevJunkItem? {
        let location = uvCleaner.location()
        if location.reasonKey == nil { observedUvRoots.insert(location.url) }
        guard let size = Scanner.shared.calculateSizes(at: [location.url])[location.url.path], size > 0 else { return nil }
        var item = DevJunkItem(definitionID: UvCacheCleaner.definitionID, url: location.url, size: size, safe: false)
        item.uvIdentity = RemovalIdentity(at: location.url)
        item.cleanupUnavailableReasonKey = location.reasonKey
        if item.cleanupUnavailableReasonKey == nil && !UvCacheCleaner.validCache(location.url, identity: item.uvIdentity) {
            item.cleanupUnavailableReasonKey = "dev.uv.changed"
        }
        return item
    }

    private nonisolated static func overlaps(_ first: URL, _ second: URL) -> Bool {
        let a = first.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let b = second.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return a.starts(with: b) || b.starts(with: a)
    }

    // MARK: - Project artifacts (node_modules / target / .build across ~)

    public func scanProjects() async -> [ProjectArtifact] {
        await scanProjectsWithReport().artifacts
    }

    func scanProjectsWithReport(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                storage: StorageManager = .shared, timeLimit: TimeInterval = 60) async
        -> (artifacts: [ProjectArtifact], skipped: ScanSkipSummary) {
        let deadline = DispatchTime.now() + timeLimit
        let found = await Self.projectCandidates(home: home.path, deadline: deadline)
        let candidates = found.candidates
        var skipped = ScanSkipSummary()
        if let reason = found.skipReason { skipped.record(home, reason: reason) }
        guard !candidates.isEmpty, !Task.isCancelled else { return ([], skipped) }
        let identities = Dictionary(uniqueKeysWithValues: candidates.compactMap { candidate in
            RemovalIdentity(at: candidate.0).map { (candidate.0, $0) }
        })
        let generation = await storage.diskCache.generation
        let sizes = await DirectorySizeProbe.measureConcurrently(
            candidates.map(\.0).filter { identities[$0] != nil }, deadline: deadline, parallelism: 4
        ) { url, timeout in
            await storage.bulkDirectorySizes(urls: [url], timeout: timeout)[url.path]
        }
        let currentGeneration = await storage.diskCache.generation
        guard !Task.isCancelled else { return ([], skipped) }

        var artifacts: [ProjectArtifact] = []
        let missingSizeReason: ScanSkipReason = DispatchTime.now() >= deadline ? .verificationLimit : .unreadable
        for (url, kind) in candidates {
            guard let identity = identities[url], identity.matches(url) else {
                skipped.record(url, reason: .unreadable)
                continue
            }
            guard currentGeneration == generation, let size = sizes[url.path] else {
                skipped.record(url, reason: missingSizeReason)
                continue
            }
            guard size > 0 else { continue }
            let parent = url.deletingLastPathComponent()
            let modified = (try? parent.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            var artifact = ProjectArtifact(
                url: url,
                projectName: parent.lastPathComponent,
                projectPath: parent.path,
                kind: kind,
                size: size,
                projectModified: modified)
            artifact.removalIdentity = identity
            artifacts.append(artifact)
        }
        return (artifacts.sorted { $0.size > $1.size }, skipped)
    }

    /// Artifact directories under `home` with their project's marker file
    /// beside them — `package.json`, `Cargo.toml` or `Package.swift` — at most
    /// 300 of them.
    nonisolated static func projectCandidates(home: String, deadline: DispatchTime = .now() + 60) async
        -> (candidates: [(URL, ProjectArtifact.Kind)], skipReason: ScanSkipReason?) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline.uptimeNanoseconds else { return ([], .verificationLimit) }
        let timeout = min(45, Double(deadline.uptimeNanoseconds - now) / 1_000_000_000)
        guard let response = await DirectorySizeProbe.captureResponse(
            executable: URL(fileURLWithPath: "/usr/bin/find"),
            arguments: projectFindArguments(home: home), timeout: timeout
        ) else { return ([], .unreadable) }

        let fm = FileManager.default
        let reason: ScanSkipReason? = response.succeeded ? nil : (response.timedOut ? .verificationLimit : .unreadable)
        var candidates: [(URL, ProjectArtifact.Kind)] = []
        guard let end = response.data.lastIndex(of: 0) else { return ([], reason) }
        for raw in response.data[..<end].split(separator: 0) {
            guard !Task.isCancelled else { return ([], reason) }
            guard DispatchTime.now() < deadline else { return (candidates, .verificationLimit) }
            let url = URL(fileURLWithPath: String(decoding: raw, as: UTF8.self))
            guard Self.isOutsidePackage(url) else { continue }
            let parent = url.deletingLastPathComponent()
            let kind: ProjectArtifact.Kind
            switch url.lastPathComponent {
            case "node_modules":
                // Real project = package.json next to it.
                guard fm.fileExists(atPath: parent.appendingPathComponent("package.json").path) else { continue }
                kind = .node
            case "target":
                // Rust target dirs only (a folder named "target" is common noise).
                guard fm.fileExists(atPath: parent.appendingPathComponent("Cargo.toml").path) else { continue }
                kind = .cargo
            case ".build":
                guard fm.fileExists(atPath: parent.appendingPathComponent("Package.swift").path) else { continue }
                kind = .swiftpm
            default:
                continue
            }
            guard candidates.count < 300 else { return (candidates, .verificationLimit) }
            candidates.append((url, kind))
        }
        return (candidates, reason)
    }

    /// One `find` pass for all three artifact names under `home`.
    ///
    /// Pruned, so never descended into:
    ///   • every hidden folder at the top of the home (`~/.vscode`, `~/.cursor`,
    ///     `~/.npm`, `~/.nvm`, …). Editors and tool managers keep installed
    ///     extensions and toolchains there, each with a `package.json` beside
    ///     its `node_modules`. Deleting one breaks the installed tool, and no
    ///     build puts it back. Hidden folders deeper down (a project's
    ///     `.build`) are still searched.
    ///   • `~/Library` and `~/Applications`: app data and app bundles, which
    ///     ship their own `node_modules` and are not projects.
    ///   • `.Trash`, `.git` and application/code packages at any depth. An
    ///     Electron app can carry `package.json` beside its runtime modules,
    ///     including when the app lives in Downloads rather than Applications.
    /// A match is pruned too, so the copies nested inside a `node_modules` are
    /// not reported separately.
    nonisolated static func projectFindArguments(home: String) -> [String] {
        let home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        // `-path` takes a glob; the home path itself must match literally.
        let root = globEscaped(home)
        let packagePatterns = projectPackageExtensions.flatMap { ["-o", "-iname", "*." + $0] }
        return [
            home, "-maxdepth", "6",
            "(", "-path", root + "/.*",
            "-o", "-path", root + "/Library",
            "-o", "-path", root + "/Applications",
            "-o", "-name", ".Trash", "-o", "-name", ".git"
        ] + packagePatterns + [
            ")", "-prune",
            "-o", "-type", "d",
            "(", "-name", "node_modules", "-o", "-name", "target", "-o", "-name", ".build", ")",
            "-prune", "-print0"
        ]
    }

    /// These code-package suffixes remain protected even when Launch Services
    /// has not registered the package yet or its metadata cannot be read.
    private static let projectPackageExtensions = [
        "app", "appex", "bundle", "framework", "xcframework", "plugin", "xpc",
        "kext", "qlgenerator", "mdimporter", "saver", "prefpane", "systemextension"
    ]

    /// A manifest inside a package describes shipped runtime content, not a
    /// regenerable project. Check both spellings so a replaced parent symlink
    /// cannot redirect a previously scanned artifact into an application.
    private nonisolated static func isOutsidePackage(_ url: URL) -> Bool {
        let original = url.standardizedFileURL
        let resolved = original.resolvingSymlinksInPath()
        for path in Set([original, resolved]) {
            var ancestor = path.deletingLastPathComponent()
            while ancestor.path != "/" {
                if projectPackageExtensions.contains(ancestor.pathExtension.lowercased())
                    || (try? ancestor.resourceValues(forKeys: [.isPackageKey]).isPackage) == true {
                    return false
                }
                let parent = ancestor.deletingLastPathComponent()
                if parent.path == ancestor.path { break }
                ancestor = parent
            }
        }
        return true
    }

    /// Backslash-escapes the characters `fnmatch` treats as a pattern.
    nonisolated static func globEscaped(_ path: String) -> String {
        var escaped = ""
        for character in path {
            if "*?[]\\".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    // MARK: - Cleaning

    /// Permanently deletes project artifacts (they regenerate on next
    /// install/build). Returns (deleted ids, failed count, freed bytes).
    ///
    /// These paths come from `find $HOME -maxdepth 6`, i.e. arbitrary
    /// directories in the user's home, and the deletion is permanent.
    /// `DeletionService` puts `PathGuard` in front of it.
    public func cleanProjects(_ items: [ProjectArtifact]) async -> (cleaned: [UUID], failed: Int, freedBytes: UInt64) {
        await remove(items, isEligible: { Self.isOutsidePackage($0) })
    }

    /// Permanently deletes the given caches, freeing space immediately.
    ///
    /// Most of these live under ~/Library/Caches, a Storage breakdown scan
    /// target, so `remove` expires those sizes; without it the Storage tab
    /// keeps the pre-clean sizes for up to an hour.
    public func clean(items: [DevJunkItem]) async -> (cleaned: [UUID], failed: Int, freedBytes: UInt64) {
        uvFailureKey = nil
        let uvItems = items.filter { $0.definitionID == UvCacheCleaner.definitionID }
        var result = await remove(items.filter { $0.definitionID != UvCacheCleaner.definitionID })
        for item in Self.outermost(uvItems, url: { $0.url }) {
            let outcome = uvCleaner.clean(item, isInUse: { isInUse($0) || uvIsInUse() })
            if outcome.succeeded {
                result.cleaned.append(contentsOf: uvItems.filter { $0.url == item.url }.map(\.id))
                result.freedBytes += outcome.freedBytes
            } else {
                result.failed += 1
                uvFailureKey = outcome.reasonKey
            }
            // Even an interrupted command may have removed some entries.
            await StorageManager.shared.invalidate(deleted: [item.url])
        }
        return result
    }

    /// Deletes the outermost of `items` and accounts for the rest.
    ///
    /// An item inside another selected item is not deleted on its own: it
    /// goes with the outer one, whose measured size already includes it. It
    /// counts as cleaned, with no bytes of its own, once it is gone from disk.
    private func remove<Item: DevCleanable>(_ items: [Item], isEligible: @Sendable (URL) -> Bool = { _ in true }) async
        -> (cleaned: [UUID], failed: Int, freedBytes: UInt64) {
        let outermost = Self.outermost(items) { $0.url }
        // A configured uv cache can overlap another cache or project artifact.
        // Neither an ancestor nor a descendant may bypass uv's lock protocol.
        let location = uvCleaner.location()
        if location.reasonKey == nil { observedUvRoots.insert(location.url) }
        let roots = observedUvRoots.union([location.url])
        let configurationUncertain = location.reasonKey == "dev.uv.configuration"
        var excludedObstacles: [URL: RemovalObstacle] = [:]
        let targets = outermost.filter { item in
            if configurationUncertain || !isEligible(item.url)
                || item.removalIdentity?.matches(item.url) != true {
                excludedObstacles[item.url] = .changedSinceScan
                return false
            }
            if roots.contains(where: { Self.overlaps(item.url, $0) })
                || UvCacheCleaner.containsCacheOrUnverified(item.url) || isInUse(item.url) {
                excludedObstacles[item.url] = .inUse
                return false
            }
            return true
        }
        let targetIDs = Set(targets.map(\.id))
        let identities = Dictionary(uniqueKeysWithValues: targets.compactMap { item in
            item.removalIdentity.map { (item.url, $0) }
        })
        var validationObstacles: [URL: RemovalObstacle] = [:]
        let result = DeletionService.delete(targets.map(\.url), validation: { url in
            guard identities[url]?.matches(url) == true, isEligible(url) else {
                validationObstacles[url] = .changedSinceScan
                return false
            }
            return !isInUse(url) && !roots.contains(where: { Self.overlaps(url, $0) })
                && !UvCacheCleaner.containsCacheOrUnverified(url)
                && identities[url]?.matches(url) == true
        })
        let omitted = outermost.filter { !targetIDs.contains($0.id) }
        let excluded = omitted.filter { !RemovalCheck.isMissing($0.url) }.map(\.url)
        let alreadyGone = omitted.filter { RemovalCheck.isMissing($0.url) }.map(\.url)
        var obstacles = result.obstacles
        for url in result.failed {
            if identities[url]?.matches(url) != true { obstacles[url] = .changedSinceScan }
            else if let reason = validationObstacles[url] { obstacles[url] = reason }
        }
        for url in excluded { obstacles[url] = excludedObstacles[url] ?? .inUse }
        lastRemovalResult = DeletionService.Result(
            deleted: result.deleted, failed: result.failed + excluded, blocked: result.blocked,
            alreadyGone: result.alreadyGone + alreadyGone, obstacles: obstacles,
            escalation: result.escalation, freedBytes: result.freedBytes)
        let deletedPaths = Set((result.deleted + result.alreadyGone).map(\.path))

        var cleaned: [Item] = []
        let freed = result.freedBytes
        var failed = result.failed.count + result.blocked.count
        for item in items {
            if targetIDs.contains(item.id) {
                guard deletedPaths.contains(item.url.path) else { continue }
                cleaned.append(item)
            } else if !RemovalCheck.isMissing(item.url) {
                failed += 1
            } else {
                cleaned.append(item)
            }
        }
        await StorageManager.shared.invalidate(deleted: cleaned.map(\.url))
        return (cleaned.map(\.id), failed, freed)
    }

    /// `items` without every entry whose URL lies inside another entry's URL,
    /// and without repeats of a URL already kept. Compared on whole path
    /// components, so `/a/b` does not swallow `/a/bc`.
    ///
    /// Deleting the outer directory removes the inner one with it. Keeping
    /// both counts the inner size twice in every total, and the second delete
    /// fails on a path that is already gone, leaving its row on screen.
    nonisolated static func outermost<T>(_ items: [T], url: (T) -> URL) -> [T] {
        let components = items.map { url($0).standardizedFileURL.pathComponents }
        return items.indices.compactMap { index in
            let mine = components[index]
            let covered = components.indices.contains { other in
                guard other != index else { return false }
                let theirs = components[other]
                if theirs.count < mine.count { return mine.starts(with: theirs) }
                // Identical paths: the first one stands for all of them.
                return theirs == mine && other < index
            }
            return covered ? nil : items[index]
        }
    }
}
