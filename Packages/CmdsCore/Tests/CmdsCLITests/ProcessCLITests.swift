import XCTest
@testable import cmds_cli
@testable import CmdsCore

/// `cmds stats` swap, `cmds top`, `cmds kill` (#193).
final class ProcessCLITests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    func testStatsShowsSwapWhenTheAppSendsIt() {
        var system = SystemStats(cpuPercent: 23, memoryUsedBytes: 12_025_908_428, memoryTotalBytes: 17_179_869_184,
                                 memoryPressure: 2)
        let old = Format.stats(StatsSnapshot(system: system, workspaces: []), titles: [:], currentWorkspace: nil)
        XCTAssertEqual(old, "system  CPU  23%  memory 11.2 / 16 GB  pressure warning\nno workspaces\n")
        system.swapUsedBytes = 4_187_593_113
        system.swapTotalBytes = 5_368_709_120
        XCTAssertEqual(Format.stats(StatsSnapshot(system: system, workspaces: []), titles: [:], currentWorkspace: nil),
                       "system  CPU  23%  memory 11.2 / 16 GB  swap 3.9 / 5 GB  pressure warning\nno workspaces\n")
        system.swapUsedBytes = 0
        system.swapTotalBytes = 0
        XCTAssertEqual(Format.swap(system), "0 B")
    }

    func testTopTable() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15 08:00 UTC
        let list = ProcessList(processes: [
            ProcessEntry(pid: 4321, name: "node", command: "node server.js", pane: "p3", workspace: "w1",
                         memoryBytes: 1_288_490_189, cpuPercent: 12.5, started: 1_799_996_400),
            ProcessEntry(pid: 99, name: "sleep", command: "sleep 9999", pane: "p8", workspace: "w2",
                         memoryBytes: 1_048_576, started: 1_799_800_000, leftover: true),
        ], total: 5, totalMemoryBytes: 1_400_000_000)
        XCTAssertEqual(Format.processes(list, titles: ["w1": "api"], currentPane: "p3", now: now, timeZone: utc), """
             PID  MEMORY  CPU  PANE  WORKSPACE      START   COMMAND
            4321  1.2 GB  12%  >p3   w1 api         07:00   node server.js
              99  1.0 MB    –  p8    w2 (leftover)  Jan 13  sleep 9999
            5 processes · 1.3 GB (2 shown)

            """)
        XCTAssertEqual(Format.processes(ProcessList(processes: [], total: 0, totalMemoryBytes: 0), titles: [:], currentPane: nil),
                       "no processes started from cmds terminals\n")
    }

    func testTopAndKillArguments() {
        // Bad arguments fail before the app is asked (exit code 2), whatever socket is given.
        let socket = ["--socket", "/nonexistent/cmds.sock"]
        XCTAssertEqual(CLI.main(["top", "--limit", "0"] + socket, environment: [:]), 2)
        XCTAssertEqual(CLI.main(["top", "--limit", "501"] + socket, environment: [:]), 2)
        XCTAssertEqual(CLI.main(["top", "extra"] + socket, environment: [:]), 2)
        XCTAssertEqual(CLI.main(["kill"] + socket, environment: [:]), 2)
        XCTAssertEqual(CLI.main(["kill", "abc"] + socket, environment: [:]), 2)
        XCTAssertEqual(CLI.main(["kill", "0"] + socket, environment: [:]), 2)
        // Valid ones reach for the app (not running: exit code 3).
        XCTAssertEqual(CLI.main(["top", "--leftover", "--limit", "5"] + socket, environment: [:]), 3)
        XCTAssertEqual(CLI.main(["kill", "4321", "--force"] + socket, environment: [:]), 3)
    }
}
