import XCTest
@testable import CleanAppCacheLib

/// Turning a startup agent off writes only a launchd override; the agent's
/// plist is never rewritten. A recording stand-in replaces `launchctl`, so
/// nothing here touches the real launchd override database.
final class StartupToggleTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("startup-toggle-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private final class Recorder: @unchecked Sendable {
        var calls: [[String]] = []
        var failVerbs: Set<String> = []
        func run(_ args: [String]) -> String? {
            calls.append(args)
            return failVerbs.contains(args[0]) ? nil : ""
        }
    }

    private func agent(scope: StartupItem.Scope = .userAgent, disabled: Bool? = nil,
                       writePlist: Bool = true) throws -> StartupItem {
        let url = root.appendingPathComponent("com.cacfixture.agent.plist")
        if writePlist {
            var plist: [String: Any] = ["Label": "com.cacfixture.agent",
                                        "ProgramArguments": ["/usr/bin/true"], "RunAtLoad": true]
            if let disabled { plist["Disabled"] = disabled }
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        }
        return StartupItem(label: "com.cacfixture.agent", program: "/usr/bin/true", plistURL: url,
                           scope: scope, runAtLoad: true, isEnabled: disabled != true)
    }

    private func plist(_ item: StartupItem) throws -> [String: Any] {
        let data = try Data(contentsOf: item.plistURL)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testTurningAUserAgentOffWritesTheOverrideBootsItOutAndLeavesThePlist() async throws {
        let item = try agent()
        let before = try Data(contentsOf: item.plistURL)
        let launchctl = Recorder()

        let ok = await StartupManager.shared.setEnabled(false, for: item, launchctl: launchctl.run)

        XCTAssertTrue(ok)
        XCTAssertEqual(try Data(contentsOf: item.plistURL), before, "the vendor's plist is not rewritten")
        XCTAssertEqual(launchctl.calls, [["disable", "gui/\(getuid())/com.cacfixture.agent"],
                                         ["bootout", "gui/\(getuid())", item.plistURL.path]])
    }

    func testTurningAUserAgentBackOnEnablesTheOverrideAndBootstrapsIt() async throws {
        let item = try agent(disabled: true)
        let launchctl = Recorder()

        let ok = await StartupManager.shared.setEnabled(true, for: item, launchctl: launchctl.run)

        XCTAssertTrue(ok)
        XCTAssertEqual(try plist(item)["Disabled"] as? Bool, true, "the override, not the plist, decides")
        XCTAssertEqual(launchctl.calls.map { $0[0] }, ["enable", "bootstrap"])
    }

    func testFailedOverrideReportsFailureAndLeavesThePlist() async throws {
        let item = try agent()
        let before = try Data(contentsOf: item.plistURL)
        let launchctl = Recorder()
        launchctl.failVerbs = ["disable"]

        let ok = await StartupManager.shared.setEnabled(false, for: item, launchctl: launchctl.run)

        XCTAssertFalse(ok)
        XCTAssertEqual(try Data(contentsOf: item.plistURL), before)
        XCTAssertEqual(launchctl.calls.map { $0[0] }, ["disable"], "a failed override stops before bootout")
    }

    func testFailedBootoutIsNotFatalBecauseTheChangePersistsAcrossLogin() async throws {
        let item = try agent()
        let launchctl = Recorder()
        launchctl.failVerbs = ["bootout"]

        let ok = await StartupManager.shared.setEnabled(false, for: item, launchctl: launchctl.run)

        XCTAssertTrue(ok)
        XCTAssertEqual(launchctl.calls.map { $0[0] }, ["disable", "bootout"])
    }

    func testGlobalAgentPlistStaysUntouched() async throws {
        let item = try agent(scope: .globalAgent)
        let before = try Data(contentsOf: item.plistURL)
        let launchctl = Recorder()

        let ok = await StartupManager.shared.setEnabled(false, for: item, launchctl: launchctl.run)

        XCTAssertTrue(ok)
        XCTAssertEqual(try Data(contentsOf: item.plistURL), before)
        XCTAssertEqual(launchctl.calls.first, ["disable", "gui/\(getuid())/com.cacfixture.agent"])
    }

    func testUnreadablePlistFailsBeforeAnyLaunchctlCall() async throws {
        let item = try agent(writePlist: false)
        let launchctl = Recorder()

        let ok = await StartupManager.shared.setEnabled(false, for: item, launchctl: launchctl.run)

        XCTAssertFalse(ok)
        XCTAssertTrue(launchctl.calls.isEmpty)
    }

    func testLoginItemsAndDaemonsAreNotToggledHere() async throws {
        let launchctl = Recorder()
        for scope in [StartupItem.Scope.loginItem, .daemon] {
            let item = try agent(scope: scope)
            let ok = await StartupManager.shared.setEnabled(false, for: item, launchctl: launchctl.run)
            XCTAssertFalse(ok, "\(scope)")
            XCTAssertEqual(try plist(item)["Disabled"] as? Bool, nil)
        }
        XCTAssertTrue(launchctl.calls.isEmpty)
    }

    // MARK: - What turn-off acts on, and what never reaches root

    @MainActor
    func testActionableKeepsLoginItemsAndEnabledJobsOnly() throws {
        let enabled = try agent(scope: .userAgent)
        let alreadyOff = try agent(scope: .globalAgent, disabled: true)
        let login = StartupItem(label: "Editor", program: "/Applications/Editor.app/x", plistURL: root,
                                scope: .loginItem, runAtLoad: true, isEnabled: false)

        let result = StartupViewModel.actionable([enabled, alreadyOff, login])

        XCTAssertEqual(result.map(\.scope), [.userAgent, .loginItem])
    }

    func testDisableDaemonsRefusesNonDaemonsAndUnsafeLabelsWithoutAskingForAPassword() async throws {
        let userAgent = try agent(scope: .userAgent)
        let hostile = StartupItem(label: "com.example; rm -rf /", program: "/x", plistURL: root,
                                  scope: .daemon, runAtLoad: true, isEnabled: true)

        let result = await StartupManager.shared.disableDaemons([userAgent, hostile], prompt: "unused")

        XCTAssertTrue(result.disabled.isEmpty)
        XCTAssertEqual(result.outcome, .failed, "no dialog may open when nothing qualifies")
    }

    // MARK: - Login items

    func testLoginItemLinesParseNamesAndPathsAndSkipBlanks() {
        let items = StartupManager.parseLoginItems("Editor\t/Applications/Editor.app/\n\t\n\t/Applications/Tool.app\n")

        XCTAssertEqual(items.map(\.label), ["Editor", "Tool.app"])
        XCTAssertEqual(items.map(\.program), ["/Applications/Editor.app/", "/Applications/Tool.app"])
        XCTAssertTrue(items.allSatisfy { $0.scope == .loginItem })
    }
}
