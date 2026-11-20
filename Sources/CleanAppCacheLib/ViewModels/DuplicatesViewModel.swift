import Foundation

@MainActor
public final class DuplicatesViewModel: ObservableObject {
    public enum Scope: String, Codable, CaseIterable, Identifiable {
        case home, downloads, documents, desktop
        public var id: String { rawValue }

        var url: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .home: return home
            case .downloads: return home.appendingPathComponent("Downloads")
            case .documents: return home.appendingPathComponent("Documents")
            case .desktop: return home.appendingPathComponent("Desktop")
            }
        }

        /// Label of the scope segment in the screen header. These are the
        /// keys the no-access state already prints, so the folder is named the
        /// same in the control that picked it and in the error about it.
        public var titleKey: String {
            switch self {
            case .home:      return "dscope.home"
            case .downloads: return "dscope.downloads"
            case .documents: return "dscope.documents"
            case .desktop:   return "dscope.desktop"
            }
        }
    }

    /// How big a file has to be before the scan bothers hashing it.
    ///
    /// Hashing is the expensive half of `DuplicateFinder`, so this is the one
    /// knob that decides whether a scan takes seconds or minutes — and a single
    /// hardcoded 5 MB makes a folder full of duplicated small photos read as "no duplicates".
    ///
    /// The ladder is stored in **decimal** bytes because `Fmt` is decimal (sizes
    /// are decimal, matching Finder). A MiB-based threshold printed through a
    /// decimal formatter turns a 100 MiB default into an odd "104.9 MB"; that
    /// trap is closed here by never storing a unit `Fmt` does not print.
    public enum MinSize: String, Codable, CaseIterable, Identifiable, Sendable {
        case mb1, mb5, mb50, mb500

        public var id: String { rawValue }

        public var bytes: UInt64 {
            switch self {
            case .mb1:   return 1_000_000
            case .mb5:   return 5_000_000
            case .mb50:  return 50_000_000
            case .mb500: return 500_000_000
            }
        }

        public var titleKey: String {
            switch self {
            case .mb1:   return "scan.min.1mb"
            case .mb5:   return "scan.min.5mb"
            case .mb50:  return "scan.min.50mb"
            case .mb500: return "scan.min.500mb"
            }
        }
    }

    public enum KeepRule { case newest, oldest }

    @Published public var scope: Scope = .downloads
    @Published private(set) var customSearchFolder: URL?

    var searchRoot: URL { customSearchFolder ?? scope.url }
    @Published public var minSize: MinSize = .mb5
    @Published public var isScanning = false
    @Published public var isDeleting = false
    @Published public var result: DuplicateScanResult?
    @Published public var groups: [DuplicateGroup] = []
    @Published public var selectedForDeletion: Set<UUID> = []
    @Published public var currentPath = ""

    private let finder = DuplicateFinder.shared
    private var scanGeneration = UUID()
    private var scanTask: Task<Void, Never>?
    /// Owned here, one per scan, cancelled synchronously — see the note on
    /// `DuplicateFinder.findDuplicates` for why this never goes through the actor.
    private var scanFlag: CancellationFlag?

    private let preflight: @Sendable (DuplicateFile) async -> Bool
    private let mover: (@Sendable (URL) throws -> URL)?
    private let history: CleanupHistory
    private let invalidateStorage: @Sendable ([URL]) async -> Void

    public convenience init() {
        self.init(preflight: { file in
            await Task.detached { DuplicateFinder.isUnchanged(file) }.value
        }, mover: nil, history: .shared)
    }

    init(preflight: @escaping @Sendable (DuplicateFile) async -> Bool,
         mover: (@Sendable (URL) throws -> URL)?, history: CleanupHistory,
         invalidateStorage: @escaping @Sendable ([URL]) async -> Void = {
             await StorageManager.shared.invalidate(deleted: $0)
         }) {
        self.preflight = preflight; self.mover = mover; self.history = history
        self.invalidateStorage = invalidateStorage
    }


    public var minSizeText: String {
        Fmt.bytes(minSize.bytes)
    }

    // MARK: - Scan parameters
    //
    // Scope and threshold are inputs, not filters over results: they decide what
    // the next scan looks at. Changing one therefore cannot leave the previous
    // scan's groups on screen — the header would then say "duplicates in
    // Documents from 50 MB" over a list produced by a different question. The
    // finding is dropped; no file is touched.

    public func setScope(_ new: Scope) {
        guard !isDeleting else { return }
        guard new != scope || customSearchFolder != nil else { return }
        scope = new
        customSearchFolder = nil
        invalidateResults()
    }

    func setCustomSearchFolder(_ url: URL) {
        guard !isDeleting, url.isFileURL else { return }
        customSearchFolder = url.standardizedFileURL.resolvingSymlinksInPath()
        invalidateResults()
    }

    public func setMinSize(_ new: MinSize) {
        guard !isDeleting else { return }
        guard new != minSize else { return }
        minSize = new
        invalidateResults()
    }

    /// Throws away everything the last scan produced, including an in-flight one.
    /// Nothing on disk changes — only the finding is discarded.
    public func invalidateResults() {
        guard !isDeleting else { return }
        cancelScan()
        result = nil
        groups = []
        selectedForDeletion = []
        currentPath = ""
    }

    public var selectedCount: Int { selectedForDeletion.count }

    public var selectedSize: UInt64 {
        var total: UInt64 = 0
        for group in groups {
            for file in group.files where selectedForDeletion.contains(file.id) {
                total += file.allocatedBytes
            }
        }
        return total
    }

    public var formattedSelectedSize: String {
        Fmt.bytes(Int64(selectedSize))
    }

    public func startScan() {
        guard !isDeleting else { return }
        guard !isScanning else { return }
        scanTask?.cancel()
        scanFlag?.cancel()   // a different object from the new scan's flag below
        scanGeneration = UUID()
        let generation = scanGeneration
        isScanning = true
        result = nil
        groups = []
        selectedForDeletion = []
        currentPath = ""

        let root = searchRoot
        let minBytes = minSize.bytes
        let flag = CancellationFlag()
        scanFlag = flag

        scanTask = Task { [weak self, finder] in
            let scan = await finder.findDuplicates(in: root, minSize: minBytes, flag: flag) { [weak self] path, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.scanGeneration == generation, self.isScanning else { return }
                    self.currentPath = path
                }
            }
            // A cancelled task must not touch `isScanning` either: the user may
            // already be running a replacement scan while this one's hashing
            // unwinds, and clearing the flag here would drop that scan's
            // progress UI and reopen the start guard (DashboardViewModel keeps
            // the same shape).
            guard !Task.isCancelled, let self else { return }
            self.result = scan
            self.groups = scan.groups
            self.autoSelect(keep: .newest)
            self.isScanning = false
        }
    }

    public func cancelScan() {
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        scanFlag?.cancel()
        scanFlag = nil
        isScanning = false
    }

    public func toggle(_ file: DuplicateFile) {
        guard !isDeleting else { return }
        if selectedForDeletion.contains(file.id) {
            selectedForDeletion.remove(file.id)
        } else {
            selectedForDeletion.insert(file.id)
        }
    }

    /// Selects every copy except the one to keep in each group.
    ///
    /// Copies produced by `cp -p`, `rsync -a` or an archive extraction share an
    /// mtime to the second. `sort` is not stable, so ordering by mtime alone
    /// made the choice of "the original" vary between runs — the file in
    /// `~/Documents` could be deleted and the one in `~/Downloads` kept. The
    /// tiebreak below is deterministic and prefers the shallower, then
    /// alphabetically earlier path, which in practice is the original.
    public func autoSelect(keep rule: KeepRule) {
        guard !isDeleting else { return }
        var selection: Set<UUID> = []
        for group in groups {
            for file in Self.ranked(group, keep: rule).dropFirst() { selection.insert(file.id) }
        }
        selectedForDeletion = selection
    }

    /// The copy `rule` keeps in `group` — what the row names before anything
    /// is deleted, from the same ordering `autoSelect` uses.
    public static func survivor(of group: DuplicateGroup, keep rule: KeepRule) -> DuplicateFile? {
        group.survivor(newestFirst: rule == .newest)
    }

    private static func ranked(_ group: DuplicateGroup, keep rule: KeepRule) -> [DuplicateFile] {
        group.files.sorted { $0.preferred(over: $1, newestFirst: rule == .newest) }
    }

    public func deleteSelected() async {
        guard !isDeleting, !isScanning, !selectedForDeletion.isEmpty else { return }
        isDeleting = true
        let selection = selectedForDeletion
        let previousGroups = groups
        let previousDuration = result?.duration ?? 0
        let previousGeneration = scanGeneration
        let previousScope = scope
        let previousThreshold = minSize

        // Collect the URLs to delete, refusing to empty a group and re-checking
        // each file against the scan snapshot. Hashing a large scope takes
        // minutes; a file edited or replaced in the meantime is no longer the
        // duplicate we verified and must not be deleted on the strength of a
        // stale hash.
        var urls: [URL] = []
        var skipped = 0
        var skippedGroups = 0
        var validationFiles: [URL: (copy: DuplicateFile, survivors: [DuplicateFile])] = [:]
        for group in previousGroups {
            var marked = group.files.filter { selection.contains($0.id) }
            guard !marked.isEmpty else { continue }
            if marked.count == group.files.count {
                // Every copy is selected — reachable by toggling each one by
                // hand. Keep one survivor rather than erasing the group.
                marked.removeFirst()
            }
            // The survivor gets the same re-check as the deletion candidates.
            // "One copy in each group is kept" is a promise about the disk, not
            // the snapshot: if the copy meant to stay was deleted or edited in
            // Finder after the scan, trashing the rest leaves zero intact
            // copies in place. Promoting a marked copy instead would keep a
            // file the user asked to delete — skip the whole group and say so.
            let markedIDs = Set(marked.map(\.id))
            let survivors = group.files.filter { !markedIDs.contains($0.id) }
            let hasSurvivor = await preflightSurvivor(survivors)
            guard hasSurvivor else {
                skippedGroups += 1
                continue
            }
            for file in marked {
                if await preflight(file) {
                    urls.append(file.url)
                    validationFiles[file.url] = (file, survivors)
                } else {
                    skipped += 1
                }
            }
        }

        guard !urls.isEmpty else {
            isDeleting = false
            if skipped > 0 {
                ToastCenter.shared.error(Localizer.shared.f("dup.staleSkippedFmt", Fmt.plural("plural.files", skipped)))
            }
            if skippedGroups > 0 {
                ToastCenter.shared.error(Localizer.shared.f("dup.staleGroupsSkippedFmt", Fmt.plural("plural.groups", skippedGroups)))
            }
            return
        }

        let toDelete = urls
        let validations = validationFiles
        // No Finder/password wait between verification and this move. A protected
        // duplicate stays for manual review rather than spending a stale hash.
        let mover = self.mover
        let res = await Task.detached(priority: .userInitiated) {
            let validation: (URL) -> Bool = { url in
                guard let entry = validations[url] else { return false }
                return entry.survivors.contains(where: DuplicateFinder.isUnchanged)
                    && DuplicateFinder.isUnchanged(entry.copy)
            }
            if let mover { return TrashService.trash(toDelete, validation: validation, mover: mover) }
            return TrashService.trash(toDelete, validation: validation)
        }.value
        let trashedPaths = Set(res.trashed.map { $0.original.path })
        await invalidateStorage(res.trashed.map(\.original))

        groups = groups.compactMap { group in
            let remaining = group.files.filter { !trashedPaths.contains($0.url.path) }
            guard remaining.count > 1 else { return nil }
            return DuplicateGroup(size: group.size, files: remaining)
        }
        selectedForDeletion.removeAll()
        result = DuplicateScanResult(groups: groups, duration: previousDuration)
        isDeleting = false

        let record = history.log(.duplicates, items: res.count, trashedBytes: res.freedBytes)
        let history = self.history
        TrashService.presentToast(res) { [weak self] in
            let restored = TrashService.restoreItems(res.trashed, recordingUndoOf: record, history: history)
            TrashService.presentRestore(restored.count)
            guard !restored.isEmpty, let self, self.scope == previousScope, self.minSize == previousThreshold,
                  self.scanGeneration == previousGeneration, !self.isScanning, !self.isDeleting else { return }
            self.isDeleting = true
            let restoredPaths = Set(restored.map { $0.original.path })
            Task {
                let restoredGroups = await Task.detached(priority: .userInitiated) {
                    previousGroups.compactMap { group -> DuplicateGroup? in
                        let files = group.files.compactMap { file -> DuplicateFile? in
                            let path = file.url.path
                            if restoredPaths.contains(path) { return file.refreshedAfterRestore() }
                            guard !trashedPaths.contains(path), !RemovalCheck.isMissing(file.url) else { return nil }
                            return file
                        }
                        return files.count > 1 ? DuplicateGroup(size: group.size, files: files) : nil
                    }
                }.value
                self.groups = restoredGroups
                self.result = DuplicateScanResult(groups: restoredGroups, duration: previousDuration)
                self.isDeleting = false
            }
        }
        if skipped > 0 {
            ToastCenter.shared.error(Localizer.shared.f("dup.staleSkippedFmt", Fmt.plural("plural.files", skipped)))
        }
        if skippedGroups > 0 {
            ToastCenter.shared.error(Localizer.shared.f("dup.staleGroupsSkippedFmt", Fmt.plural("plural.groups", skippedGroups)))
        }
    }

    private func preflightSurvivor(_ files: [DuplicateFile]) async -> Bool {
        for file in files { if await preflight(file) { return true } }
        return false
    }
}
