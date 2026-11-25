import XCTest
@testable import cmds_cli
@testable import CmdsCore

/// `cmds queue list` and `cmds idle`: one line per instruction and per pane.
final class QueueCLITests: XCTestCase {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    func testQueueList() {
        let list = PaneQueueList(
            waiting: [.init(id: "q0000000a", pane: "p3", workspaceTitle: "sales", text: "send the weekly report\nto the CEO",
                            createdAt: "2026-11-25T07:00:00Z", position: 1, hold: .typedInput),
                      .init(id: "q0000000b", pane: "p3", workspaceTitle: "sales", text: "then tidy the folder",
                            createdAt: "2026-11-25T07:01:00Z", position: 2, hold: nil),
                      .init(id: "q0000000c", pane: nil, workspaceTitle: nil, text: "x", createdAt: "2026-11-25T07:02:00Z",
                            position: 1, hold: .paneNotFound),
                      .init(id: "q0000000d", pane: "p9", workspaceTitle: "dev", text: "go", createdAt: "2026-11-25T07:03:00Z",
                            position: 1, hold: nil)],
            recent: [.init(id: "q0000000e", pane: "p3", outcome: .delivered, endedAt: "2026-11-25T06:59:00Z")])
        XCTAssertEqual(Format.queue(list, timeZone: tokyo),
                       "q0000000a  p3  sales  next · waits: its input box holds typed text  send the weekly report to the CEO\n"
                       + "q0000000b  p3  sales  place 2 · behind 1  then tidy the folder\n"
                       + "q0000000c  -  -  next · waits: the pane is not open  x\n"
                       + "q0000000d  p9  dev  next · being typed  go\n"
                       + "  q0000000e  p3  delivered 2026-11-25 15:59\n")
        XCTAssertEqual(Format.queue(PaneQueueList(waiting: [], recent: [])), "nothing waits\n")
        XCTAssertEqual(Format.queue(PaneQueueList(waiting: [], recent: list.recent), timeZone: tokyo),
                       "nothing waits\n  q0000000e  p3  delivered 2026-11-25 15:59\n")
    }

    func testPower() {
        let off = PowerNoticeStatus(settings: .init(), power: .init(onBattery: false, percent: 84))
        XCTAssertEqual(Format.power(off, timeZone: tokyo),
                       "power   power adapter, 84%\nnotice  off (cmds power notice on)\nline    … \(PowerNotice.defaultRequest)\n")
        let on = PowerNoticeStatus(settings: .init(enabled: true, belowPercent: 30, request: "stop cleanly"),
                                   power: .init(onBattery: true, percent: 24), lastEvent: .low,
                                   lastSentAt: "2026-11-25T07:00:00Z", lastPanes: 7)
        XCTAssertEqual(Format.power(on, timeZone: tokyo),
                       "power   battery, 24%\nnotice  on: agents are told when the Mac goes on battery and below 30%\n"
                       + "line    … stop cleanly\nlast    low battery line kept for 7 panes at 2026-11-25 16:00\n")
        let desktop = PowerNoticeStatus(settings: .init(enabled: true), power: .init(onBattery: false, percent: nil),
                                        lastEvent: .onBattery, lastSentAt: "2026-11-25T07:00:00Z", lastPanes: 1)
        XCTAssertTrue(Format.power(desktop, timeZone: tokyo).hasPrefix("power   power adapter (no battery)\n"))
        XCTAssertTrue(Format.power(desktop, timeZone: tokyo).hasSuffix("last    on battery line kept for 1 pane at 2026-11-25 16:00\n"))
        XCTAssertTrue(Format.power(PowerNoticeStatus(settings: .init(), power: nil)).hasPrefix("power   unknown\n"))
    }

    func testIdlePanes() {
        let report = IdlePaneReport(minutes: 30, panes: [
            .init(pane: "p3", workspace: "w1", workspaceTitle: "sales", agent: "claude", state: "idle", idleSeconds: 45 * 60,
                  since: "2026-11-25T06:15:00Z", sinceIsWatchStart: false, queued: 0),
            .init(pane: "p7", workspace: "w2", workspaceTitle: "legal", agent: "codex", state: "needsInput", idleSeconds: 2 * 3600 + 300,
                  since: "2026-11-25T04:55:00Z", sinceIsWatchStart: true, queued: 2),
        ])
        XCTAssertEqual(Format.idlePanes(report, timeZone: tokyo),
                       "p3  sales  claude  idle 45m00s (since 2026-11-25 15:15)\n"
                       + "p7  legal  codex  asks for input ≥2h05m (since 2026-11-25 13:55) · 2 kept instructions waiting\n")
        XCTAssertEqual(Format.idlePanes(IdlePaneReport(minutes: 30, panes: [])), "no pane has been idle for 30 min\n")
    }

    func testCommandsAreListed() {
        let names = Set(CLI.queueCommands.map(\.name))
        XCTAssertEqual(names, ["queue add", "queue list", "queue cancel", "idle", "power", "power notice"])
    }
}
