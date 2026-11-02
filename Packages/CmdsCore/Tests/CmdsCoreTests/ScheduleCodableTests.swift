import XCTest
@testable import CmdsCore

final class ScheduleCodableTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_793_000_000)

    private var morning: Schedule {
        let draft = ScheduleDraft(name: "Morning tests",
                                  trigger: .weekly(WeeklyRule(weekdays: Weekday.workdays, times: [TimeOfDay("09:00")!],
                                                              timeZone: "Asia/Tokyo")),
                                  action: .startWorkspace(StartWorkspace(cwd: "~/src/app", account: "work", command: "claude",
                                                                         prompt: "Run the test suite and summarise failures")))
        return Schedule(id: "s1a2b3c4d", draft: draft, origin: .api(pane: "p3"), createdAt: created,
                        nextFireAt: Date(timeIntervalSince1970: 1_793_059_200))
    }

    private var continuing: Schedule {
        let draft = ScheduleDraft(name: "Continue after reset", trigger: .limitReset(account: "work", delay: 120),
                                  action: .continueSession(ContinueSession(sessionID: "6f1c2d3e-aaaa-bbbb-cccc-000000000001",
                                                                           cwd: "/Users/me/src/app")),
                                  late: .skip, notify: .always)
        return Schedule(id: "s00000001", draft: draft, origin: .app, createdAt: created)
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }

    func testRoundTrip() throws {
        let once = Schedule(id: "sabcdef01", draft: ScheduleDraft(name: "bench", enabled: false, trigger: .once(at: created),
                                                                   action: .startWorkspace(StartWorkspace(cwd: "/tmp", command: "make bench"))),
                            origin: .api(pane: nil), createdAt: created)
        let file = ScheduleFile(schedules: [morning, continuing, once])
        let decoded = try JSONDecoder().decode(ScheduleFile.self, from: JSONEncoder().encode(file))
        XCTAssertEqual(decoded, file)
        XCTAssertEqual(decoded.dropped, 0)
        XCTAssertFalse(decoded.isFromNewerVersion)
    }

    func testFileFormat() throws {
        let object = try json(morning)
        XCTAssertEqual(object["createdAt"] as? Double, 1_793_000_000)
        XCTAssertEqual(object["nextFireAt"] as? Double, 1_793_059_200)
        XCTAssertEqual(object["notify"] as? String, "failures")
        let trigger = object["trigger"] as? [String: Any]
        XCTAssertEqual(trigger?["type"] as? String, "weekly")
        XCTAssertEqual(trigger?["weekdays"] as? [String], ["mon", "tue", "wed", "thu", "fri"])
        XCTAssertEqual(trigger?["times"] as? [String], ["09:00"])
        XCTAssertEqual(trigger?["timeZone"] as? String, "Asia/Tokyo")
        let action = object["action"] as? [String: Any]
        XCTAssertEqual(action?["type"] as? String, "startWorkspace")
        XCTAssertEqual(action?["cwd"] as? String, "~/src/app")
        XCTAssertEqual((object["late"] as? [String: Any])?["type"] as? String, "runIfWithin")
        XCTAssertEqual((object["late"] as? [String: Any])?["seconds"] as? Double, 900)
        XCTAssertEqual((object["origin"] as? [String: Any])?["type"] as? String, "api")
        XCTAssertEqual((object["origin"] as? [String: Any])?["pane"] as? String, "p3")
        let other = try json(continuing)
        XCTAssertEqual((other["trigger"] as? [String: Any])?["delay"] as? Double, 120)
        XCTAssertEqual((other["action"] as? [String: Any])?["agent"] as? String, "claude")
        XCTAssertEqual((other["late"] as? [String: Any])?["type"] as? String, "skip")
        XCTAssertNil(other["nextFireAt"])
    }

    func testTheDesignsExampleDecodes() throws {
        let text = """
            { "version": 1,
              "schedules": [{
                "id": "s1a2b3c4d", "name": "Morning tests", "enabled": true,
                "trigger": {"type": "weekly", "weekdays": ["mon","tue","wed","thu","fri"], "times": ["09:00"], "timeZone": "Asia/Tokyo"},
                "action": {"type": "startWorkspace", "cwd": "~/src/app", "account": "work", "command": "claude",
                           "prompt": "Run the test suite and summarise failures"},
                "late": {"type": "runIfWithin", "seconds": 900}, "notify": "failures",
                "origin": {"type": "api", "pane": "p3"}, "createdAt": 1793000000, "nextFireAt": 1793059200,
                "someFutureKey": true }]}
            """
        let file = try JSONDecoder().decode(ScheduleFile.self, from: Data(text.utf8))
        XCTAssertEqual(file.schedules, [morning])
    }

    func testLenientDecodingDropsOnlyBadSchedules() throws {
        let text = """
            {"version": 1, "schedules": [
              {"id": "s00000001", "name": "ok", "trigger": {"type": "once", "at": 1793000000},
               "action": {"type": "startWorkspace", "cwd": "/tmp"}},
              {"id": "s00000002", "name": "future trigger", "trigger": {"type": "monthly", "day": 1},
               "action": {"type": "startWorkspace", "cwd": "/tmp"}},
              {"id": "s00000003", "name": "future action", "trigger": {"type": "once", "at": 1793000000},
               "action": {"type": "sendText", "pane": "p1"}},
              {"id": "s00000004", "name": "", "trigger": {"type": "once", "at": 1793000000},
               "action": {"type": "startWorkspace", "cwd": "/tmp"}},
              {"id": "bad", "name": "bad id", "trigger": {"type": "once", "at": 1793000000},
               "action": {"type": "startWorkspace", "cwd": "/tmp"}},
              {"id": "s00000001", "name": "duplicate id", "trigger": {"type": "once", "at": 1793000000},
               "action": {"type": "startWorkspace", "cwd": "/tmp"}},
              {"id": "s00000005", "name": "escape in prompt", "trigger": {"type": "once", "at": 1793000000},
               "action": {"type": "startWorkspace", "cwd": "/tmp", "command": "claude", "prompt": "hi\\u001b[201~rm -rf"}},
              42
            ]}
            """
        let file = try JSONDecoder().decode(ScheduleFile.self, from: Data(text.utf8))
        XCTAssertEqual(file.schedules.map(\.name), ["ok"])
        XCTAssertEqual(file.dropped, 7)
        // Defaults for what was left out.
        let ok = file.schedules[0]
        XCTAssertTrue(ok.enabled)
        XCTAssertEqual(ok.late, .runIfWithin(6 * 3600))
        XCTAssertEqual(ok.notify, .failures)
        XCTAssertEqual(ok.origin, .app)
    }

    func testNewerVersionIsReadOnly() throws {
        let text = #"{"version": 2, "schedules": [], "runs": []}"#
        XCTAssertTrue(try JSONDecoder().decode(ScheduleFile.self, from: Data(text.utf8)).isFromNewerVersion)
        XCTAssertTrue(try JSONDecoder().decode(ScheduleRunsFile.self, from: Data(text.utf8)).isFromNewerVersion)
        XCTAssertFalse(try JSONDecoder().decode(ScheduleFile.self, from: Data(#"{"schedules": []}"#.utf8)).isFromNewerVersion)
    }

    func testRuns() throws {
        let run = ScheduleRun(id: "r00000001", scheduleID: "s00000001", scheduleName: "x", cause: .catchUp,
                              dueAt: created, startedAt: created.addingTimeInterval(5), endedAt: created.addingTimeInterval(9),
                              state: .succeeded, reason: .confirmed, workspace: "w3", pane: "p7", account: "work")
        let file = ScheduleRunsFile(runs: [run])
        XCTAssertEqual(try JSONDecoder().decode(ScheduleRunsFile.self, from: JSONEncoder().encode(file)), file)
        let object = try json(run)
        XCTAssertEqual(object["reason"] as? String, "confirmed")
        XCTAssertEqual(object["state"] as? String, "succeeded")
        XCTAssertEqual(object["dueAt"] as? Double, 1_793_000_000)
        // A reason from a newer cmds; a run without a state is dropped.
        let text = """
            {"version": 1, "runs": [
              {"id": "r1", "scheduleID": "s1", "state": "failed", "dueAt": 1793000000, "reason": "somethingNew"},
              {"id": "r2", "scheduleID": "s1", "dueAt": 1793000000}
            ]}
            """
        let runs = try JSONDecoder().decode(ScheduleRunsFile.self, from: Data(text.utf8)).runs
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].reason, .other)
        XCTAssertEqual(runs[0].scheduleName, "s1")
    }

    func testStoreMovesADamagedFileAsideAndWritesPrivately() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-schedule-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = ScheduleStore.url(supportDirectory: directory)
        guard case .missing = StoredFile.load(ScheduleFile.self, from: url) else { return XCTFail("expected missing") }
        try ScheduleStore.save(ScheduleFile(schedules: [morning]), to: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        guard case .loaded(let loaded) = StoredFile.load(ScheduleFile.self, from: url) else { return XCTFail("expected loaded") }
        XCTAssertEqual(loaded.schedules, [morning])
        try Data("{not json".utf8).write(to: url)
        guard case .unreadable(_, .success(let moved)) = StoredFile.load(ScheduleFile.self, from: url) else {
            return XCTFail("expected moved aside")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "{not json")
    }

    func testHistoryRetention() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func run(_ n: Int, schedule: String, age: TimeInterval) -> ScheduleRun {
            ScheduleRun(id: String(format: "r%08x", n), scheduleID: schedule, scheduleName: schedule, cause: .scheduled,
                        dueAt: now.addingTimeInterval(-age), startedAt: now.addingTimeInterval(-age),
                        endedAt: now.addingTimeInterval(-age), state: .succeeded)
        }
        // 60 runs of one schedule: the newest 50 stay.
        let many = (0..<60).map { run($0, schedule: "s00000001", age: TimeInterval($0) * 60) }
        let kept = ScheduleHistory.trimmed(many.shuffled(), now: now)
        XCTAssertEqual(kept.count, 50)
        XCTAssertEqual(kept.first?.id, many[0].id)
        XCTAssertEqual(kept.last?.id, many[49].id)
        // 400 runs over 10 schedules: 300 in all.
        let spread = (0..<400).map { run($0, schedule: "s0000000\($0 % 10)", age: TimeInterval($0)) }
        XCTAssertEqual(ScheduleHistory.trimmed(spread, now: now).count, 300)
        // Older than 90 days: dropped.
        XCTAssertEqual(ScheduleHistory.trimmed([run(1, schedule: "s1", age: 91 * 86400), run(2, schedule: "s1", age: 89 * 86400)],
                                               now: now).map(\.id), [String(format: "r%08x", 2)])
    }

    func testIDs() {
        let id = ScheduleIDs.make(prefix: "s")
        XCTAssertTrue(ScheduleIDs.isValid(id, prefix: "s"), id)
        XCTAssertFalse(ScheduleIDs.isValid("s1234567", prefix: "s"))
        XCTAssertFalse(ScheduleIDs.isValid("s1234567G", prefix: "s"))
        XCTAssertFalse(ScheduleIDs.isValid("sABCDEF01", prefix: "s"))
        XCTAssertFalse(ScheduleIDs.isValid("r12345678", prefix: "s"))
    }
}

