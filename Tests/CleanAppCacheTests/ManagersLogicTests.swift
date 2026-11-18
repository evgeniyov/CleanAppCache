import XCTest
@testable import CleanAppCacheLib

/// Tests the safety-critical classification logic: what counts as a leftover
/// (drives permanent-ish cleanup) and how a launch agent's enabled/disabled
/// state is parsed (drives the Startup toggles).
final class ManagersLogicTests: XCTestCase {

    // MARK: - LeftoversManager.isLeftoverBundleKey

    func testLeftoverBundleKeyDetection() async {
        let mgr = LeftoversManager.shared
        let installed: Set<String> = ["com.installed.app"]

        // Reverse-DNS, not installed, not an Apple/system namespace → leftover.
        let acme = await mgr.isLeftoverBundleKey("com.acme.oldapp", installedIDs: installed)
        XCTAssertTrue(acme)

        // Still installed → NOT a leftover (must never be flagged for removal).
        let installedApp = await mgr.isLeftoverBundleKey("com.installed.app", installedIDs: installed)
        XCTAssertFalse(installedApp)

        // Apple / system namespaces are excluded.
        let apple = await mgr.isLeftoverBundleKey("com.apple.Safari", installedIDs: installed)
        XCTAssertFalse(apple)
        let swiftpm = await mgr.isLeftoverBundleKey("org.swift.swiftpm", installedIDs: installed)
        XCTAssertFalse(swiftpm)

        // Not bundle-id-shaped (no dots, spaces, or too few dots) → ignored.
        let plainName = await mgr.isLeftoverBundleKey("Downloads", installedIDs: installed)
        XCTAssertFalse(plainName)
        let withSpace = await mgr.isLeftoverBundleKey("com.foo bar", installedIDs: installed)
        XCTAssertFalse(withSpace)
        let oneDot = await mgr.isLeftoverBundleKey("com.foo", installedIDs: installed)
        XCTAssertFalse(oneDot)
    }

    // MARK: - StartupManager.parse

    func testStartupParseReadsDisabledAndRunAtLoad() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("startup_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let plistURL = dir.appendingPathComponent("com.test.agent.plist")
        let dict: [String: Any] = [
            "Label": "com.test.agent",
            "ProgramArguments": ["/usr/bin/true"],
            "RunAtLoad": true,
            "Disabled": true
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: plistURL)

        let item = await StartupManager.shared.parse(url: plistURL, scope: .userAgent)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.label, "com.test.agent")
        XCTAssertEqual(item?.program, "/usr/bin/true")
        XCTAssertEqual(item?.runAtLoad, true)
        XCTAssertEqual(item?.isEnabled, false)          // Disabled = true
        XCTAssertEqual(item?.scope, .userAgent)
        XCTAssertEqual(item?.needsAdmin, false)         // user-scope agents don't
    }

    func testStartupParseEnabledWhenNoDisabledKey() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("startup_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let plistURL = dir.appendingPathComponent("com.test.enabled.plist")
        let dict: [String: Any] = ["Label": "com.test.enabled", "Program": "/bin/echo"]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: plistURL)

        let item = await StartupManager.shared.parse(url: plistURL, scope: .globalAgent)
        XCTAssertEqual(item?.isEnabled, true)           // absent Disabled → enabled
        // A global agent is switched off per user, in the user's own domain.
        XCTAssertEqual(item?.needsAdmin, false)
        let daemon = await StartupManager.shared.parse(url: plistURL, scope: .daemon)
        XCTAssertEqual(daemon?.needsAdmin, true)        // the system domain needs root
    }

    func testOnlyReverseDNSLabelsReachTheShell() {
        XCTAssertTrue(StartupManager.isSafeLabel("com.example.helper-daemon_2"))
        XCTAssertFalse(StartupManager.isSafeLabel(""))
        XCTAssertFalse(StartupManager.isSafeLabel("com.example; rm -rf /"))
        XCTAssertFalse(StartupManager.isSafeLabel("com.example'x"))
        XCTAssertFalse(StartupManager.isSafeLabel("com.exämple"))
    }

    // MARK: - launchd override database beats the plist

    /// Regression: `homebrew.mxcl.mysql` ships `Disabled = true` in its plist yet
    /// runs at login, because `launchctl enable` wrote an override for the label.
    /// Reading the plist alone reported the exact opposite of reality.
    func testOverrideBeatsDisabledKeyInPlist() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("startup_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let plistURL = dir.appendingPathComponent("homebrew.mxcl.mysql.plist")
        let dict: [String: Any] = [
            "Label": "homebrew.mxcl.mysql", "Program": "/usr/bin/true", "Disabled": true
        ]
        try PropertyListSerialization
            .data(fromPropertyList: dict, format: .xml, options: 0)
            .write(to: plistURL)

        // Override says enabled → the item is enabled despite Disabled = true.
        let enabled = await StartupManager.shared.parse(
            url: plistURL, scope: .userAgent, overrides: ["homebrew.mxcl.mysql": true])
        XCTAssertEqual(enabled?.isEnabled, true)

        // No override for this label → fall back to the plist key.
        let fallback = await StartupManager.shared.parse(
            url: plistURL, scope: .userAgent, overrides: ["some.other.label": true])
        XCTAssertEqual(fallback?.isEnabled, false)
    }

    /// And the opposite direction: no `Disabled` key, but launchd says disabled.
    func testOverrideCanDisableAnOtherwiseEnabledAgent() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("startup_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let plistURL = dir.appendingPathComponent("com.apple.Siri.agent.plist")
        let dict: [String: Any] = ["Label": "com.apple.Siri.agent", "Program": "/usr/bin/true"]
        try PropertyListSerialization
            .data(fromPropertyList: dict, format: .xml, options: 0)
            .write(to: plistURL)

        let item = await StartupManager.shared.parse(
            url: plistURL, scope: .userAgent, overrides: ["com.apple.Siri.agent": false])
        XCTAssertEqual(item?.isEnabled, false)
    }

    /// The parser is fused to the `launchctl` call, so the one thing checkable
    /// without a fixture is that a domain launchctl rejects yields nothing —
    /// not entries invented from its error text. (A loop over the live user
    /// domain would pass vacuously whenever that domain has no overrides,
    /// which is the common case.)
    func testUnknownDomainYieldsNoOverrides() {
        XCTAssertTrue(StartupManager.readOverrides(domain: "gui/nonexistent-domain").isEmpty)
    }
}
