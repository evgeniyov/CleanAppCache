import XCTest
@testable import CleanAppCacheLib

final class ProjectArtifactSafetyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("project-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func artifact(_ relative: String, kind: ProjectArtifact.Kind = .node) throws -> ProjectArtifact {
        let project = root.appendingPathComponent(relative)
        let name: String
        let marker: String
        switch kind {
        case .node: name = "node_modules"; marker = "package.json"
        case .cargo: name = "target"; marker = "Cargo.toml"
        case .swiftpm: name = ".build"; marker = "Package.swift"
        }
        let build = project.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data("manifest".utf8).write(to: project.appendingPathComponent(marker))
        try Data(repeating: 1, count: 8192).write(to: build.appendingPathComponent("sentinel"))
        return ProjectArtifact(url: build, projectName: project.lastPathComponent, projectPath: project.path,
                               kind: kind, size: 8192, projectModified: .distantPast)
    }

    private func manager(isInUse: @escaping @Sendable (URL) -> Bool = { _ in false }) -> DevCleanManager {
        DevCleanManager(isInUse: isInUse, uvIsInUse: { false },
                        uvCleaner: UvCacheCleaner(home: root, environment: [:], discoverExecutable: false))
    }

    func testProjectSearchSkipsApplicationAndCodePackagesOutsideApplications() async throws {
        let ordinary = [
            try artifact("Projects/web"),
            try artifact("Projects/crate", kind: .cargo),
            try artifact("Projects/package", kind: .swiftpm)
        ]
        _ = try artifact("Downloads/Tool.app/Contents/Resources/app")
        _ = try artifact("Documents/Upper.APP/Contents/Resources/app")
        for suffix in ["framework", "xcframework", "bundle", "plugin", "xpc", "appex"] {
            _ = try artifact("Documents/Runtime.\(suffix)/Resources/component")
        }

        let found = await DevCleanManager.projectCandidates(home: root.path)
        XCTAssertEqual(Set(found.candidates.map { $0.0.path }), Set(ordinary.map { $0.url.path }))
    }

    func testProjectCleanupRefusesRuntimeModulesAndKeepsOrdinaryBuildArtifactsWorking() async throws {
        let packaged = [
            try artifact("Downloads/Tool.app/Contents/Resources/app"),
            try artifact("Documents/Runtime.framework/Resources/component")
        ]
        let ordinary = [
            try artifact("Projects/web"),
            try artifact("Projects/crate", kind: .cargo),
            try artifact("Projects/package", kind: .swiftpm)
        ]
        let candidate = manager()
        let result = await candidate.cleanProjects(packaged + ordinary)

        XCTAssertEqual(Set(result.cleaned), Set(ordinary.map(\.id)))
        XCTAssertEqual(result.failed, packaged.count)
        for item in packaged {
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.appendingPathComponent("sentinel").path))
        }
        for item in ordinary { XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path)) }
        let removal = await candidate.lastRemovalResult
        for item in packaged { XCTAssertEqual(removal?.obstacles[item.url], .changedSinceScan) }
    }

    func testProjectCleanupRefusesParentRedirectedIntoPackageAfterScan() async throws {
        let item = try artifact("Projects/web")
        let original = item.url.deletingLastPathComponent()
        let packaged = root.appendingPathComponent("Tool.app")
        try FileManager.default.moveItem(at: original, to: packaged)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: packaged)

        let result = await manager().cleanProjects([item])

        XCTAssertTrue(result.cleaned.isEmpty)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(try Data(contentsOf: packaged.appendingPathComponent("node_modules/sentinel")),
                       Data(repeating: 1, count: 8192))
    }

    func testProjectCleanupRechecksPackageBoundaryAfterPreflight() async throws {
        let item = try artifact("Projects/web")
        let packaged = root.appendingPathComponent("Tool.app")
        let swap = PackageParentSwap(original: item.url.deletingLastPathComponent(), packaged: packaged)
        let candidate = manager(isInUse: { _ in swap.perform(); return false })

        let result = await candidate.cleanProjects([item])

        XCTAssertNil(swap.error)
        XCTAssertTrue(result.cleaned.isEmpty)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(try Data(contentsOf: packaged.appendingPathComponent("node_modules/sentinel")),
                       Data(repeating: 1, count: 8192))
    }
}

/// The injected activity check swaps the parent after eligibility preflight,
/// without relying on timing or changing any installed application.
private final class PackageParentSwap: @unchecked Sendable {
    private let lock = NSLock()
    private let original: URL
    private let packaged: URL
    private var performed = false
    private var failure: Error?

    init(original: URL, packaged: URL) { self.original = original; self.packaged = packaged }

    var error: Error? {
        lock.lock(); defer { lock.unlock() }
        return failure
    }

    func perform() {
        lock.lock(); defer { lock.unlock() }
        guard !performed else { return }
        performed = true
        do {
            try FileManager.default.moveItem(at: original, to: packaged)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: packaged)
        } catch { failure = error }
    }
}