final class ScheduleValidationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)
    private let start = ScheduleAction.startWorkspace(StartWorkspace(cwd: "/tmp"))

    private func draft(_ trigger: ScheduleTrigger, _ action: ScheduleAction? = nil, name: String = "x",
                       late: ScheduleLatePolicy? = nil) -> ScheduleDraft {
        ScheduleDraft(name: name, trigger: trigger, action: action ?? start, late: late)
    }

    private func weekly(_ times: [String], days: Set<Weekday> = [.mon], zone: String? = nil) -> ScheduleTrigger {
        .weekly(WeeklyRule(weekdays: days, times: times.compactMap(TimeOfDay.init), timeZone: zone))
    }

    func testValidSchedulesPass() {
        XCTAssertEqual(ScheduleValidation.problems(draft(.once(at: now))), [])
        XCTAssertEqual(ScheduleValidation.problems(draft(weekly(["09:00", "13:30"], zone: "Asia/Tokyo"))), [])
        let full = ScheduleAction.startWorkspace(StartWorkspace(cwd: "~/src/app", title: "Tests", account: "auto",
                                                                command: "claude", prompt: "Line one\n\tline two"))
        XCTAssertEqual(ScheduleValidation.problems(draft(.once(at: now), full)), [])
    }

    func testName() {
        XCTAssertEqual(ScheduleValidation.problems(draft(.once(at: now), name: " ")), [.nameInvalid])
        XCTAssertEqual(ScheduleValidation.problems(draft(.once(at: now), name: String(repeating: "a", count: 65))), [.nameInvalid])
        XCTAssertEqual(ScheduleValidation.problems(draft(.once(at: now), name: "a\nb")), [.nameInvalid])
        XCTAssertEqual(ScheduleValidation.problems(draft(.once(at: now), name: String(repeating: "あ", count: 64))), [])
    }

    func testWeeklyRules() {
        XCTAssertEqual(ScheduleValidation.problems(draft(weekly(["09:00"], days: []))), [.noWeekdays])
        XCTAssertEqual(ScheduleValidation.problems(draft(weekly([]))), [.timesCount])
        let every30 = (0..<25).map { String(format: "%02d:%02d", $0 / 2, ($0 % 2) * 30) }
        XCTAssertEqual(ScheduleValidation.problems(draft(weekly(every30))), [.timesCount])
        XCTAssertEqual(ScheduleValidation.problems(draft(weekly(["09:00", "09:04"]))), [.timesTooClose])
        XCTAssertEqual(ScheduleValidation.problems(draft(weekly(["09:00", "09:05"]))), [])
        // Across midnight.
        XCTAssertEqual(ScheduleValidation.problems(draft(weekly(["23:58", "00:02"]))), [.timesTooClose])
        XCTAssertEqual(ScheduleValidation.problems(draft(weekly(["09:00"], zone: "Mars/Base"))), [.unknownTimeZone("Mars/Base")])
    }

    func testLimitResetAndLate() {
        XCTAssertEqual(ScheduleValidation.problems(draft(.limitReset(account: "work", delay: 3601))), [.delayOutOfRange])
        XCTAssertEqual(ScheduleValidation.problems(draft(.limitReset(account: "work", delay: -1))), [.delayOutOfRange])
        XCTAssertEqual(ScheduleValidation.problems(draft(.limitReset(account: "auto", delay: 60))), [.accountInvalid("auto")])
        XCTAssertEqual(ScheduleValidation.problems(draft(.once(at: now), late: .runIfWithin(30))), [.lateOutOfRange])
        XCTAssertEqual(ScheduleValidation.problems(draft(.once(at: now), late: .runIfWithin(8 * 86400))), [.lateOutOfRange])
        XCTAssertEqual(ScheduleValidation.problems(draft(.once(at: now), late: .skip)), [])
    }

    func testStartWorkspace() {
        func problems(_ action: StartWorkspace) -> [ScheduleProblem] {
            ScheduleValidation.problems(draft(.once(at: now), .startWorkspace(action)))
        }
        XCTAssertEqual(problems(StartWorkspace(cwd: "src/app")), [.folderInvalid])
        XCTAssertEqual(problems(StartWorkspace(cwd: "/tmp", title: "a\u{7}")), [.titleInvalid])
        XCTAssertEqual(problems(StartWorkspace(cwd: "/tmp", command: "echo a\nrm -rf ~")), [.commandInvalid])
        XCTAssertEqual(problems(StartWorkspace(cwd: "/tmp", command: "echo \u{1b}[31m")), [.commandInvalid])
        XCTAssertEqual(problems(StartWorkspace(cwd: "/tmp", command: String(repeating: "a", count: 1025))), [.commandInvalid])
        XCTAssertEqual(problems(StartWorkspace(cwd: "/tmp", command: "  ")), [.commandInvalid])
        XCTAssertEqual(problems(StartWorkspace(cwd: "/tmp", prompt: "hi")), [.promptWithoutCommand])
        XCTAssertEqual(problems(StartWorkspace(cwd: "/tmp", command: "claude", prompt: "hi\u{1b}[201~")), [.promptInvalid])
        XCTAssertEqual(problems(StartWorkspace(cwd: "/tmp", command: "claude", prompt: "\n ")), [.promptInvalid])
        XCTAssertEqual(problems(StartWorkspace(cwd: "/tmp", command: "claude", prompt: String(repeating: "a", count: 8193))),
                       [.promptTooLong])
        XCTAssertEqual(problems(StartWorkspace(cwd: "/tmp", command: "claude", prompt: String(repeating: "a", count: 8192))), [])
        XCTAssertEqual(problems(StartWorkspace(cwd: "/tmp", account: "bad name")), [.accountInvalid("bad name")])
    }

    /// Boundaries and character classes kept when the checks got named limits and one control-character test (#47).
    func testBoundariesAndControlCharacters() {
        XCTAssertEqual(ScheduleValidation.problems(draft(.once(at: now), late: .runIfWithin(59))), [.lateOutOfRange])
        XCTAssertEqual(ScheduleValidation.problems(draft(.once(at: now), late: .runIfWithin(60))), [])
        XCTAssertEqual(ScheduleValidation.problems(draft(.once(at: now), late: .runIfWithin(7 * 86400))), [])
        func problems(_ action: StartWorkspace) -> [ScheduleProblem] {
            ScheduleValidation.problems(draft(.once(at: now), .startWorkspace(action)))
        }
        XCTAssertEqual(problems(StartWorkspace(cwd: "/" + String(repeating: "a", count: 1023))), [])
        XCTAssertEqual(problems(StartWorkspace(cwd: "/" + String(repeating: "a", count: 1024))), [.folderInvalid])
        XCTAssertEqual(problems(StartWorkspace(cwd: "~")), [])
        XCTAssertEqual(problems(StartWorkspace(cwd: "/tmp/a\u{7F}")), [.folderInvalid])
        // Names, titles, commands: C0, DEL, C1 and the Unicode line / paragraph separators are refused.
        for bad in ["\u{0}", "\u{1F}", "\u{7F}", "\u{85}", "\u{9F}", "\u{2028}", "\u{2029}"] {
            XCTAssertEqual(problems(StartWorkspace(cwd: "/tmp", command: "echo " + bad)), [.commandInvalid], bad.debugDescription)
            XCTAssertEqual(ScheduleValidation.problems(draft(.once(at: now), name: "a" + bad)), [.nameInvalid])
        }
        XCTAssertEqual(problems(StartWorkspace(cwd: "/tmp", command: "echo \u{A0}é")), [])
        // A prompt keeps line breaks and tabs (and the Unicode separators); other control characters are refused.
        for good in ["a\nb", "a\tb", "a\u{2028}b", "a\u{2029}b", "a\u{A0}b"] {
            XCTAssertEqual(problems(StartWorkspace(cwd: "/tmp", command: "claude", prompt: good)), [], good.debugDescription)
        }
        for bad in ["a\rb", "a\u{0}", "a\u{7F}", "a\u{85}", "a\u{9F}"] {
            XCTAssertEqual(problems(StartWorkspace(cwd: "/tmp", command: "claude", prompt: bad)), [.promptInvalid],
                           bad.debugDescription)
        }
    }

    func testContinueSession() {
        func problems(_ action: ContinueSession) -> [ScheduleProblem] {
            ScheduleValidation.problems(draft(.once(at: now), .continueSession(action)))
        }
        XCTAssertEqual(problems(ContinueSession(sessionID: "abc-123")), [])
        XCTAssertEqual(problems(ContinueSession(agent: .codex, sessionID: "abc")), [.agentUnsupported])
        XCTAssertEqual(problems(ContinueSession(sessionID: "abc; rm -rf ~")), [.sessionIDInvalid])
        XCTAssertEqual(problems(ContinueSession(sessionID: "abc", cwd: "relative")), [.folderInvalid])
        XCTAssertEqual(problems(ContinueSession(sessionID: "abc", account: "auto")), [.accountInvalid("auto")])
        XCTAssertEqual(problems(ContinueSession(sessionID: "abc", prompt: "")), [.promptInvalid])
    }

    func testCreation() {
        let limited = ClaudeAccount(name: "work", configDir: "~/.claude-work",
                                    limit: ClaudeAccountLimit(kind: .usageLimit, resetsAt: now.addingTimeInterval(3600)))
        let free = ClaudeAccount(name: "me", configDir: "~/.claude")
        let accounts = [limited, free]
        func problems(_ draft: ScheduleDraft, existing: Int = 0, accounts: [ClaudeAccount] = accounts) -> [ScheduleProblem] {
            ScheduleValidation.problems(draft, accounts: accounts, existing: existing, now: now)
        }
        XCTAssertEqual(problems(draft(.once(at: now))), [.onceInPast])
        XCTAssertEqual(problems(draft(.once(at: now.addingTimeInterval(60)))), [])
        XCTAssertEqual(problems(draft(.once(at: now.addingTimeInterval(60))), existing: 50), [.tooManySchedules])
        XCTAssertEqual(problems(draft(.limitReset(account: "WORK", delay: 60))), [])
        XCTAssertEqual(problems(draft(.limitReset(account: "me", delay: 60))), [.accountNotLimited("me")])
        XCTAssertEqual(problems(draft(.limitReset(account: "gone", delay: 60))), [.accountUnknown("gone")])
        let auto = ScheduleAction.startWorkspace(StartWorkspace(cwd: "/tmp", account: "auto"))
        XCTAssertEqual(problems(draft(weekly(["09:00"]), auto)), [])
        XCTAssertEqual(problems(draft(weekly(["09:00"]), auto), accounts: []), [.noAccounts])
        let named = ScheduleAction.continueSession(ContinueSession(sessionID: "abc", account: "gone"))
        XCTAssertEqual(problems(draft(weekly(["09:00"]), named)), [.accountUnknown("gone")])
    }
}
