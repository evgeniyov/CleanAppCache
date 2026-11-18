import XCTest
@testable import CleanAppCacheLib

/// `DeveloperViewModel.clean()` and `cleanProjects()` delete permanently, so
/// what they remove, what stays listed afterwards and what they refuse to
/// start are each checked on scratch directories.
@MainActor
final class DeveloperViewModelTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("developer-vm-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func cache(_ name: String, bytes: Int = 8192) throws -> DevJunkItem {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url.appendingPathComponent("blob"))
        return DevJunkItem(definitionID: "simulatorCaches", url: url, size: UInt64(bytes), safe: true)
    }

    private func project(_ name: String, kind: ProjectArtifact.Kind = .node) throws -> ProjectArtifact {
        let dir = root.appendingPathComponent(name)
        let build = dir.appendingPathComponent("node_modules")
        try fm.createDirectory(at: build, withIntermediateDirectories: true)
        try Data("manifest".utf8).write(to: dir.appendingPathComponent("package.json"))
        try Data(repeating: 1, count: 8192).write(to: build.appendingPathComponent("sentinel"))
        return ProjectArtifact(url: build, projectName: name, projectPath: dir.path, kind: kind,
                               size: 8192, projectModified: .distantPast)
    }

    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    /// A fresh scratch artifact would otherwise count as in use whenever a
    /// `node` or `swift` process happens to be running on the machine.
    private func viewModel() -> DeveloperViewModel {
        DeveloperViewModel(manager: DevCleanManager(
            isInUse: { _ in false }, uvIsInUse: { false },
            uvCleaner: UvCacheCleaner(home: root, environment: [:], discoverExecutable: false)))
    }

    // MARK: - Caches

    func testCleanDeletesOnlySelectedCachesAndLeavesTheRestListed() async throws {
        let a = try cache("a")
        let b = try cache("b")
        let vm = viewModel()
        vm.items = [a, b]
        vm.selected = [a.id]
        let before = CleanupHistory.shared.totalFreedBytes

        await vm.clean()

        XCTAssertFalse(exists(a.url))
        XCTAssertTrue(exists(b.url))
        XCTAssertEqual(vm.items.map(\.id), [b.id])
        XCTAssertTrue(vm.selected.isEmpty)
        XCTAssertFalse(vm.isCleaning)
        XCTAssertEqual(CleanupHistory.shared.totalFreedBytes - before, 8192)
        XCTAssertEqual(CleanupHistory.shared.records.first?.source, .developer)
    }

    func testCleanWithNothingSelectedTouchesNothing() async throws {
        let a = try cache("a")
        let vm = viewModel()
        vm.items = [a]
        let records = CleanupHistory.shared.records.count

        await vm.clean()

        XCTAssertTrue(exists(a.url))
        XCTAssertEqual(vm.items.count, 1)
        XCTAssertEqual(CleanupHistory.shared.records.count, records)
    }

    func testCleanDoesNotStartWhileScanningCleaningOrScanningProjects() async throws {
        let a = try cache("a")
        let vm = viewModel()
        vm.items = [a]
        vm.selected = [a.id]

        for busy in [\DeveloperViewModel.isLoading, \.isCleaning, \.isScanningProjects] {
            vm[keyPath: busy] = true
            await vm.clean()
            vm[keyPath: busy] = false
            XCTAssertTrue(exists(a.url), "\(busy) must block the delete")
        }
        XCTAssertEqual(vm.items.count, 1)
    }

    func testCacheReplacedAfterScanIsNotDeletedAndStaysSelected() async throws {
        let stale = try cache("stale")
        let fresh = try cache("fresh")
        let vm = viewModel()
        vm.items = [stale, fresh]
        vm.selected = [stale.id, fresh.id]
        try fm.moveItem(at: stale.url, to: root.appendingPathComponent("held"))
        try fm.createDirectory(at: stale.url, withIntermediateDirectories: true)
        try Data("user data".utf8).write(to: stale.url.appendingPathComponent("blob"))

        await vm.clean()

        XCTAssertEqual(try String(contentsOf: stale.url.appendingPathComponent("blob")), "user data")
        XCTAssertFalse(exists(fresh.url))
        XCTAssertEqual(vm.items.map(\.id), [stale.id], "the refused row stays so the user sees it")
        XCTAssertEqual(vm.selected, [stale.id])
    }

    // MARK: - Project artifacts

    func testCleanProjectsDeletesSelectedArtifactsButKeepsTheProject() async throws {
        let one = try project("one")
        let two = try project("two")
        let vm = viewModel()
        vm.projects = [one, two]
        vm.selectedProjects = [one.id]
        let before = CleanupHistory.shared.totalFreedBytes

        await vm.cleanProjects()

        XCTAssertFalse(exists(one.url))
        XCTAssertTrue(exists(root.appendingPathComponent("one/package.json")), "only the artifact goes")
        XCTAssertTrue(exists(two.url))
        XCTAssertEqual(vm.projects.map(\.id), [two.id])
        XCTAssertTrue(vm.selectedProjects.isEmpty)
        XCTAssertEqual(CleanupHistory.shared.totalFreedBytes - before, 8192)
    }

    func testCleanProjectsKeepsAnArtifactInsideAnAppPackageListed() async throws {
        let packaged = try project("Tool.app/Contents/Resources/app")
        let ordinary = try project("web")
        let vm = viewModel()
        vm.projects = [packaged, ordinary]
        vm.selectedProjects = [packaged.id, ordinary.id]

        await vm.cleanProjects()

        XCTAssertTrue(exists(packaged.url.appendingPathComponent("sentinel")))
        XCTAssertFalse(exists(ordinary.url))
        XCTAssertEqual(vm.projects.map(\.id), [packaged.id])
        XCTAssertEqual(vm.selectedProjects, [packaged.id])
    }

    func testCleanProjectsDoesNotStartWhileBusyOrWithNothingSelected() async throws {
        let one = try project("one")
        let vm = viewModel()
        vm.projects = [one]

        await vm.cleanProjects()
        XCTAssertTrue(exists(one.url), "an empty selection deletes nothing")

        vm.selectedProjects = [one.id]
        for busy in [\DeveloperViewModel.isLoading, \.isCleaning, \.isScanningProjects] {
            vm[keyPath: busy] = true
            await vm.cleanProjects()
            vm[keyPath: busy] = false
            XCTAssertTrue(exists(one.url), "\(busy) must block the delete")
        }
    }
}
