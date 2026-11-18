import XCTest
@testable import CleanAppCacheLib

/// Bundle-id matching decides whose data gets deleted. Both directions of
/// error are expensive:
/// - too loose, and uninstalling one app takes a sibling app's data with it;
/// - too strict, and the working data of an installed app is offered up as an
///   "leftover" from something the user removed.
final class BundleIDMatchingTests: XCTestCase {

    // MARK: - AppManager.owningBundleID

    func testExactMatchWins() {
        let installed: Set<String> = ["com.acme.app"]
        XCTAssertEqual(AppManager.owningBundleID(of: "com.acme.app", installed: installed),
                       "com.acme.app")
    }

    func testSuffixedContainersAreOwnedByTheirParentApp() {
        let installed: Set<String> = ["com.acme.app"]
        XCTAssertEqual(
            AppManager.owningBundleID(of: "com.acme.app.shareextension", installed: installed),
            "com.acme.app"
        )
        XCTAssertEqual(
            AppManager.owningBundleID(of: "com.acme.app.plist", installed: installed),
            "com.acme.app"
        )
    }

    func testLexicalNeighbourIsNotOwned() {
        // The classic collision: com.acme.app must not claim com.acme.apple.
        let installed: Set<String> = ["com.acme.app"]
        XCTAssertNil(AppManager.owningBundleID(of: "com.acme.apple", installed: installed))
        XCTAssertNil(AppManager.owningBundleID(of: "com.acme.application", installed: installed))
    }

    func testLongestInstalledIDWins() {
        // Uninstalling com.adobe.acrobat must not delete com.adobe.acrobat.reader's
        // data while Reader is still installed.
        let installed: Set<String> = ["com.adobe.acrobat", "com.adobe.acrobat.reader"]
        XCTAssertEqual(
            AppManager.owningBundleID(of: "com.adobe.acrobat.reader", installed: installed),
            "com.adobe.acrobat.reader"
        )
        XCTAssertEqual(
            AppManager.owningBundleID(of: "com.adobe.acrobat.reader.helper", installed: installed),
            "com.adobe.acrobat.reader"
        )
    }

    func testAppKnownOnlyToLaunchServicesOwnsItsData() {
        // com.acme.app.pro runs from Downloads, outside the folders the walk
        // sees; uninstalling com.acme.app must leave its data alone.
        let installed: Set<String> = ["com.acme.app"]
        let elsewhere: (String) -> Bool = { $0 == "com.acme.app.pro" }
        XCTAssertEqual(
            AppManager.owningBundleID(of: "com.acme.app.pro.savedstate", installed: installed,
                                      applicationExists: elsewhere),
            "com.acme.app.pro"
        )
        XCTAssertEqual(
            AppManager.owningBundleID(of: "com.acme.app.helper", installed: installed,
                                      applicationExists: elsewhere),
            "com.acme.app"
        )
    }

    func testUnrelatedNamesHaveNoOwner() {
        let installed: Set<String> = ["com.acme.app"]
        XCTAssertNil(AppManager.owningBundleID(of: "com.other.thing", installed: installed))
        XCTAssertNil(AppManager.owningBundleID(of: "notabundleid", installed: installed))
    }

    // MARK: - LeftoversManager

    func testExtensionContainersOfInstalledAppsAreNotLeftovers() async {
        let mgr = LeftoversManager.shared
        let installed: Set<String> = ["com.acme.app"]

        // These all live in ~/Library/Containers alongside the app's own
        // container and hold the working state of a *running* product.
        for key in ["com.acme.app.shareextension",
                    "com.acme.app.helper",
                    "com.acme.app.widget",
                    "com.acme.app.binarycookies"] {
            let flagged = await mgr.isLeftoverBundleKey(key, installedIDs: installed)
            XCTAssertFalse(flagged, "\(key) belongs to an installed app")
        }
    }

    func testAppGroupsOfInstalledAppsAreNotLeftovers() async {
        let mgr = LeftoversManager.shared
        let installed: Set<String> = ["com.acme.app"]
        let flagged = await mgr.isLeftoverBundleKey("group.com.acme.app", installedIDs: installed)
        XCTAssertFalse(flagged, "app groups hold shared data of an installed app")
    }

    func testGenuineLeftoversAreStillDetected() async {
        let mgr = LeftoversManager.shared
        let installed: Set<String> = ["com.acme.app"]

        for key in ["com.gone.oldapp",
                    "com.gone.oldapp.helper",
                    "group.com.gone.oldapp"] {
            let flagged = await mgr.isLeftoverBundleKey(key, installedIDs: installed)
            XCTAssertTrue(flagged, "\(key) has no installed owner")
        }
    }

    func testLexicalNeighbourIsStillALeftover() async {
        // The reverse of the collision test: com.acme.apple is a different app
        // and, if it isn't installed, its data really is a leftover.
        let mgr = LeftoversManager.shared
        let flagged = await mgr.isLeftoverBundleKey(
            "com.acme.apple", installedIDs: ["com.acme.app"]
        )
        XCTAssertTrue(flagged)
    }
}
