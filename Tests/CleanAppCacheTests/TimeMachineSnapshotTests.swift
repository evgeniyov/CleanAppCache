import XCTest
@testable import CleanAppCacheLib

/// Local Time Machine snapshots are listed, deleted and thinned through
/// `tmutil`. A stand-in runner replaces it, so no test touches a real
/// snapshot, and what each refusal means is checked against the messages
/// tmutil prints.
final class TimeMachineSnapshotTests: XCTestCase {

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(path: String, args: [String])] = []
        func record(_ path: String, _ args: [String]) {
            lock.lock(); stored.append((path, args)); lock.unlock()
        }
        var all: [(path: String, args: [String])] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private func manager(_ calls: Calls = Calls(), stdout: String = "", stderr: String = "",
                         status: Int32 = 0, missing: Bool = false) -> SystemDataManager {
        SystemDataManager(runner: { path, args in
            calls.record(path, args)
            return missing ? nil : SystemDataManager.ProcResult(stdout: stdout, stderr: stderr, status: status)
        })
    }

    private func snapshot(_ token: String = "2026-07-18-123456") -> TMSnapshot {
        TMSnapshot(id: "com.apple.TimeMachine.\(token).local", dateToken: token, date: nil)
    }

    // MARK: - Listing

    func testListParsesNamesTokensAndSortsNewestFirst() async {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-07-16-090000.local
          com.apple.TimeMachine.2026-07-18-123456.local
        com.apple.TimeMachine.2026-07-17-235959.local
        com.apple.os.update-ABCDEF
        """

        let snapshots = await manager(stdout: output).listSnapshots()

        XCTAssertEqual(snapshots?.map(\.dateToken), ["2026-07-18-123456", "2026-07-17-235959", "2026-07-16-090000"],
                       "other snapshot kinds and the header are not Time Machine's")
        XCTAssertEqual(snapshots?.first?.id, "com.apple.TimeMachine.2026-07-18-123456.local")
        XCTAssertNotNil(snapshots?.first?.date)
    }

    func testListAsksTmutilAboutTheStartupVolumeOnly() async {
        let calls = Calls()
        _ = await manager(calls).listSnapshots()

        XCTAssertEqual(calls.all.count, 1)
        XCTAssertEqual(calls.all.first?.path, "/usr/bin/tmutil")
        XCTAssertEqual(calls.all.first?.args, ["listlocalsnapshots", "/"])
    }

    func testEmptyAnswerIsNoSnapshotsButARefusalIsUnknown() async {
        let none = await manager(stdout: "Snapshots for disk /:\n").listSnapshots()
        let refused = await manager(stderr: "Operation not permitted", status: 1).listSnapshots()
        let missing = await manager(missing: true).listSnapshots()

        XCTAssertEqual(none?.count, 0, "tmutil answered: there are none")
        XCTAssertNil(refused, "a refusal must not read as zero snapshots")
        XCTAssertNil(missing)
    }

    // MARK: - Deleting

    func testDeleteSendsOnlyTheSnapshotsDateToken() async {
        let calls = Calls()

        let failure = await manager(calls).deleteSnapshot(snapshot("2026-07-18-123456"))

        XCTAssertNil(failure)
        XCTAssertEqual(calls.all.count, 1)
        XCTAssertEqual(calls.all.first?.args, ["deletelocalsnapshots", "2026-07-18-123456"])
    }

    func testDeleteReportsWhyTmutilRefused() async {
        let fda = await manager(stderr: "tmutil: requires Full Disk Access privileges", status: 1)
            .deleteSnapshot(snapshot())
        let rights = await manager(stderr: "Delete failed: Operation not permitted", status: 1)
            .deleteSnapshot(snapshot())
        let root = await manager(stderr: "must be run as root", status: 1).deleteSnapshot(snapshot())
        let other = await manager(stderr: "  no such snapshot\n", status: 1).deleteSnapshot(snapshot())
        let silent = await manager(status: 1).deleteSnapshot(snapshot())
        let missing = await manager(missing: true).deleteSnapshot(snapshot())

        XCTAssertEqual(fda, .needsFullDiskAccess)
        XCTAssertEqual(rights, .notPermitted)
        XCTAssertEqual(root, .notPermitted)
        XCTAssertEqual(other, .failed("no such snapshot"), "stderr is trimmed for the log")
        XCTAssertEqual(silent, .failed(""))
        XCTAssertEqual(missing, .failed(""), "a tool that cannot launch is a failure, not a success")
    }

    // MARK: - Thinning

    func testThinAsksForMaximumReclaimOnTheStartupVolume() async {
        let calls = Calls()

        let failure = await manager(calls).thinAllSnapshots()

        XCTAssertNil(failure)
        XCTAssertEqual(calls.all.first?.path, "/usr/bin/tmutil")
        XCTAssertEqual(calls.all.first?.args, ["thinlocalsnapshots", "/", "999999999999", "4"])
    }

    func testThinReportsRefusalsTheSameWayAsDelete() async {
        let fda = await manager(stderr: "Full Disk Access required", status: 1).thinAllSnapshots()
        let rights = await manager(stderr: "Not permitted", status: 1).thinAllSnapshots()

        XCTAssertEqual(fda, .needsFullDiskAccess)
        XCTAssertEqual(rights, .notPermitted)
    }

    func testFullDiskAccessWinsWhenBothPhrasesAppear() {
        XCTAssertEqual(SystemDataManager.classify("Not permitted: grant Full Disk Access to continue"),
                       .needsFullDiskAccess)
    }
}
