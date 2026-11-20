import XCTest
@testable import CleanAppCacheLib

/// The Developer section deletes permanently, so what it selects, how it
/// counts and where it searches are each a data-safety question.
final class DevCleanManagerTests: XCTestCase {

    private var temp: URL!

    override func setUpWithError() throws {
        temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devclean_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    // MARK: - Nesting guard

    func testOutermostDropsURLsInsideAnotherSelectedURL() {
        let urls = [
            URL(fileURLWithPath: "/u/Library/Developer/CoreSimulator/Caches/dyld"),
            URL(fileURLWithPath: "/u/Library/Developer/CoreSimulator/Caches"),
            URL(fileURLWithPath: "/u/Library/Developer/CoreSimulator/Devices"),
        ]
        let kept = DevCleanManager.outermost(urls) { $0 }.map(\.path)
        XCTAssertEqual(kept, ["/u/Library/Developer/CoreSimulator/Caches",
                              "/u/Library/Developer/CoreSimulator/Devices"])
    }

    func testOutermostComparesWholePathComponents() {
        let urls = [URL(fileURLWithPath: "/u/cache"), URL(fileURLWithPath: "/u/cache-old/x")]
        XCTAssertEqual(DevCleanManager.outermost(urls) { $0 }.count, 2,
                       "/u/cache-old is a sibling of /u/cache, not inside it")
    }

    func testOutermostKeepsOneOfIdenticalPaths() {
        let urls = [URL(fileURLWithPath: "/u/a/b"), URL(fileURLWithPath: "/u/a/./b"),
                    URL(fileURLWithPath: "/u/a/c/../b")]
        XCTAssertEqual(DevCleanManager.outermost(urls) { $0 }.count, 1)
    }

    func testNoCuratedLocationLiesInsideAnother() {
        let urls = DevCleanManager.definitions.map {
            URL(fileURLWithPath: "/home").appendingPathComponent($0.relativePath)
        }
        XCTAssertEqual(DevCleanManager.outermost(urls) { $0 }.count, urls.count)
        XCTAssertEqual(Set(DevCleanManager.definitions.map(\.id)).count,
                       DevCleanManager.definitions.count, "definition ids must be unique")
    }

    func testCleaningANestedSelectionDeletesOnceAndCountsOnce() async throws {
        let fm = FileManager.default
        let outer = temp.appendingPathComponent("Caches")
        let inner = outer.appendingPathComponent("dyld")
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: inner.appendingPathComponent("blob"))

        let outerItem = DevJunkItem(definitionID: "simulatorCaches", url: outer, size: 8192, safe: true)
        let innerItem = DevJunkItem(definitionID: "simulatorCaches", url: inner, size: 8192, safe: true)
        let result = await DevCleanManager.shared.clean(items: [innerItem, outerItem])

        XCTAssertFalse(fm.fileExists(atPath: outer.path))
        XCTAssertEqual(Set(result.cleaned), [outerItem.id, innerItem.id],
                       "the inner row went with the outer one and must leave the list")
        XCTAssertEqual(result.failed, 0, "no second delete may be attempted on a path already gone")
        XCTAssertEqual(result.freedBytes, 8192, "the inner size is part of the outer one")
    }

    // MARK: - Selection and wording

    func testOnlyRegenerableLocationsAreSafe() {
        let unsafe = Set(DevCleanManager.definitions.filter { !$0.safe }.map(\.id))
        XCTAssertEqual(unsafe, ["archives", "pubCache", "goModules", "simulatorDevices",
                                "docker", "orbstack", "maven", "uv-cache"])
    }

    /// The names are interpolated keys, which the invariants script skips.
    func testEveryCuratedLocationIsLocalizedInBothLanguages() throws {
        for language in ["en", "ru"] {
            let strings = try localizedStrings(language)
            for definition in DevCleanManager.definitions {
                let item = DevJunkItem(definitionID: definition.id, url: temp, size: 1,
                                       safe: definition.safe)
                XCTAssertNotNil(strings[item.titleKey], "\(language): \(item.titleKey)")
                XCTAssertNotNil(strings[item.detailKey], "\(language): \(item.detailKey)")
                if !definition.safe {
                    XCTAssertNotNil(strings[item.lossKey], "\(language): \(item.lossKey)")
                }
            }
        }
    }

    private func localizedStrings(_ language: String) throws -> [String: String] {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CleanAppCacheLib/Resources/\(language).lproj/Localizable.strings")
        let dictionary = try XCTUnwrap(NSDictionary(contentsOf: file) as? [String: String])
        return dictionary
    }

    func testUvFailuresAndEstimateAreLocalized() throws {
        for language in ["en", "ru"] {
            let strings = try localizedStrings(language)
            for suffix in ["unavailable", "configuration", "changed", "busy", "unsupported", "failed", "cleanedFmt"] {
                let key = "dev.uv.\(suffix)"
                XCTAssertNotNil(strings[key], "\(language): \(key)")
            }
            if let message = strings["dev.uv.cleanedFmt"] {
                let formatted = String(format: message, "ITEM_COUNT", "BYTE_ESTIMATE")
                XCTAssertTrue(formatted.contains("ITEM_COUNT"))
                XCTAssertTrue(formatted.contains("BYTE_ESTIMATE"))
            }
        }
    }

    // MARK: - Project search

    func testProjectSearchSkipsHiddenTopLevelFoldersLibraryAndApplications() async throws {
        let home = temp.appendingPathComponent("home")
        func project(_ relative: String, artifact: String, marker: String) throws {
            let dir = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(artifact),
                                                    withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: dir.appendingPathComponent(marker).path, contents: Data())
        }
        // Installed tools, not projects: deleting these breaks them.
        try project(".vscode/extensions/pub.ext-1.0.0", artifact: "node_modules", marker: "package.json")
        try project(".cursor/extensions/other-2.0.0", artifact: "node_modules", marker: "package.json")
        try project(".nvm/versions/node/v20/lib", artifact: "node_modules", marker: "package.json")
        try project("Applications/Tool.app/Contents/Resources/app", artifact: "node_modules", marker: "package.json")
        try project("Library/Application Support/Some", artifact: "node_modules", marker: "package.json")
        // Real projects, hidden folders below the top level included.
        try project("Projects/web", artifact: "node_modules", marker: "package.json")
        try project("Projects/web/node_modules/dep", artifact: "node_modules", marker: "package.json")
        try project("Projects/crate", artifact: "target", marker: "Cargo.toml")
        try project("Projects/.tools/pkg", artifact: ".build", marker: "Package.swift")
        // No marker, no project.
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Projects/loose/node_modules"), withIntermediateDirectories: true)

        let result = await DevCleanManager.projectCandidates(home: home.path)
        let found = result.candidates.map { String($0.0.path.dropFirst(home.path.count + 1)) }
        XCTAssertNil(result.skipReason)
        XCTAssertEqual(Set(found), ["Projects/web/node_modules",
                                    "Projects/crate/target",
                                    "Projects/.tools/pkg/.build"])
    }

    func testProjectSearchMatchesTheHomePathLiterally() {
        XCTAssertEqual(DevCleanManager.globEscaped("/Users/a[1]*?\\b"), "/Users/a\\[1\\]\\*\\?\\\\b")
        let args = DevCleanManager.projectFindArguments(home: "/Users/a*/")
        XCTAssertEqual(args.first, "/Users/a*")
        XCTAssertTrue(args.contains("/Users/a\\*/.*"))
        XCTAssertTrue(args.contains("/Users/a\\*/Applications"))
    }
}
