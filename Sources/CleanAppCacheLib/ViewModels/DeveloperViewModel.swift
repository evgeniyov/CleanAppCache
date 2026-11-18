import Foundation

@MainActor
public final class DeveloperViewModel: ObservableObject {
    @Published public var items: [DevJunkItem] = []
    @Published public var selected: Set<UUID> = []
    @Published public var isLoading = false
    @Published public var isCleaning = false
    @Published public var currentScan = ""
    /// Whether the user has run a scan yet (drives the idle vs. empty state).
    @Published public var hasScanned = false

    private let manager: DevCleanManager

    public init() { manager = DevCleanManager.shared }

    /// Tests pass a manager whose activity checks do not depend on the
    /// processes running on the machine.
    init(manager: DevCleanManager) { self.manager = manager }

    public var selectedCount: Int { selected.count }

    public var totalSize: UInt64 { items.reduce(0) { $0 + $1.size } }
    public var formattedTotalSize: String {
        Fmt.bytes(Int64(totalSize))
    }

    /// A selected cache inside another selected one is not counted again.
    public var selectedSize: UInt64 {
        DevCleanManager.outermost(items.filter { selected.contains($0.id) }) { $0.url }
            .reduce(0) { $0 + $1.size }
    }
    public var formattedSelectedSize: String {
        Fmt.bytes(Int64(selectedSize))
    }

    /// Starts a scan (used by the Scan / Rescan button).
    public func scan() { load() }

    public func reload() { load() }

    private func load() {
        guard !isCleaning else { return }
        guard !isLoading else { return }
        isLoading = true
        hasScanned = true
        items = []
        selected = []
        currentScan = ""

        Task { [weak self, manager] in
            let found = await manager.scan { [weak self] titleKey in
                Task { @MainActor [weak self] in
                    self?.currentScan = Localizer.shared.s(titleKey)
                }
            }
            guard let self else { return }
            self.items = found
            self.selectSafe()
            self.isLoading = false
        }
    }

    public func toggle(_ item: DevJunkItem) {
        if selected.contains(item.id) { selected.remove(item.id) }
        else { selected.insert(item.id) }
    }

    /// The default selection: safe caches only. Unsafe ones cost data or a
    /// rebuild that cannot be redone, so only an explicit tick selects them.
    public func selectSafe() {
        selected = Set(items.filter { $0.safe }.map(\.id))
    }

    public func deselectAll() { selected.removeAll() }

    public func clean() async {
        guard !isCleaning, !isLoading, !isScanningProjects else { return }
        let toClean = items.filter { selected.contains($0.id) }
        guard !toClean.isEmpty else { return }
        isCleaning = true
        let (cleaned, failed, freed) = await manager.clean(items: toClean)
        let cleanedSet = Set(cleaned)
        items.removeAll { cleanedSet.contains($0.id) }
        selected.subtract(cleanedSet)
        if toClean.contains(where: { $0.definitionID == UvCacheCleaner.definitionID }) {
            let uvIDs = Set(items.filter { $0.definitionID == UvCacheCleaner.definitionID }.map(\.id))
            items.removeAll { $0.definitionID == UvCacheCleaner.definitionID }
            selected.subtract(uvIDs)
            if let remaining = await manager.scanUvCache() { items.append(remaining) }
            items.sort { $0.size > $1.size }
        }
        isCleaning = false

        CleanupHistory.shared.log(.developer, items: cleaned.count, freedBytes: freed)
        let loc = Localizer.shared
        if !cleaned.isEmpty {
            let messageKey = toClean.contains { $0.definitionID == UvCacheCleaner.definitionID }
                ? "dev.uv.cleanedFmt" : "toast.deletedFmt"
            ToastCenter.shared.success(
                loc.s("toast.deleted"),
                loc.f(messageKey, Fmt.plural("plural.items", cleaned.count), Fmt.bytes(Int64(freed)))
            )
        }
        if failed > 0 {
            presentRemovalFailures(await manager.lastRemovalResult)
            if let reason = await manager.uvFailureKey {
                ToastCenter.shared.error(loc.s(reason))
            }
        }
    }

    // MARK: - Project artifacts mode (node_modules / target / .build)

    public enum Mode: String, CaseIterable, Identifiable {
        case caches, projects
        public var id: String { rawValue }
        public var labelKey: String { "dev.mode.\(rawValue)" }
    }

    @Published public var mode: Mode = .caches
    @Published public var projects: [ProjectArtifact] = []
    @Published public var selectedProjects: Set<UUID> = []
    @Published public var isScanningProjects = false
    @Published public var hasScannedProjects = false

    public var selectedProjectsSize: UInt64 {
        projects.filter { selectedProjects.contains($0.id) }.reduce(0) { $0 + $1.size }
    }
    public var formattedSelectedProjectsSize: String {
        Fmt.bytes(Int64(selectedProjectsSize))
    }
    public var totalProjectsSize: UInt64 { projects.reduce(0) { $0 + $1.size } }
    public var formattedTotalProjectsSize: String {
        Fmt.bytes(Int64(totalProjectsSize))
    }

    public func scanProjects() {
        guard !isCleaning else { return }
        guard !isScanningProjects else { return }
        isScanningProjects = true
        hasScannedProjects = true
        projects = []
        selectedProjects = []
        Task {
            let found = await manager.scanProjects()
            self.projects = found
            self.isScanningProjects = false
        }
    }

    public func toggleProject(_ item: ProjectArtifact) {
        if selectedProjects.contains(item.id) { selectedProjects.remove(item.id) }
        else { selectedProjects.insert(item.id) }
    }

    /// Selects artifacts of projects untouched for 3+ months — the "dead
    /// projects" quick pick.
    public func selectStaleProjects() {
        let cutoff = Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
        selectedProjects = Set(projects.filter {
            ($0.projectModified ?? .distantPast) < cutoff
        }.map(\.id))
    }

    public func deselectAllProjects() { selectedProjects.removeAll() }

    public func cleanProjects() async {
        guard !isCleaning, !isLoading, !isScanningProjects else { return }
        let toClean = projects.filter { selectedProjects.contains($0.id) }
        guard !toClean.isEmpty else { return }
        isCleaning = true
        let (cleaned, failed, freed) = await manager.cleanProjects(toClean)
        let cleanedSet = Set(cleaned)
        projects.removeAll { cleanedSet.contains($0.id) }
        selectedProjects.subtract(cleanedSet)
        isCleaning = false

        CleanupHistory.shared.log(.developer, items: cleaned.count, freedBytes: freed)
        let loc = Localizer.shared
        if !cleaned.isEmpty {
            ToastCenter.shared.success(
                loc.s("toast.deleted"),
                loc.f("toast.deletedFmt", Fmt.plural("plural.items", cleaned.count), Fmt.bytes(Int64(freed)))
            )
        }
        if failed > 0 {
            presentRemovalFailures(await manager.lastRemovalResult)
        }
    }

    /// Native uv failures are reported separately, so a mixed batch also
    /// keeps every ordinary permission, safety and activity explanation.
    private func presentRemovalFailures(_ result: DeletionService.Result?) {
        guard let result else { return }
        RemovalReport.present(failed: result.failed, obstacles: result.obstacles,
                              escalation: result.escalation, permanent: true)
        if !result.blocked.isEmpty {
            ToastCenter.shared.error(Localizer.shared.f("guard.blockedFmt",
                RemovalReport.explanation(nil, urls: result.blocked)))
        }
    }
}
