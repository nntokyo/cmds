import XCTest
@testable import CmdsCore

/// Fake `pmset`: never touches the real power settings.
private final class FakeSleepSystem: SleepDisabledSystem {
    var value: Bool?
    var calls: [Bool] = []
    var failWith: Error?

    init(_ value: Bool?) { self.value = value }

    func readSleepDisabled() -> Bool? { value }

    func setSleepDisabled(_ disabled: Bool) throws {
        calls.append(disabled)
        if let failWith { throw failWith }
        value = disabled
    }
}

private final class MemoryMarkers: LidSleepMarkerStore {
    var exists = false
    var writes = 0
    func write(enabledAt: Date, pid: Int32) throws { exists = true; writes += 1 }
    func remove() { exists = false }
}

final class KeepAwakeCommandTests: XCTestCase {
    func testCommandsAreFixedPmsetInvocations() {
        XCTAssertEqual(SleepDisabledCommand.shellCommand(sleepDisabled: true), "/usr/bin/pmset -a disablesleep 1")
        XCTAssertEqual(SleepDisabledCommand.shellCommand(sleepDisabled: false), "/usr/bin/pmset -a disablesleep 0")
        XCTAssertEqual(SleepDisabledCommand.arguments(sleepDisabled: true), ["-a", "disablesleep", "1"])
        XCTAssertEqual(SleepDisabledCommand.manualRestore, "sudo /usr/bin/pmset -a disablesleep 0")
    }

