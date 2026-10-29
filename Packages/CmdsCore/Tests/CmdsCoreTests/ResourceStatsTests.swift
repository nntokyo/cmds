import XCTest
@testable import CmdsCore

final class ResourceStatsCodableTests: XCTestCase {
    func testWorkspaceInfoDecodesJSONWithoutUsageFields() throws {
        // As sent by a Mac/app version from before resource usage existed.
        let json = #"""
        {"id":"w1","title":"api","selected":true,"ports":[3000],"attention":false,
         "panes":[{"id":"p1","kind":"terminal","title":"zsh","focused":true,"attention":false}],
         "layout":{"pane":{"id":"p1"}}}
        """#
        let info = try JSONDecoder().decode(WorkspaceInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.id, "w1")
        XCTAssertNil(info.cpuPercent)
        XCTAssertNil(info.memoryBytes)
        XCTAssertEqual(info.panes.count, 1)
    }

    func testWorkspaceInfoOmitsNilUsageAndRoundTripsValues() throws {
        let plain = WorkspaceInfo(id: "w1", title: "t", selected: false)
        let plainJSON = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(plainJSON.contains("cpuPercent"))
        XCTAssertFalse(plainJSON.contains("memoryBytes"))

        let busy = WorkspaceInfo(id: "w2", title: "t", selected: true, cpuPercent: 123.4, memoryBytes: 1_288_490_189)
        let decoded = try JSONDecoder().decode(WorkspaceInfo.self, from: JSONEncoder().encode(busy))
        XCTAssertEqual(decoded, busy)
        // Through the untyped JSON used by the socket API too (numbers become Double there).
        XCTAssertEqual(try JSONValue.from(busy).decode(WorkspaceInfo.self), busy)
    }

    func testStateWithSystemRoundTripsAndOldStateDecodes() throws {
        let codec = SyncCodec()
        let system = SystemStats(cpuPercent: 23.5, memoryUsedBytes: 12_025_908_428, memoryTotalBytes: 17_179_869_184,
                                 memoryPressure: 2)
        let ws = WorkspaceInfo(id: "w1", title: "api", selected: true, cpuPercent: 4.2, memoryBytes: 52_428_800)
        let message = ServerMessage.state(.init(workspaces: [ws], system: system))
        XCTAssertEqual(try codec.decodeServerMessage(codec.encode(message)), message)

        let old = #"{"type":"state","workspaces":[{"id":"w1","title":"a","selected":false,"ports":[],"attention":false,"panes":[]}]}"#
        guard case .state(let state) = try codec.decodeServerMessage(Data(old.utf8)) else { return XCTFail() }
        XCTAssertNil(state.system)
        XCTAssertNil(state.workspaces[0].cpuPercent)

        // Old receivers ignore unknown keys; new optional ones are omitted when nil.
        let withoutSystem = String(decoding: try codec.encode(ServerMessage.state(.init(workspaces: []))), as: UTF8.self)
        XCTAssertEqual(withoutSystem, #"{"type":"state","workspaces":[]}"#)
    }

    func testStatsSnapshotJSONShape() throws {
        let snapshot = StatsSnapshot(
            system: SystemStats(cpuPercent: 10, memoryUsedBytes: 1, memoryTotalBytes: 2, memoryPressure: 1),
            workspaces: [WorkspaceStats(id: "w1", cpuPercent: 1.5, memoryBytes: 3), WorkspaceStats(id: "w2")])
        let value = try JSONValue.from(snapshot)
        XCTAssertEqual(value["system"]?["memoryPressure"]?.intValue, 1)
        XCTAssertEqual(value["workspaces"]?.arrayValue?.count, 2)
        XCTAssertEqual(value["workspaces"]?.arrayValue?[0]["memoryBytes"]?.intValue, 3)
        XCTAssertNil(value["workspaces"]?.arrayValue?[1]["cpuPercent"])
        XCTAssertEqual(try value.decode(StatsSnapshot.self), snapshot)
        XCTAssertNil(try JSONValue.from(StatsSnapshot(system: nil, workspaces: [])).decode(StatsSnapshot.self).system)
    }

    func testMemoryPressureLevels() {
        XCTAssertEqual(MemoryPressure(level: 1), .normal)
        XCTAssertEqual(MemoryPressure(level: 2), .warning)
        XCTAssertEqual(MemoryPressure(level: 4), .critical)
        XCTAssertEqual(MemoryPressure(level: nil), .unknown)
        XCTAssertEqual(MemoryPressure(level: 3).name, "unknown")
        XCTAssertEqual(SystemStats(cpuPercent: 0, memoryUsedBytes: 3, memoryTotalBytes: 4).memoryFraction, 0.75)
        XCTAssertEqual(SystemStats(cpuPercent: 0, memoryUsedBytes: 3, memoryTotalBytes: 0).memoryFraction, 0)
    }
}

final class ResourceFormatTests: XCTestCase {
    func testPercent() {
        XCTAssertEqual(ResourceFormat.percent(0), "0%")
        XCTAssertEqual(ResourceFormat.percent(0.04), "0%")
        XCTAssertEqual(ResourceFormat.percent(0.4), "0.4%")
        XCTAssertEqual(ResourceFormat.percent(9.94), "9.9%")
        XCTAssertEqual(ResourceFormat.percent(9.96), "10%")
        XCTAssertEqual(ResourceFormat.percent(12.4), "12%")
        XCTAssertEqual(ResourceFormat.percent(104.2), "104%")
        XCTAssertEqual(ResourceFormat.percent(.nan), "0%")
        XCTAssertEqual(ResourceFormat.wholePercent(23.4), "23%")
        XCTAssertEqual(ResourceFormat.wholePercent(99.6), "100%")
        XCTAssertEqual(ResourceFormat.wholePercent(-1), "0%")
    }

    func testBytes() {
        let mib: UInt64 = 1024 * 1024
        let gib = mib * 1024
        XCTAssertEqual(ResourceFormat.bytes(0), "0 B")
        XCTAssertEqual(ResourceFormat.bytes(512), "512 B")
        XCTAssertEqual(ResourceFormat.bytes(2048), "2.0 KB")
        XCTAssertEqual(ResourceFormat.bytes(mib * 42 / 10), "4.2 MB")
        XCTAssertEqual(ResourceFormat.bytes(mib * 45), "45 MB")
        XCTAssertEqual(ResourceFormat.bytes(mib * 812), "812 MB")
        XCTAssertEqual(ResourceFormat.bytes(mib * 1000), "1.0 GB") // never four digits
        XCTAssertEqual(ResourceFormat.bytes(gib * 12 / 10), "1.2 GB")
        XCTAssertEqual(ResourceFormat.bytes(gib * 16), "16.0 GB")
        XCTAssertEqual(ResourceFormat.bytes(gib * 128), "128 GB")
    }

    func testMemoryPairAndUsageLine() {
        let gib: UInt64 = 1024 * 1024 * 1024
        XCTAssertEqual(ResourceFormat.memory(used: gib * 112 / 10, total: 17_179_869_184), "11.2 / 16 GB")
        XCTAssertEqual(ResourceFormat.memory(used: gib, total: gib * 3 / 2), "1.0 / 1.5 GB")
        XCTAssertEqual(ResourceFormat.memory(used: 1024, total: 4096), "1.0 KB / 4.0 KB")
        XCTAssertEqual(ResourceFormat.usage(cpuPercent: 12.3, memoryBytes: gib * 12 / 10), "CPU 12% · 1.2 GB")
        XCTAssertEqual(ResourceFormat.usage(cpuPercent: nil, memoryBytes: nil), "CPU – · –")
    }
}

final class ResourceMathTests: XCTestCase {
    func testMachTimeConversion() {
        // Apple Silicon timebase: 24 MHz ticks → 125/3 ns each.
        XCTAssertEqual(MachTime.nanoseconds(24_000_000, numer: 125, denom: 3), 1_000_000_000)
        XCTAssertEqual(MachTime.nanoseconds(3, numer: 125, denom: 3), 125)
        XCTAssertEqual(MachTime.nanoseconds(1_234, numer: 1, denom: 1), 1_234) // Intel
        XCTAssertEqual(MachTime.nanoseconds(5, numer: 0, denom: 0), 5)
        // No overflow for large tick counts (≈ 7 years of CPU time).
        XCTAssertEqual(MachTime.nanoseconds(24_000_000 * 86_400 * 365 * 7, numer: 125, denom: 3),
                       1_000_000_000 * 86_400 * 365 * 7)
        XCTAssertEqual(MachTime.nanoseconds(.max, numer: 125, denom: 3), .max)
    }

    func testCPULoadTicks() {
        let a = CPULoadTicks(user: 100, system: 50, idle: 850, nice: 0)
        let b = CPULoadTicks(user: 160, system: 70, idle: 1_020, nice: 10)
        XCTAssertEqual(try XCTUnwrap(b.busyPercent(since: a)), 90.0 / 260.0 * 100, accuracy: 1e-9)
        XCTAssertNil(a.busyPercent(since: a))
        // 32-bit counters wrap.
        let beforeWrap = CPULoadTicks(user: .max - 9, system: 0, idle: .max - 29, nice: 0)
        let afterWrap = CPULoadTicks(user: 10, system: 0, idle: 30, nice: 0)
        XCTAssertEqual(try XCTUnwrap(afterWrap.busyPercent(since: beforeWrap)), 25, accuracy: 1e-9)
    }

    func testMemoryUsed() {
        XCTAssertEqual(MemoryAccounting.usedBytes(internalPages: 312_791, purgeablePages: 2_237, wiredPages: 136_776,
                                                  compressorPages: 292_077, pageSize: 16_384),
                       (312_791 - 2_237 + 136_776 + 292_077) * 16_384)
        XCTAssertEqual(MemoryAccounting.usedBytes(internalPages: 1, purgeablePages: 5, wiredPages: 2, compressorPages: 3,
                                                  pageSize: 10), 50)
    }
}

final class ProcessUsageAccountantTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000

    private func proc(_ pid: Int32, parent: Int32 = 1, start: UInt64 = 0, group: String = "w1", cpu: Double,
                      children: Double = 0, memory: UInt64 = 0) -> ProcessUsageSample {
        ProcessUsageSample(pid: pid, parentPID: parent, startTime: start, group: group,
                           cpuTime: UInt64(cpu * Double(second)), childCPUTime: UInt64(children * Double(second)),
                           memoryBytes: memory)
    }

    private func pids(_ samples: [ProcessUsageSample], plus extra: [Int32] = []) -> Set<Int32> {
        Set(samples.map(\.pid) + extra)
    }

    func testFirstScanHasMemoryButNoCPU() {
        var accountant = ProcessUsageAccountant(cpuCount: 8)
        let samples = [proc(10, cpu: 5, memory: 100), proc(11, parent: 10, cpu: 1, memory: 50), proc(20, group: "w2", cpu: 0, memory: 7)]
        let usage = accountant.update(samples: samples, alivePIDs: pids(samples), now: 100 * second)
        XCTAssertEqual(usage["w1"], ResourceUsage(cpuPercent: nil, memoryBytes: 150, processCount: 2))
        XCTAssertEqual(usage["w2"], ResourceUsage(cpuPercent: nil, memoryBytes: 7, processCount: 1))
    }

    func testCPUIsDeltaOverWallTimeSummedPerWorkspace() throws {
        var accountant = ProcessUsageAccountant(cpuCount: 8)
        var samples = [proc(10, cpu: 5), proc(11, parent: 10, cpu: 1), proc(20, group: "w2", cpu: 3)]
        _ = accountant.update(samples: samples, alivePIDs: pids(samples), now: 100 * second)
        samples = [proc(10, cpu: 5.5), proc(11, parent: 10, cpu: 3.5), proc(20, group: "w2", cpu: 3.2)]
        let usage = accountant.update(samples: samples, alivePIDs: pids(samples), now: 102 * second)
        // w1: (0.5 + 2.5) s over 2 s = 150 % (more than one core, like Activity Monitor).
        XCTAssertEqual(try XCTUnwrap(usage["w1"]?.cpuPercent), 150, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(usage["w2"]?.cpuPercent), 10, accuracy: 1e-6)
    }

    func testNewProcessCountsFromZeroOnlyIfStartedDuringInterval() throws {
        var accountant = ProcessUsageAccountant(cpuCount: 8)
        let first = [proc(10, cpu: 1)]
        _ = accountant.update(samples: first, alivePIDs: pids(first), now: 100 * second)
        let second = [proc(10, cpu: 1), proc(12, parent: 10, start: 101 * self.second, cpu: 0.4),
                      proc(13, parent: 10, start: 50 * self.second, cpu: 30)] // older but never sampled: no baseline
        let usage = accountant.update(samples: second, alivePIDs: pids(second), now: 102 * self.second)
        XCTAssertEqual(try XCTUnwrap(usage["w1"]?.cpuPercent), 20, accuracy: 1e-6)
        XCTAssertEqual(usage["w1"]?.processCount, 3)
    }

    func testShortLivedChildrenAreCountedThroughParentChildTime() throws {
        var accountant = ProcessUsageAccountant(cpuCount: 8)
        let first = [proc(10, cpu: 1, children: 4)]
        _ = accountant.update(samples: first, alivePIDs: pids(first), now: 100 * second)
        // Children that started and exited between the scans (never sampled) used 1.2 s.
        let second = [proc(10, cpu: 1.1, children: 5.2)]
        let usage = accountant.update(samples: second, alivePIDs: pids(second), now: 102 * self.second)
        XCTAssertEqual(try XCTUnwrap(usage["w1"]?.cpuPercent), 65, accuracy: 1e-6)
    }

    func testSampledChildIsNotCountedTwiceWhenReaped() throws {
        var accountant = ProcessUsageAccountant(cpuCount: 8)
        let first = [proc(10, cpu: 1), proc(11, parent: 10, cpu: 3)]
        _ = accountant.update(samples: first, alivePIDs: pids(first), now: 100 * second)
        // 11 used 0.4 s more, exited and was reaped by 10: 10's child time grows by 11's total (3.4 s).
        let second = [proc(10, cpu: 1.2, children: 3.4)]
        let usage = accountant.update(samples: second, alivePIDs: pids(second), now: 102 * self.second)
        XCTAssertEqual(try XCTUnwrap(usage["w1"]?.cpuPercent), 30, accuracy: 1e-6) // (0.2 + 0.4) / 2
        XCTAssertEqual(usage["w1"]?.processCount, 1)
    }

    func testReapRacingTheScanIsCreditedOnTheNextScan() throws {
        var accountant = ProcessUsageAccountant(cpuCount: 8)
        let first = [proc(10, cpu: 1), proc(11, parent: 10, cpu: 3)]
        _ = accountant.update(samples: first, alivePIDs: pids(first), now: 100 * second)
        // 11 was read (3.5 s), then reaped before the final pid listing; 10 was read before the reap.
        let second = [proc(10, cpu: 1), proc(11, parent: 10, cpu: 3.5)]
        var usage = accountant.update(samples: second, alivePIDs: [10], now: 102 * self.second)
        XCTAssertEqual(try XCTUnwrap(usage["w1"]?.cpuPercent), 0, accuracy: 1e-6)
        XCTAssertEqual(usage["w1"]?.processCount, 1)
        // The reap now shows in 10's child time (11's total 3.6 s); the 3 s counted before are credited,
        // so 11's last 0.6 s (0.5 s seen in the race + 0.1 s unseen) arrive here, nothing twice.
        let third = [proc(10, cpu: 1, children: 3.6)]
        usage = accountant.update(samples: third, alivePIDs: pids(third), now: 104 * self.second)
        XCTAssertEqual(try XCTUnwrap(usage["w1"]?.cpuPercent), 30, accuracy: 1e-6)
    }

    func testNestedRaceWhereTheMiddleProcessDiesDuringTheScan() throws {
        var accountant = ProcessUsageAccountant(cpuCount: 8)
        let first = [proc(10, cpu: 1), proc(11, parent: 10, cpu: 1), proc(12, parent: 11, cpu: 3)]
        _ = accountant.update(samples: first, alivePIDs: pids(first), now: 100 * second)
        // 12 (+1 s) was reaped by 11 before the scan; 11 (+1 s) was read, then exited and was reaped by 10.
        let second = [proc(10, cpu: 1), proc(11, parent: 10, cpu: 2, children: 4)]
        var usage = accountant.update(samples: second, alivePIDs: [10], now: 102 * self.second)
        XCTAssertEqual(try XCTUnwrap(usage["w1"]?.cpuPercent), 0, accuracy: 1e-6)
        let third = [proc(10, cpu: 1, children: 6)]
        usage = accountant.update(samples: third, alivePIDs: pids(third), now: 104 * self.second)
        XCTAssertEqual(try XCTUnwrap(usage["w1"]?.cpuPercent), 100, accuracy: 1e-6) // the 2 s new CPU, once
    }

    func testNestedDeparturesCreditTheNearestLiveAncestor() throws {
        var accountant = ProcessUsageAccountant(cpuCount: 8)
        // shell 10 → make 11 → cc 12
        let first = [proc(10, cpu: 1), proc(11, parent: 10, cpu: 1), proc(12, parent: 11, cpu: 3)]
        _ = accountant.update(samples: first, alivePIDs: pids(first), now: 100 * second)
        // cc used 1 s more and was reaped by make (+4 s child time); make used 1 s more, exited and was reaped
        // by the shell, whose child time grows by make's total: 2 s own + 4 s children.
        let second = [proc(10, cpu: 1, children: 6)]
        let usage = accountant.update(samples: second, alivePIDs: pids(second), now: 102 * self.second)
        XCTAssertEqual(try XCTUnwrap(usage["w1"]?.cpuPercent), 100, accuracy: 1e-6) // (1 + 1) / 2
    }

    func testOrphansAndForeignParentsAreNotCredited() throws {
        var accountant = ProcessUsageAccountant(cpuCount: 8)
        // 11's parent (500) is not a workspace process (e.g. login, launchd after reparenting).
        let first = [proc(10, cpu: 1), proc(11, parent: 500, cpu: 9)]
        _ = accountant.update(samples: first, alivePIDs: pids(first), now: 100 * second)
        let second = [proc(10, cpu: 1, children: 2)]
        let usage = accountant.update(samples: second, alivePIDs: pids(second, plus: [500]), now: 102 * self.second)
        XCTAssertEqual(try XCTUnwrap(usage["w1"]?.cpuPercent), 100, accuracy: 1e-6)
    }

    func testUnusedCreditsExpire() throws {
        var accountant = ProcessUsageAccountant(cpuCount: 8)
        let first = [proc(10, cpu: 1), proc(11, parent: 10, cpu: 50)]
        _ = accountant.update(samples: first, alivePIDs: pids(first), now: 100 * second)
        // 11 vanished but was never reaped by 10 (orphaned to launchd in the same interval).
        var samples = [proc(10, cpu: 1)]
        _ = accountant.update(samples: samples, alivePIDs: pids(samples), now: 102 * second)
        samples = [proc(10, cpu: 1)]
        _ = accountant.update(samples: samples, alivePIDs: pids(samples), now: 104 * second)
        // Two scans later the 50 s credit is gone: real child time counts again.
        samples = [proc(10, cpu: 1, children: 1)]
        let usage = accountant.update(samples: samples, alivePIDs: pids(samples), now: 106 * second)
        XCTAssertEqual(try XCTUnwrap(usage["w1"]?.cpuPercent), 50, accuracy: 1e-6)
    }

    func testPIDReuseIsANewProcess() throws {
        var accountant = ProcessUsageAccountant(cpuCount: 8)
        let first = [proc(10, cpu: 1), proc(11, parent: 10, start: 10 * second, cpu: 7)]
        _ = accountant.update(samples: first, alivePIDs: pids(first), now: 100 * second)
        // Old 11 (7 s) exited and was reaped by 10; a new process got pid 11 and used 0.5 s.
        let second = [proc(10, cpu: 1, children: 7), proc(11, parent: 10, start: 101 * self.second, cpu: 0.5)]
        let usage = accountant.update(samples: second, alivePIDs: pids(second), now: 102 * self.second)
        XCTAssertEqual(try XCTUnwrap(usage["w1"]?.cpuPercent), 25, accuracy: 1e-6)
    }

    func testCPUIsCappedAtAllCores() throws {
        var accountant = ProcessUsageAccountant(cpuCount: 4)
        let first = [proc(10, cpu: 0)]
        _ = accountant.update(samples: first, alivePIDs: pids(first), now: 100 * second)
        // A long-lived child without CMDS_WORKSPACE_ID (never sampled) is reaped: one-off 600 s burst.
        let second = [proc(10, cpu: 0, children: 600)]
        let usage = accountant.update(samples: second, alivePIDs: pids(second), now: 102 * self.second)
        XCTAssertEqual(usage["w1"]?.cpuPercent, 400)
    }
}

final class CmdsEnvTests: XCTestCase {
    func testSupportDirectoryOverridesSocketPath() {
        XCTAssertEqual(CmdsEnv.defaultSocketPath(environment: ["CMDS_SUPPORT_DIR": "/tmp/cmds-test"]), "/tmp/cmds-test/cmds.sock")
        // An inherited CMDS_SOCKET_PATH (live app's terminal) must not win over an isolated support dir.
        XCTAssertEqual(CmdsEnv.defaultSocketPath(environment: ["CMDS_SUPPORT_DIR": "/tmp/cmds-test",
                                                               "CMDS_SOCKET_PATH": "/live/cmds.sock"]),
                       "/tmp/cmds-test/cmds.sock")
        XCTAssertEqual(CmdsEnv.defaultSocketPath(environment: ["CMDS_SOCKET_PATH": "/live/cmds.sock"]), "/live/cmds.sock")
        XCTAssertTrue(CmdsEnv.defaultSocketPath(environment: [:]).hasSuffix("Library/Application Support/cmds/cmds.sock"))
        XCTAssertEqual(CmdsEnv.supportDirectoryURL(environment: ["CMDS_SUPPORT_DIR": "/tmp/x/../y"]).path, "/tmp/y")
        XCTAssertNil(CmdsEnv.supportDirectoryOverride(environment: ["CMDS_SUPPORT_DIR": "  "]))
        XCTAssertEqual(CmdsEnv.supportDirectoryOverride(environment: ["CMDS_SUPPORT_DIR": "~/t"]), NSHomeDirectory() + "/t")
    }

    func testSyncDisabledFlag() {
        XCTAssertTrue(CmdsEnv.isSyncDisabled(environment: ["CMDS_SYNC_DISABLED": "1"]))
        XCTAssertTrue(CmdsEnv.isSyncDisabled(environment: ["CMDS_SYNC_DISABLED": "TRUE"]))
        XCTAssertFalse(CmdsEnv.isSyncDisabled(environment: ["CMDS_SYNC_DISABLED": "0"]))
        XCTAssertFalse(CmdsEnv.isSyncDisabled(environment: [:]))
    }
}
