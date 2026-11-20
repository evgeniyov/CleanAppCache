import XCTest
@testable import CleanAppCacheLib

final class MonitorProcessTests: XCTestCase {
    func testRanksGroupedTotalsBeforeLimitingEachSortOrder() {
        var processes = (1...45).map {
            ProcessInfoItem(id: Int32($0), name: "Busy \($0)", cpuPercent: 10, memBytes: 100)
        }
        processes += [
            ProcessInfoItem(id: 46, name: "Editor", cpuPercent: 0, memBytes: 1_000),
            ProcessInfoItem(id: 47, name: "Editor Helper (Renderer)", cpuPercent: 0, memBytes: 1_500),
        ]

        let groups = SystemMonitor().groupProcesses(processes)
        let cpu = ProcessGroup.ranked(groups, byMemory: false, query: "")
        XCTAssertEqual(cpu.count, 40)
        XCTAssertFalse(cpu.contains { $0.name == "Editor" })

        let memory = ProcessGroup.ranked(groups, byMemory: true, query: "")
        XCTAssertEqual(memory.count, 40)
        XCTAssertEqual(memory.first?.name, "Editor")
        XCTAssertEqual(memory.first?.memBytes, 2_500)
        XCTAssertEqual(memory.first?.children.count, 2)
        XCTAssertEqual(ProcessGroup.ranked(groups, byMemory: false, query: "editor").map(\.name), ["Editor"])
    }

    func testQuitRefusesAStaleOrUnverifiedRowAndQuitsTheMatchingChild() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }

        let monitor = SystemMonitor()
        let row = try XCTUnwrap(monitor.sample().processes.first { $0.id == child.processIdentifier })
        let started = try XCTUnwrap(row.startTime)
        let stale = ProcessInfoItem(id: row.id, name: row.name, cpuPercent: 0, memBytes: 0,
                                    startTime: started &+ 1)
        let unverified = ProcessInfoItem(id: row.id, name: row.name, cpuPercent: 0, memBytes: 0)
        for target in [stale, unverified] {
            let outcome = await monitor.terminate(target)
            guard case .refused = outcome else { return XCTFail("Quit accepted an unverified identity") }
            XCTAssertTrue(child.isRunning)
        }

        let outcome = await monitor.terminate(row)
        guard case .exited = outcome else { return XCTFail("Quit failed for the matching child") }
    }
}
