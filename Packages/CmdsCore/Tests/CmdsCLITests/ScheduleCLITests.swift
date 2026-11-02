import XCTest
@testable import cmds_cli
@testable import CmdsCore

/// `cmds schedule …`: argument mapping (times parsed locally, sent as epoch seconds) and the English output.
final class ScheduleCLITests: XCTestCase {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    /// Wednesday 2026-11-04 10:00 in Tokyo.
    private let now = Date(timeIntervalSince1970: 1_793_754_000)

    private func options(_ words: [String], stdin: String = "") throws -> CLI.ScheduleOptions {
        let args = try Arguments(words, options: CLI.scheduleValueOptions, flags: CLI.scheduleFlags)
        return try CLI.parseScheduleOptions(args, now: now, timeZone: tokyo, cwd: "/Users/me/src", readStandardInput: { stdin })
    }

    private func usageError(_ words: [String], _ file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try options(words), file: file, line: line) { error in
            XCTAssertEqual((error as? CLIError)?.code, .usage, file: file, line: line)
        }
    }

    func testOnceAt() throws {
        XCTAssertEqual(try options(["--at", "2026-11-05 02:00"]).trigger,
                       ["type": "once", "at": .number(Date(timeIntervalSince1970: 1_793_811_600).timeIntervalSince1970)])
        // HH:MM: the next such time (tomorrow when it has passed today).
        XCTAssertEqual(try options(["--at", "09:30"]).trigger?["at"], .number(1_793_838_600)) // Thu 09:30
        XCTAssertEqual(try options(["--at", "11:00"]).trigger?["at"], .number(1_793_757_600)) // today 11:00
        XCTAssertEqual(try options(["--in", "90m"]).trigger, ["type": "once", "at": .number(1_793_754_000 + 5400)])
        XCTAssertEqual(try options(["--in", "1h30m"]).trigger?["at"], .number(1_793_754_000 + 5400))
        XCTAssertEqual(try options(["--in", "5s"]).trigger?["at"], .number(1_793_754_005))
        usageError(["--at", "tomorrow"])
        usageError(["--at", "2026-13-01 02:00"])
        usageError(["--in", "90"])
        usageError(["--in", "m"])
        usageError(["--at", "09:00", "--in", "5m"])
    }

    func testWeekly() throws {
        XCTAssertEqual(try options(["--every", "weekdays", "--time", "09:00,13:30", "--tz", "Asia/Tokyo"]).trigger, [
            "type": "weekly", "weekdays": ["mon", "tue", "wed", "thu", "fri"], "times": ["09:00", "13:30"], "timeZone": "Asia/Tokyo",
        ])
        XCTAssertEqual(try options(["--every", "Mon,wednesday,FRI", "--time", "9:05"]).trigger,
                       ["type": "weekly", "weekdays": ["mon", "wed", "fri"], "times": ["09:05"]])
        XCTAssertEqual(try options(["--every", "daily", "--time", "07:00"]).trigger?["weekdays"]?.arrayValue?.count, 7)
        usageError(["--every", "weekdays"])
        usageError(["--every", "funday", "--time", "09:00"])
        usageError(["--every", "mo", "--time", "09:00"])
        usageError(["--every", "daily", "--time", "25:00"])
        usageError(["--every", "daily", "--time", "09:00", "--tz", "Mars/Base"])
        usageError(["--time", "09:00"])
    }

    func testAfterLimit() throws {
        XCTAssertEqual(try options(["--after-limit", "work"]).trigger, ["type": "limitReset", "account": "work", "delay": 60])
        XCTAssertEqual(try options(["--after-limit", "work", "--delay", "2m"]).trigger?["delay"], 120)
        usageError(["--delay", "2m"])
    }

    func testStartWorkspace() throws {
        let parsed = try options(["--start", "app", "--account", "auto", "--title", "Tests", "--prompt", "-",
                                  "--", "claude", "--model", "opus"], stdin: "Run the tests\nand summarise")
        XCTAssertEqual(parsed.start, [
            "type": "startWorkspace", "cwd": "/Users/me/src/app", "account": "auto", "title": "Tests",
            "command": "claude --model opus", "prompt": "Run the tests\nand summarise",
        ])
        XCTAssertNil(parsed.continueTarget)
        XCTAssertEqual(try options(["--start", "~/x", "--", "make bench"]).start?["command"], "make bench")
        XCTAssertEqual(try options(["--start", "/tmp/a/../b"]).start, ["type": "startWorkspace", "cwd": "/tmp/b"])
        usageError(["--start", "/tmp", "--continue"])
        usageError(["--start", "/tmp", "--session", "abc"])
        usageError(["--continue", "--", "claude"])
        usageError(["--continue", "--pane", "p1", "--session", "abc"])
        usageError(["--prompt", "hi"])
        usageError(["--", "make"])
    }

    func testOtherOptions() throws {
        let parsed = try options(["--name", "x", "--late", "skip", "--notify", "always", "--disabled"])
        XCTAssertEqual(parsed.name, "x")
        XCTAssertEqual(parsed.late, ["type": "skip"])
        XCTAssertEqual(parsed.notify, "always")
        XCTAssertEqual(parsed.enabled, false)
        XCTAssertEqual(try options(["--late", "30"]).late, ["type": "runIfWithin", "seconds": 1800])
        usageError(["--late", "soon"])
        usageError(["--notify", "sometimes"])
    }

    func testContinueLooksUpTheSession() throws {
        let session = AgentSession(agent: .claude, sessionID: "6f1c2d3e-0000", cwd: "/Users/me/src/app", account: "work")
        let remote = AgentSession(agent: .claude, sessionID: "remote-1", cwd: "/srv", host: "server")
        let sessions = AgentSessionList(mode: .ask, sessions: [
            AgentSessionEntry(workspace: "w1", pane: "p3", state: .running, session: session, command: nil),
            AgentSessionEntry(workspace: "w2", pane: "p9", state: .running, session: remote, command: nil),
        ])
        XCTAssertEqual(try CLI.continueAction(target: .pane("p3"), pane: "p3", sessions: sessions, account: nil, prompt: nil), [
            // The chosen pane goes along (#55): with two panes holding the session, the prompt goes to this one.
            "type": "continueSession", "agent": "claude", "sessionID": "6f1c2d3e-0000", "cwd": "/Users/me/src/app",
            "pane": "p3",
        ])
        XCTAssertEqual(try CLI.continueAction(target: .session("other"), pane: nil, sessions: sessions, account: "me",
                                              prompt: "go on"),
                       ["type": "continueSession", "agent": "claude", "sessionID": "other", "account": "me", "prompt": "go on"])
        XCTAssertThrowsError(try CLI.continueAction(target: .current, pane: "p5", sessions: sessions, account: nil, prompt: nil))
        XCTAssertThrowsError(try CLI.continueAction(target: .pane("p9"), pane: "p9", sessions: sessions, account: nil, prompt: nil))
        let parsed = try options(["--continue"])
        XCTAssertEqual(parsed.continueTarget, .current)
        XCTAssertEqual(try options(["--continue", "--pane", "p3", "--prompt", "go"]).continueTarget, .pane("p3"))
    }

    func testCommandsAreRegistered() {
        for name in ["schedule", "schedule add", "schedule edit", "schedule show", "schedule enable", "schedule disable",
                     "schedule remove", "schedule run", "schedule cancel", "schedule history", "schedule list", "schedule skip"] {
            XCTAssertTrue(CLI.commands.contains { $0.name == name }, name)
        }
        XCTAssertEqual(CLI.lookup(["schedule"])?.0.name, "schedule")
        XCTAssertEqual(CLI.lookup(["schedule", "add", "--name", "x"])?.0.name, "schedule add")
    }

    // MARK: Output

    private var entry: ScheduleListEntry {
        let draft = ScheduleDraft(name: "Morning tests",
                                  trigger: .weekly(WeeklyRule(weekdays: Weekday.workdays, times: [TimeOfDay("09:00")!],
                                                              timeZone: "Asia/Tokyo")),
                                  action: .startWorkspace(StartWorkspace(cwd: "/tmp/app", account: "work", command: "claude",
                                                                         prompt: "Run the tests")))
        let schedule = Schedule(id: "s1a2b3c4d", draft: draft, origin: .api(pane: "p3"), createdAt: now)
        let last = ScheduleRun(id: "r00000001", scheduleID: "s1a2b3c4d", scheduleName: "Morning tests", cause: .catchUp,
                               dueAt: now.addingTimeInterval(-7200), startedAt: now.addingTimeInterval(-7200),
                               endedAt: now.addingTimeInterval(-7190), state: .succeeded, reason: .confirmed,
                               workspace: "w3", pane: "p7", account: "work")
        return ScheduleListEntry(schedule: schedule, nextFireAt: now.addingTimeInterval(23 * 3600), lastRun: last)
    }

    func testListOutput() {
        XCTAssertEqual(Format.schedules(ScheduleList(schedules: [entry]), now: now, timeZone: tokyo),
                       "s1a2b3c4d  on   Morning tests  weekdays 09:00 (Asia/Tokyo)  →  start /tmp/app (work): claude + prompt"
                       + "  next 2026-11-05 09:00  last succeeded 1 h ago\n")
        XCTAssertEqual(Format.schedules(ScheduleList(schedules: [], readOnly: true), now: now, timeZone: tokyo),
                       "read only: the schedule files were written by a newer cmds or could not be read\n"
                       + "no schedules (add one: cmds schedule add --help)\n")
    }

    func testRunAndTriggerOutput() {
        XCTAssertEqual(Format.scheduleRun(entry.lastRun!, timeZone: tokyo),
                       "r00000001  2026-11-04 08:00  catch-up  succeeded — the agent started working on the prompt  w3 p7 (work)")
        XCTAssertEqual(Format.scheduleTrigger(.limitReset(account: "work", delay: 60)), "when work resets + 1m")
        XCTAssertEqual(Format.scheduleTrigger(.limitReset(account: "work", delay: 0, repeats: true)), "every time work resets")
        XCTAssertEqual(Format.scheduleTrigger(.codexLimitReset(delay: 120)), "when Codex resets + 2m")
        XCTAssertEqual(Format.scheduleTrigger(.codexLimitReset(delay: 60, repeats: true)), "every time Codex resets + 1m")
        XCTAssertEqual(Format.scheduleAction(.sendText(SendText(target: .tag("t1a2b3c4d"), text: "make test", to: .shell))),
                       "send \"make test\" to the shell in pane t1a2b3c4d")
        XCTAssertEqual(Format.scheduleAction(.sendText(SendText(target: .workspace(title: "API"), text: "continue", to: .agent))),
                       "send \"continue\" to the agent in workspace \"API\"")
        XCTAssertEqual(Format.scheduleAction(.continueSession(ContinueSession(agent: .codex, sessionID: "019a2b3c-dddd"))),
                       "continue Codex session 019a2b3c with \"continue\"")
        XCTAssertEqual(Format.scheduleTrigger(.once(at: now), timeZone: tokyo), "once 2026-11-04 10:00")
        XCTAssertEqual(Format.scheduleTrigger(.weekly(WeeklyRule(weekdays: [.fri, .mon], times: [TimeOfDay("13:30")!, TimeOfDay("09:00")!]))),
                       "mon,fri 09:00, 13:30")
        XCTAssertEqual(Format.scheduleAction(.continueSession(ContinueSession(sessionID: "6f1c2d3e-aaaa"))),
                       "continue session 6f1c2d3e with \"continue\"")
        XCTAssertEqual(Format.scheduleAdded(entry, timeZone: tokyo), "s1a2b3c4d  next run 2026-11-05 09:00\n")
        XCTAssertEqual(Format.duration(5400), "1h30m")
        XCTAssertEqual(Format.duration(90), "90s")
        XCTAssertEqual(Format.scheduleHistory([]), "no runs yet\n")
    }

    func testDetails() {
        let text = Format.scheduleDetails(entry, runs: [entry.lastRun!], now: now, timeZone: tokyo)
        XCTAssertTrue(text.hasPrefix("s1a2b3c4d  Morning tests  (on)\nwhen     weekdays 09:00 (Asia/Tokyo)\n"), text)
        XCTAssertTrue(text.contains("command  claude\nprompt   Run the tests\nif late  run when at most 15m late\n"), text)
        XCTAssertTrue(text.contains("origin   api (pane p3)\n"), text)
        XCTAssertTrue(text.contains("notify   failures, 1 minute before\n"), text)
        var send = entry
        send.schedule.action = .sendText(SendText(target: .tag("t1a2b3c4d"), text: "make test", to: .shell))
        send.schedule.warn = false
        send.targetPane = "p4"
        let sendText = Format.scheduleDetails(send, runs: [], now: now, timeZone: tokyo)
        XCTAssertTrue(sendText.contains("target   pane t1a2b3c4d (now p4)\ntext     make test\n"), sendText)
        XCTAssertTrue(sendText.contains("notify   failures\n"), sendText)
    }

    // MARK: Phase 2

    func testSend() throws {
        let parsed = try options(["--send", "make test", "--to", "shell", "--pane", "p3"])
        XCTAssertEqual(parsed.send, CLI.SendOptions(text: "make test", to: .shell, target: .pane("p3")))
        XCTAssertEqual(try CLI.sendAction(parsed.send!, envPane: "p1"), [
            "type": "sendText", "target": ["pane": "p3"], "text": "make test", "to": "shell",
        ])
        // No target: this pane; outside cmds one is required.
        let here = try options(["--send", "-", "--to", "agent"], stdin: "continue\nplease")
        XCTAssertEqual(here.send, CLI.SendOptions(text: "continue\nplease", to: .agent, target: nil))
        XCTAssertEqual(try CLI.sendAction(here.send!, envPane: "p1")["target"], ["pane": "p1"])
        XCTAssertThrowsError(try CLI.sendAction(here.send!, envPane: nil))
        XCTAssertEqual(try options(["--send", "go", "--to", "agent", "--workspace", "API"]).send?.target, .workspace(title: "API"))
        usageError(["--send", "x"])
        usageError(["--send", "x", "--to", "both"])
        usageError(["--send", "x", "--to", "shell", "--pane", "p3", "--workspace", "API"])
        usageError(["--send", "x", "--to", "shell", "--continue"])
        usageError(["--send", "x", "--to", "shell", "--prompt", "y"])
        usageError(["--send", "x", "--to", "shell", "--", "make"])
        usageError(["--to", "shell"])
        usageError(["--workspace", "API", "--continue"])
    }

    func testCodexAndRepeatingTriggers() throws {
        XCTAssertEqual(try options(["--after-codex-limit"]).trigger, ["type": "codexLimitReset", "delay": 60])
        XCTAssertEqual(try options(["--after-codex-limit", "--delay", "5m", "--repeat"]).trigger,
                       ["type": "codexLimitReset", "delay": 300, "repeats": true])
        XCTAssertEqual(try options(["--after-limit", "work", "--repeat"]).trigger,
                       ["type": "limitReset", "account": "work", "delay": 60, "repeats": true])
        usageError(["--repeat"])
        usageError(["--at", "09:00", "--repeat"])
        usageError(["--after-codex-limit", "--after-limit", "work"])
        XCTAssertEqual(try options(["--no-warn"]).warn, false)
        XCTAssertNil(try options([]).warn)
    }

    func testContinueCodex() throws {
        let codex = AgentSession(agent: .codex, sessionID: "019a2b3c-dddd", cwd: "/Users/me/src/app")
        let sessions = AgentSessionList(mode: .ask, sessions: [
            AgentSessionEntry(workspace: "w1", pane: "p3", state: .running, session: codex, command: nil),
        ])
        XCTAssertEqual(try CLI.continueAction(target: .pane("p3"), pane: "p3", sessions: sessions, account: nil, prompt: nil), [
            "type": "continueSession", "agent": "codex", "sessionID": "019a2b3c-dddd", "cwd": "/Users/me/src/app", "pane": "p3",
        ])
        // Codex has no accounts in cmds.
        XCTAssertThrowsError(try CLI.continueAction(target: .pane("p3"), pane: "p3", sessions: sessions, account: "work", prompt: nil))
    }
}