    func testAppleScriptAsksForAdministratorPrivileges() {
        let on = SleepDisabledCommand.appleScript(sleepDisabled: true)
        XCTAssertTrue(on.hasPrefix("do shell script \"/usr/bin/pmset -a disablesleep 1\" with prompt \""))
        XCTAssertTrue(on.hasSuffix("\" with administrator privileges"))
        XCTAssertFalse(on.contains("password"))
        let off = SleepDisabledCommand.appleScript(sleepDisabled: false)
        XCTAssertTrue(off.hasPrefix("do shell script \"/usr/bin/pmset -a disablesleep 0\""))
        XCTAssertEqual(SleepDisabledCommand.escape(#"a"b\c"#), #"a\"b\\c"#)
    }

    func testParsesPmsetOutput() {
        let on = "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n standby              1\n"
        XCTAssertEqual(SleepDisabledCommand.parseSleepDisabled(pmsetOutput: on), true)
        let off = "System-wide power settings:\n SleepDisabled\t\t0\nCurrently in use:\n"
        XCTAssertEqual(SleepDisabledCommand.parseSleepDisabled(pmsetOutput: off), false)
        let missing = "Currently in use:\n standby              1\n sleep                1\n"
        XCTAssertEqual(SleepDisabledCommand.parseSleepDisabled(pmsetOutput: missing), false)
        XCTAssertNil(SleepDisabledCommand.parseSleepDisabled(pmsetOutput: ""))
        XCTAssertNil(SleepDisabledCommand.parseSleepDisabled(pmsetOutput: "pmset: error"))
    }

    func testStatusRoundTripsAndSnapshotDecodesWithoutIt() throws {
        let status = KeepAwakeStatus(idleAssertion: true, lidCloseDisabled: false, lidCloseByCmds: false)
        let snapshot = StatsSnapshot(system: nil, workspaces: [], keepAwake: status)
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(StatsSnapshot.self, from: data), snapshot)
        let old = try JSONDecoder().decode(StatsSnapshot.self, from: Data(#"{"workspaces":[]}"#.utf8))
        XCTAssertNil(old.keepAwake)
        XCTAssertEqual(status.summary, "idle sleep blocked · closing the lid sleeps")
        XCTAssertTrue(KeepAwakeStatus(idleAssertion: false, lidCloseDisabled: true, lidCloseByCmds: true).summary
            .contains("restored on quit"))
    }
}

final class LidSleepControllerTests: XCTestCase {
    func testEnableAndDisableRunOnePromptEach() throws {
        let system = FakeSleepSystem(false)
        let markers = MemoryMarkers()
        let controller = LidSleepController(isAvailable: true, system: system, markers: markers)
        XCTAssertEqual(controller.refresh(), .off)
        try controller.enable()
        XCTAssertEqual(system.calls, [true])
        XCTAssertTrue(markers.exists)
        XCTAssertEqual(controller.state, .onByCmds)
        try controller.disable()
        XCTAssertEqual(system.calls, [true, false])
        XCTAssertFalse(markers.exists)
        XCTAssertEqual(controller.state, .off)
    }

    func testCancelledEnableLeavesNoMarker() {
        let system = FakeSleepSystem(false)
        system.failWith = LidSleepError.cancelled
        let markers = MemoryMarkers()
        let controller = LidSleepController(isAvailable: true, system: system, markers: markers)
        XCTAssertThrowsError(try controller.enable()) { XCTAssertEqual($0 as? LidSleepError, .cancelled) }
        XCTAssertEqual(markers.writes, 1) // written before the dialog, so a crash during it is noticed next launch
        XCTAssertFalse(markers.exists)
        XCTAssertEqual(controller.state, .off)
    }

    func testNeverTakesOverASettingMadeOutsideCmds() {
        let system = FakeSleepSystem(true)
        let markers = MemoryMarkers()
        let controller = LidSleepController(isAvailable: true, system: system, markers: markers)
        XCTAssertEqual(controller.refresh(), .onOutsideCmds)
        XCTAssertThrowsError(try controller.enable()) {
            XCTAssertEqual($0 as? LidSleepError, .alreadyDisabledOutsideCmds)
        }
        XCTAssertNoThrow(try controller.disable())
        XCTAssertTrue(controller.restoreOnQuit())
        XCTAssertEqual(system.calls, [])
        XCTAssertEqual(controller.launchCheck(), .nothing)
        XCTAssertFalse(controller.shouldOfferTurnOff(onBattery: true))
    }

    func testIsolatedInstanceNeverRunsPmset() {
        let system = FakeSleepSystem(false)
        let markers = MemoryMarkers()
        markers.exists = true // even with a marker lying around
        let controller = LidSleepController(isAvailable: false, system: system, markers: markers)
        XCTAssertThrowsError(try controller.enable()) { XCTAssertEqual($0 as? LidSleepError, .unavailable) }
        XCTAssertNoThrow(try controller.disable())
        XCTAssertTrue(controller.restoreOnQuit())
        XCTAssertEqual(controller.launchCheck(), .nothing)
        XCTAssertEqual(system.calls, [])
    }

    func testQuitRestoresAndKeepsMarkerWhenCancelled() throws {
        let system = FakeSleepSystem(false)
        let markers = MemoryMarkers()
        let controller = LidSleepController(isAvailable: true, system: system, markers: markers)
        try controller.enable()
        system.failWith = LidSleepError.cancelled
        XCTAssertFalse(controller.restoreOnQuit())
        XCTAssertTrue(markers.exists)
        XCTAssertEqual(system.value, true)
        system.failWith = nil
        XCTAssertTrue(controller.restoreOnQuit())
        XCTAssertFalse(markers.exists)
        XCTAssertEqual(system.value, false)
    }

    func testLaunchAfterCrashOffersRestore() throws {
        let system = FakeSleepSystem(true) // left on by a run that was killed
        let markers = MemoryMarkers()
        markers.exists = true
        let controller = LidSleepController(isAvailable: true, system: system, markers: markers)
        XCTAssertEqual(controller.launchCheck(), .offerRestore)
        XCTAssertEqual(controller.state, .onByCmds)
        try controller.disable()
        XCTAssertEqual(system.calls, [false])
        XCTAssertEqual(controller.state, .off)
    }

    func testLaunchClearsStaleMarkerWhenRestoredManually() {
        let system = FakeSleepSystem(false) // user ran sudo pmset -a disablesleep 0
        let markers = MemoryMarkers()
        markers.exists = true
        let controller = LidSleepController(isAvailable: true, system: system, markers: markers)
        XCTAssertEqual(controller.launchCheck(), .clearedStaleMarker)
        XCTAssertFalse(markers.exists)
        XCTAssertEqual(system.calls, [])
    }

    func testDisableWithoutPromptWhenAlreadyRestored() throws {
        let system = FakeSleepSystem(false)
        let markers = MemoryMarkers()
        let controller = LidSleepController(isAvailable: true, system: system, markers: markers)
        try controller.enable()
        system.value = false // restored outside cmds meanwhile
        try controller.disable()
        XCTAssertEqual(system.calls, [true])
        XCTAssertFalse(markers.exists)
    }

    func testBatteryOfferOnlyWhileOwned() throws {
        let system = FakeSleepSystem(false)
        let markers = MemoryMarkers()
        let controller = LidSleepController(isAvailable: true, system: system, markers: markers)
        controller.refresh()
        XCTAssertFalse(controller.shouldOfferTurnOff(onBattery: true))
        try controller.enable()
        XCTAssertTrue(controller.shouldOfferTurnOff(onBattery: true))
        XCTAssertFalse(controller.shouldOfferTurnOff(onBattery: false))
    }

    func testFileMarkerStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-ka-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileLidSleepMarkerStore(url: dir.appendingPathComponent("lid-sleep-disabled.json"))
        XCTAssertFalse(store.exists)
        try store.write(enabledAt: Date(timeIntervalSince1970: 1), pid: 42)
        XCTAssertTrue(store.exists)
        let text = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertTrue(text.contains("sudo /usr/bin/pmset -a disablesleep 0"))
        store.remove()
        XCTAssertFalse(store.exists)
    }
}
