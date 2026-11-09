import XCTest
@testable import CmdsCore

/// Per-process breakdown, leftovers, stopping them and the memory warning (#193).
final class ProcessListTests: XCTestCase {
    private let launch: UInt64 = 1_800_000_000_000_000  // app start, µs since 1970

    private func process(_ pid: Int32, _ workspace: String, _ pane: String?, memory: UInt64, started: UInt64? = nil,
                         command: String? = nil) -> ScannedProcess {
        ScannedProcess(pid: pid, startMicroseconds: started ?? launch + UInt64(pid), name: "proc\(pid)", command: command,
                       workspace: workspace, pane: pane, memoryBytes: memory, cpuPercent: 12.345)
    }

    func testSystemStatsWithoutSwapDecodesAndOmitsIt() throws {
        // As sent by an app from before #193.
        let old = #"{"cpuPercent":12,"memoryUsedBytes":1,"memoryTotalBytes":2,"memoryPressure":2}"#
        let stats = try JSONDecoder().decode(SystemStats.self, from: Data(old.utf8))
        XCTAssertNil(stats.swapUsedBytes)
        XCTAssertNil(stats.swapTotalBytes)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(stats), as: UTF8.self).contains("swap"))

        let withSwap = SystemStats(cpuPercent: 1, memoryUsedBytes: 1, memoryTotalBytes: 2, memoryPressure: 1,
                                   swapUsedBytes: 4_187_593_113, swapTotalBytes: 5_368_709_120)
        XCTAssertEqual(try JSONValue.from(withSwap).decode(SystemStats.self), withSwap)
        XCTAssertEqual(try JSONValue.from(withSwap)["swapTotalBytes"]?.intValue, 5_368_709_120)
    }

    func testProcessEntryDecodesWithoutOptionalKeys() throws {
        let json = #"{"pid":42,"name":"node","workspace":"w1","memoryBytes":1024,"started":1800000000.5}"#
        let entry = try JSONDecoder().decode(ProcessEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.pid, 42)
        XCTAssertNil(entry.pane)
        XCTAssertNil(entry.cpuPercent)
        XCTAssertFalse(entry.isLeftover)
        let list = try JSONDecoder().decode(ProcessList.self, from: Data(#"{"processes":[],"total":0,"totalMemoryBytes":0}"#.utf8))
        XCTAssertEqual(list.total, 0)
    }

    func testBuildSortsMarksLeftoversFiltersAndCuts() {
        let scanned = [
            process(10, "w1", "p1", memory: 100),
            process(11, "w1", "p2", memory: 300),            // pane p2 closed
            process(12, "w2", "p5", memory: 200),            // workspace w2 closed
            process(13, "w1", nil, memory: 50),              // pane unknown: not a leftover while w1 lives
            process(14, "w1", "p1", memory: 400, started: launch - 1),  // ids of an earlier run
        ]
        let live = (panes: Set(["p1"]), workspaces: Set(["w1"]))
        let all = ProcessList.build(scanned, request: ProcessListRequest(), livePanes: live.panes, liveWorkspaces: live.workspaces,
                                    appStarted: launch)
        XCTAssertEqual(all.processes.map(\.pid), [14, 11, 12, 10, 13])
        XCTAssertEqual(all.processes.map(\.isLeftover), [true, true, true, false, false])
        XCTAssertNil(all.processes[3].leftover)  // omitted, not false
        XCTAssertEqual(all.total, 5)
        XCTAssertEqual(all.totalMemoryBytes, 1050)
        XCTAssertEqual(all.processes[0].cpuPercent, 12.3)
        XCTAssertEqual(all.processes[3].started, Double(launch + 10) / 1_000_000, accuracy: 0.000_001)

        let leftovers = ProcessList.build(scanned, request: ProcessListRequest(limit: 2, leftover: true),
                                          livePanes: live.panes, liveWorkspaces: live.workspaces, appStarted: launch)
        XCTAssertEqual(leftovers.processes.map(\.pid), [14, 11])
        XCTAssertEqual(leftovers.total, 3)
        XCTAssertEqual(leftovers.totalMemoryBytes, 900)

        let pane = ProcessList.build(scanned, request: ProcessListRequest(pane: "p1"), livePanes: live.panes,
                                     liveWorkspaces: live.workspaces, appStarted: launch)
        XCTAssertEqual(pane.processes.map(\.pid), [14, 10])
        let workspace = ProcessList.build(scanned, request: ProcessListRequest(workspace: "w2"), livePanes: live.panes,
                                          liveWorkspaces: live.workspaces, appStarted: launch)
        XCTAssertEqual(workspace.processes.map(\.pid), [12])
    }

    func testBuildCutsLongCommands() {
        let long = String(repeating: "x", count: 1000)
        let list = ProcessList.build([process(1, "w1", "p1", memory: 1, command: long)], request: ProcessListRequest(),
                                     livePanes: ["p1"], liveWorkspaces: ["w1"], appStarted: launch)
        XCTAssertEqual(list.processes[0].command?.count, ProcessEntry.maxCommandLength)
        XCTAssertTrue(list.processes[0].command?.hasSuffix("…") == true)
    }

    func testListRequestValidation() throws {
        XCTAssertEqual(try ProcessListRequest(params: nil), ProcessListRequest())
        let request = try ProcessListRequest(params: ["limit": 5, "workspace": "w1", "pane": "p2", "leftover": true])
        XCTAssertEqual(request, ProcessListRequest(limit: 5, workspace: "w1", pane: "p2", leftover: true))
        XCTAssertEqual(try ProcessListRequest(params: .object(request.params.compactMapValues { $0 })), request)
        XCTAssertTrue(ProcessListRequest().params.compactMapValues { $0 }.isEmpty)
        for bad: JSONValue in [["limit": 0], ["limit": 1.5], ["limit": 501], ["limit": "5"], ["workspace": 3],
                               ["pane": ""], ["leftover": "yes"], ["x"]] {
            XCTAssertThrowsError(try ProcessListRequest(params: bad), "\(bad)") { error in
                XCTAssertEqual((error as? RPCError)?.code, RPCError.invalidParams("").code)
            }
        }
    }

    func testKillRequestValidation() throws {
        XCTAssertEqual(try ProcessKillRequest(params: ["pid": 42]), ProcessKillRequest(pid: 42))
        XCTAssertEqual(try ProcessKillRequest(params: ["pid": 42, "force": true, "started": 1_800_000_000.25]),
                       ProcessKillRequest(pid: 42, force: true, started: 1_800_000_000.25))
        for bad: JSONValue in [[:], ["pid": 0], ["pid": -3], ["pid": 1.5], ["pid": "42"], ["pid": 42, "force": 1],
                               ["pid": 42, "started": "now"], ["pid": 1e12]] {
            XCTAssertThrowsError(try ProcessKillRequest(params: bad), "\(bad)")
        }
    }

    func testKillOnlyTheScannedProcessNeverPidOneOrTheApp() throws {
        let scanned = [process(500, "w1", nil, memory: 1)]
        let start = launch + 500
        XCTAssertEqual(try ProcessKillRequest(pid: 500).authorize(scanned: scanned, currentStart: start, ownPID: 99).pid, 500)
        XCTAssertEqual(try ProcessKillRequest(pid: 500, started: Double(start) / 1_000_000)
                        .authorize(scanned: scanned, currentStart: start, ownPID: 99).pid, 500)

        func code(_ request: ProcessKillRequest, currentStart: UInt64?, ownPID: Int32 = 99) -> Int? {
            do {
                _ = try request.authorize(scanned: scanned + [process(1, "w1", nil, memory: 1), process(99, "w1", nil, memory: 1)],
                                          currentStart: currentStart, ownPID: ownPID)
                return nil
            } catch {
                return (error as? RPCError)?.code
            }
        }
        XCTAssertEqual(code(ProcessKillRequest(pid: 1), currentStart: launch + 1), 403)
        XCTAssertEqual(code(ProcessKillRequest(pid: 99), currentStart: launch + 99), 403)       // the app itself
        XCTAssertEqual(code(ProcessKillRequest(pid: 777), currentStart: 5), 403)               // not from cmds
        XCTAssertEqual(code(ProcessKillRequest(pid: 500), currentStart: start + 1), 403)       // pid reused since the scan
        XCTAssertEqual(code(ProcessKillRequest(pid: 500), currentStart: nil), RPCError.notFound("").code)
        XCTAssertEqual(code(ProcessKillRequest(pid: 500, started: 1), currentStart: start), 409)
    }

    func testOriginsStickForTheProcessLifetime() {
        var origins = ProcessOrigins()
        let key = ProcessOrigins.Key(pid: 7, start: 1)
        XCTAssertNil(origins.resolve(key, workspace: nil, pane: nil))
        XCTAssertEqual(origins.resolve(key, workspace: "w1", pane: nil), .init(workspace: "w1"))
        // The pane learnt later fills in.
        XCTAssertEqual(origins.resolve(key, workspace: "w1", pane: "p2"), .init(workspace: "w1", pane: "p2"))
        // After the pane closed the process is found nowhere (or through a reused tty elsewhere): it keeps its origin.
        XCTAssertEqual(origins.resolve(key, workspace: nil, pane: nil), .init(workspace: "w1", pane: "p2"))
        XCTAssertEqual(origins.resolve(key, workspace: "w3", pane: "p9"), .init(workspace: "w1", pane: "p2"))
        // Same pid, other start: another process.
        XCTAssertNil(origins.resolve(.init(pid: 7, start: 2), workspace: nil, pane: nil))
        origins.keep(only: [])
        XCTAssertEqual(origins.count, 0)
    }

    func testPressureAlarmWaitsAMinuteAndRepeatsAtMostEveryHalfHour() {
        var alarm = MemoryPressureAlarm()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(alarm.update(pressure: .warning, now: t0))
        XCTAssertFalse(alarm.update(pressure: .warning, now: t0 + 59))
        XCTAssertTrue(alarm.update(pressure: .critical, now: t0 + 60))
        XCTAssertFalse(alarm.update(pressure: .warning, now: t0 + 120))
        // A normal reading restarts the minute.
        XCTAssertFalse(alarm.update(pressure: .normal, now: t0 + 1700))
        XCTAssertFalse(alarm.update(pressure: .warning, now: t0 + 1790))
        XCTAssertFalse(alarm.update(pressure: .warning, now: t0 + 1849))  // a minute, but within 30 min of the last
        XCTAssertTrue(alarm.update(pressure: .warning, now: t0 + 1860))
        XCTAssertFalse(alarm.update(pressure: .unknown, now: t0 + 4000))
    }

    func testHeavyJobAdvice() {
        func stats(_ level: Int?) -> SystemStats {
            SystemStats(cpuPercent: 0, memoryUsedBytes: 0, memoryTotalBytes: 1, memoryPressure: level)
        }
        XCTAssertEqual(HeavyJobAdvice(stats(1)), .ok)
        XCTAssertEqual(HeavyJobAdvice(stats(2)), .wait)
        XCTAssertEqual(HeavyJobAdvice(stats(4)), .wait)
        XCTAssertEqual(HeavyJobAdvice(stats(nil)), .ok)
        XCTAssertEqual(HeavyJobAdvice(nil), .ok)
    }

    func testAccountantReportsOwnCPUPerProcess() {
        var accountant = ProcessUsageAccountant(cpuCount: 8)
        let first = ProcessUsageSample(pid: 5, parentPID: 1, startTime: 10, group: "w1", cpuTime: 1_000)
        _ = accountant.update(samples: [first], alivePIDs: [5], now: 1_000_000_000)
        XCTAssertTrue(accountant.processCPUPercent.isEmpty)
        var second = first
        second.cpuTime = 1_000 + 500_000_000  // half a second in one second
        second.childCPUTime = 900_000_000     // reaped children are not the process's own
        _ = accountant.update(samples: [second], alivePIDs: [5], now: 2_000_000_000)
        XCTAssertEqual(accountant.processCPUPercent[5] ?? 0, 50, accuracy: 0.001)
    }

    /// The forwarded socket of an SSH pane cannot list or stop the Mac's processes.
    func testRemoteSocketsCannotListOrKill() {
        let scope = RemoteScope(paneID: "p1", workspaceID: "w1")
        for method in ["system.processes", "system.kill_process"] {
            XCTAssertThrowsError(try RemoteAPIPolicy.authorize(method: method, params: ["pid": 42], scope: scope), method) {
                XCTAssertEqual(($0 as? RPCError)?.code, 403)
            }
        }
    }
}
