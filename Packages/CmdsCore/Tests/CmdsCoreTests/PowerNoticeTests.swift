import XCTest
@testable import CmdsCore

final class PowerNoticeTests: XCTestCase {
    private typealias P = PowerNotice
    private let on = P.Settings(enabled: true)

    private func ac(_ percent: Int? = 80) -> P.Power { P.Power(onBattery: false, percent: percent) }
    private func battery(_ percent: Int? = 80) -> P.Power { P.Power(onBattery: true, percent: percent) }

    func testSwitchToBatteryIsToldOnce() {
        var state = P.State()
        XCTAssertNil(P.event(current: ac(), settings: on, state: &state))
        XCTAssertEqual(P.event(current: battery(79), settings: on, state: &state), .onBattery)
        // The charge goes down: nothing more until the level.
        XCTAssertNil(P.event(current: battery(78), settings: on, state: &state))
        XCTAssertNil(P.event(current: battery(25), settings: on, state: &state))
        // Plugged in and out again: told again.
        XCTAssertNil(P.event(current: ac(26), settings: on, state: &state))
        XCTAssertEqual(P.event(current: battery(26), settings: on, state: &state), .onBattery)
    }

    func testNothingAtLaunchOnBatteryAboveTheLevel() {
        var state = P.State()
        XCTAssertNil(P.event(current: battery(60), settings: on, state: &state))
    }

    func testLowIsToldOnceBelowTheLevel() {
        var state = P.State()
        XCTAssertNil(P.event(current: battery(26), settings: on, state: &state))
        XCTAssertEqual(P.event(current: battery(24), settings: on, state: &state), .low)
        XCTAssertNil(P.event(current: battery(23), settings: on, state: &state))
        XCTAssertNil(P.event(current: battery(10), settings: on, state: &state))
        // The reading wobbles around the level: no second line.
        XCTAssertNil(P.event(current: battery(26), settings: on, state: &state))
        XCTAssertNil(P.event(current: battery(24), settings: on, state: &state))
        // Charged and drained again: told again.
        XCTAssertNil(P.event(current: ac(24), settings: on, state: &state))
        XCTAssertNil(P.event(current: ac(60), settings: on, state: &state))
        XCTAssertEqual(P.event(current: battery(60), settings: on, state: &state), .onBattery)
        XCTAssertEqual(P.event(current: battery(24), settings: on, state: &state), .low)
    }

    func testLowAtLaunchAndWhenUnpluggedBelowTheLevel() {
        var state = P.State()
        XCTAssertEqual(P.event(current: battery(20), settings: on, state: &state), .low)
        // Unplugged at 20 %: one line, the low one.
        state = P.State()
        XCTAssertNil(P.event(current: ac(20), settings: on, state: &state))
        XCTAssertEqual(P.event(current: battery(20), settings: on, state: &state), .low)
        XCTAssertNil(P.event(current: battery(19), settings: on, state: &state))
    }

    func testOwnLevel() {
        var state = P.State()
        let at40 = P.Settings(enabled: true, belowPercent: 40)
        XCTAssertNil(P.event(current: battery(40), settings: at40, state: &state))
        XCTAssertEqual(P.event(current: battery(39), settings: at40, state: &state), .low)
    }

    func testOffSendsNothingButKeepsWatching() {
        var state = P.State()
        let off = P.Settings()
        XCTAssertFalse(off.enabled)
        XCTAssertNil(P.event(current: ac(), settings: off, state: &state))
        XCTAssertNil(P.event(current: battery(20), settings: off, state: &state))
        // Turned on while low on battery: told now.
        XCTAssertEqual(P.event(current: battery(20), settings: on, state: &state), .low)
    }

    func testAMacWithoutABatteryIsNeverTold() {
        var state = P.State()
        XCTAssertNil(P.event(current: ac(nil), settings: on, state: &state))
        XCTAssertNil(P.event(current: ac(nil), settings: on, state: &state))
    }

    func testLine() {
        XCTAssertEqual(P.line(.onBattery, power: battery(79), settings: on),
                       "この Mac の電源が電池に切り替わりました（残り 79%）。区切りをつけ、途中の反映を残さず、次の一手を 1 行で記録してください。")
        XCTAssertEqual(P.line(.low, power: battery(24), settings: on),
                       "この Mac の電池の残りが 25% を下回りました（残り 24%、充電されていません）。" + P.defaultRequest)
        XCTAssertEqual(P.line(.onBattery, power: battery(nil), settings: on), "この Mac の電源が電池に切り替わりました。" + P.defaultRequest)
        let own = P.Settings(enabled: true, belowPercent: 30, request: "Stop at a good point.")
        XCTAssertEqual(P.line(.low, power: battery(nil), settings: own),
                       "この Mac の電池の残りが 30% を下回りました（充電されていません）。Stop at a good point.")
        XCTAssertFalse(P.line(.low, power: battery(24), settings: on).contains("\n"))
    }

    func testOneLine() {
        XCTAssertEqual(P.oneLine("  stop\nnow\t please  "), "stop now please")
        XCTAssertNil(P.oneLine(" \n "))
        XCTAssertEqual(P.oneLine(String(repeating: "a", count: 600))?.count, 500)
    }

    func testTargetsAreAgentPanesWithoutALineWaiting() {
        let panes = [P.Candidate(pane: "p1", runsAgent: true, hasPowerLineWaiting: false),
                     P.Candidate(pane: "p2", runsAgent: false, hasPowerLineWaiting: false),
                     P.Candidate(pane: "p3", runsAgent: true, hasPowerLineWaiting: true),
                     P.Candidate(pane: "p4", runsAgent: true, hasPowerLineWaiting: false)]
        XCTAssertEqual(P.targets(panes), ["p1", "p4"])
    }

    func testSettingsFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("power-\(UUID().uuidString)/power-notice.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(P.loadSettings(from: url), P.Settings())
        let saved = P.Settings(enabled: true, belowPercent: 30, request: "stop")
        try P.save(saved, to: url)
        XCTAssertEqual(P.loadSettings(from: url), saved)
        // Odd values fall back; unknown keys are ignored.
        try Data(#"{"enabled": true, "belowPercent": 300, "request": "a\nb", "later": 1}"#.utf8).write(to: url)
        XCTAssertEqual(P.loadSettings(from: url), P.Settings(enabled: true, belowPercent: 25, request: "a b"))
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(P.loadSettings(from: url), P.Settings())
    }
}
