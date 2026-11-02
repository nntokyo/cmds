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
        let text = #"{"version": 3, "schedules": [], "runs": []}"#
        XCTAssertTrue(try JSONDecoder().decode(ScheduleFile.self, from: Data(text.utf8)).isFromNewerVersion)
        XCTAssertTrue(try JSONDecoder().decode(ScheduleRunsFile.self, from: Data(text.utf8)).isFromNewerVersion)
        XCTAssertFalse(try JSONDecoder().decode(ScheduleFile.self, from: Data(#"{"schedules": []}"#.utf8)).isFromNewerVersion)
        // Version 2 (phase 2) is this build's; the history stays at version 1.
        XCTAssertFalse(try JSONDecoder().decode(ScheduleFile.self, from: Data(#"{"version": 2, "schedules": []}"#.utf8)).isFromNewerVersion)
        XCTAssertTrue(try JSONDecoder().decode(ScheduleRunsFile.self, from: Data(#"{"version": 2, "runs": []}"#.utf8)).isFromNewerVersion)
        XCTAssertEqual(try json(ScheduleRunsFile())["version"] as? Int, 1)
    }

    // MARK: Phase 2: versioning

    private func phase2(_ trigger: ScheduleTrigger, _ action: ScheduleAction) -> Schedule {
        Schedule(id: "s0000000a", draft: ScheduleDraft(name: "p2", trigger: trigger, action: action), origin: .app,
                 createdAt: created)
    }

    private let send = ScheduleAction.sendText(SendText(target: .tag("t1a2b3c4d"), text: "continue", to: .agent))

    func testVersionIsTheLowestThatRunsEverySchedule() throws {
        // Only phase-1 schedules: version 1, so a phase-1 build keeps running them.
        XCTAssertEqual(ScheduleFile(schedules: [morning, continuing]).version, 1)
        XCTAssertEqual(try json(ScheduleFile(schedules: [])).count, 2)
        XCTAssertEqual(try json(ScheduleFile(schedules: [morning]))["version"] as? Int, 1)
        // Any phase-2 action or trigger: version 2, which a phase-1 build (currentVersion 1) opens read only.
        let codex = ContinueSession(agent: .codex, sessionID: "019a-codex")
        for schedule in [phase2(.once(at: created), send),
                         phase2(.once(at: created), .continueSession(codex)),
                         phase2(.limitReset(account: "work", delay: 60, repeats: true), continuing.action),
                         phase2(.codexLimitReset(delay: 60), continuing.action)] {
            let file = ScheduleFile(schedules: [morning, schedule])
            XCTAssertEqual(file.version, 2, "\(schedule.trigger) \(schedule.action)")
            XCTAssertGreaterThan(file.version, 1)
            let decoded = try JSONDecoder().decode(ScheduleFile.self, from: JSONEncoder().encode(file))
            XCTAssertEqual(decoded.schedules, file.schedules)
            XCTAssertFalse(decoded.isFromNewerVersion)
        }
        // Fields an older build may ignore do not raise it.
        var quiet = morning
        quiet.warn = false
        quiet.lastDueAt = created
        XCTAssertEqual(ScheduleFile(schedules: [quiet]).version, 1)
    }

    func testPhase2Format() throws {
        let object = try json(phase2(.limitReset(account: "work", delay: 60, repeats: true), send))
        XCTAssertEqual((object["trigger"] as? [String: Any])?["repeats"] as? Bool, true)
        let action = object["action"] as? [String: Any]
        XCTAssertEqual(action?["type"] as? String, "sendText")
        XCTAssertEqual(action?["to"] as? String, "agent")
        XCTAssertEqual(action?["target"] as? [String: String], ["tag": "t1a2b3c4d"])
        XCTAssertEqual(object["warn"] as? Bool, true)
        // A one-shot limit trigger is written as in phase 1 (no `repeats`).
        XCTAssertNil((try json(continuing)["trigger"] as? [String: Any])?["repeats"])
        let codex = try json(phase2(.codexLimitReset(delay: 0), send))["trigger"] as? [String: Any]
        XCTAssertEqual(codex?["type"] as? String, "codexLimitReset")
        // Read back: targets by workspace title; `warn` absent = on (phase-1 files).
        let text = """
            {"version": 2, "schedules": [
              {"id": "s00000002", "name": "x", "trigger": {"type": "codexLimitReset", "delay": 30, "repeats": true},
               "action": {"type": "sendText", "target": {"workspace": "API"}, "text": "make test", "to": "shell"}},
              {"id": "s00000003", "name": "bad target", "trigger": {"type": "once", "at": 1793000000},
               "action": {"type": "sendText", "target": {"tag": "t1", "workspace": "API"}, "text": "x", "to": "shell"}},
              {"id": "s00000004", "name": "pane ids are not stored", "trigger": {"type": "once", "at": 1793000000},
               "action": {"type": "sendText", "target": {"pane": "p3"}, "text": "x", "to": "shell"}},
              {"id": "s00000005", "name": "bad to", "trigger": {"type": "once", "at": 1793000000},
               "action": {"type": "sendText", "target": {"workspace": "API"}, "text": "x", "to": "both"}}
            ]}
            """
        let file = try JSONDecoder().decode(ScheduleFile.self, from: Data(text.utf8))
        XCTAssertEqual(file.dropped, 3)
        let kept = try XCTUnwrap(file.schedules.first)
        XCTAssertEqual(kept.trigger, .codexLimitReset(delay: 30, repeats: true))
        XCTAssertEqual(kept.action, .sendText(SendText(target: .workspace(title: "API"), text: "make test", to: .shell)))
        XCTAssertTrue(kept.warn)
        XCTAssertTrue(kept.trigger.repeats)
        XCTAssertFalse(kept.trigger.isOneShot)
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

    /// The API's problem texts name the limits (#47: taken from `ScheduleLimits`).
    func testProblemTextsNameTheLimits() {
        XCTAssertEqual(ScheduleProblem.timesTooClose.english, "times of day must be at least 5 minutes apart")
        XCTAssertEqual(ScheduleProblem.delayOutOfRange.english, "the delay must be 0 to 60 minutes")
        XCTAssertEqual(ScheduleProblem.lateOutOfRange.english, "a late run must be allowed for 1 minute to 7 days")
        XCTAssertEqual(ScheduleProblem.commandInvalid.english,
                       "the command must be one line of at most 1 KB without control characters")
        XCTAssertEqual(ScheduleProblem.promptTooLong.english, "the prompt must be at most 8 KB")
    }

    /// One rule for the editor and the runner (#55): a new schedule, a new trigger or turning it on is checked in full,
    /// also when the schedule stays off.
    func testFullCheckRule() {
        let past = draft(.once(at: now.addingTimeInterval(-60)))
        var off = past
        off.enabled = false
        XCTAssertTrue(ScheduleValidation.needsFullCheck(old: nil, new: off))
        var changed = off
        changed.trigger = .once(at: now.addingTimeInterval(-120))
        XCTAssertTrue(ScheduleValidation.needsFullCheck(old: off, new: changed))
        var renamed = off
        renamed.name = "y"
        XCTAssertFalse(ScheduleValidation.needsFullCheck(old: off, new: renamed))
        XCTAssertTrue(ScheduleValidation.needsFullCheck(old: off, new: past)) // turned on
        XCTAssertFalse(ScheduleValidation.needsFullCheck(old: past, new: off)) // turned off
        var renamedOn = past
        renamedOn.name = "y"
        XCTAssertFalse(ScheduleValidation.needsFullCheck(old: past, new: renamedOn))
    }

    /// The editor's late field (#55): blank = default, not a number = a problem of its own, minutes rounded.
    func testLateField() {
        XCTAssertEqual(ScheduleLatePolicy.fromMinutes(" ", trigger: .once(at: now)), .runIfWithin(6 * 3600))
        XCTAssertEqual(ScheduleLatePolicy.fromMinutes("30", trigger: .once(at: now)), .runIfWithin(1800))
        XCTAssertEqual(ScheduleLatePolicy.fromMinutes(" 1.5 ", trigger: .once(at: now)), .runIfWithin(90))
        XCTAssertNil(ScheduleLatePolicy.fromMinutes("soon", trigger: .once(at: now)))
        XCTAssertNil(ScheduleLatePolicy.fromMinutes("nan", trigger: .once(at: now)))
        XCTAssertEqual(ScheduleLatePolicy.minutesText(89), "1")
        XCTAssertEqual(ScheduleLatePolicy.minutesText(90), "2")
        XCTAssertEqual(ScheduleLatePolicy.minutesText(15 * 60), "15")
        XCTAssertEqual(ScheduleProblem.lateNotANumber.english, "give the late window as a number of minutes")
    }

    /// "Continue at": an existing schedule counts only when it will run (#55).
    func testContinuesAtReset() {
        let action = ScheduleAction.continueSession(ContinueSession(sessionID: "abc"))
        var schedule = Schedule(id: "s00000001", draft: draft(.limitReset(account: "Work", delay: 60), action), origin: .app,
                                createdAt: now, nextFireAt: now.addingTimeInterval(3600))
        XCTAssertTrue(schedule.continuesAtReset(sessionID: "abc", account: "work"))
        XCTAssertFalse(schedule.continuesAtReset(sessionID: "abd", account: "work"))
        XCTAssertFalse(schedule.continuesAtReset(sessionID: "abc", account: "me"))
        schedule.nextFireAt = nil
        XCTAssertFalse(schedule.continuesAtReset(sessionID: "abc", account: "work"))
        schedule.nextFireAt = now
        schedule.enabled = false
        XCTAssertFalse(schedule.continuesAtReset(sessionID: "abc", account: "work"))
    }

    /// The schedule's own pane is stored with the session (#55); older files without it still load.
    func testContinueSessionPane() throws {
        let action = ContinueSession(sessionID: "abc", pane: "p12")
        let decoded = try JSONDecoder().decode(ContinueSession.self, from: JSONEncoder().encode(action))
        XCTAssertEqual(decoded.pane, "p12")
        let old = try JSONDecoder().decode(ContinueSession.self, from: Data(#"{"sessionID":"abc"}"#.utf8))
        XCTAssertNil(old.pane)
    }

    func testContinueSession() {
        func problems(_ action: ContinueSession) -> [ScheduleProblem] {
            ScheduleValidation.problems(draft(.once(at: now), .continueSession(action)))
        }
        XCTAssertEqual(problems(ContinueSession(sessionID: "abc-123")), [])
        XCTAssertEqual(problems(ContinueSession(agent: .codex, sessionID: "abc")), [])
        XCTAssertEqual(problems(ContinueSession(agent: .codex, sessionID: "abc", account: "work")), [.accountWithCodex])
        XCTAssertEqual(problems(ContinueSession(agent: .other, sessionID: "abc")), [.agentUnsupported])
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

    func testSendTextValidation() {
        func problems(_ target: PaneTarget, _ text: String, _ to: SendText.Destination) -> [ScheduleProblem] {
            ScheduleValidation.problems(draft(.once(at: now), .sendText(SendText(target: target, text: text, to: to))))
        }
        XCTAssertEqual(problems(.tag("t1a2b3c4d"), "make test", .shell), [])
        XCTAssertEqual(problems(.workspace(title: "API"), "continue\nand then this", .agent), [])
        XCTAssertEqual(problems(.tag("p3"), "x", .shell), [.targetInvalid])
        XCTAssertEqual(problems(.pane("p3"), "x", .shell), [.targetInvalid])
        XCTAssertEqual(problems(.workspace(title: "  "), "x", .shell), [.targetInvalid])
        // A shell gets one line; an agent a prompt (line breaks fine, no escape sequences).
        XCTAssertEqual(problems(.tag("t1a2b3c4d"), "make\ntest", .shell), [.commandInvalid])
        XCTAssertEqual(problems(.tag("t1a2b3c4d"), "x\u{1b}[201~rm -rf ~", .agent), [.promptInvalid])
        XCTAssertEqual(problems(.tag("t1a2b3c4d"), String(repeating: "a", count: 8 * 1024 + 1), .agent), [.promptTooLong])
    }

    func testPhase2Creation() {
        let free = ClaudeAccount(name: "me", configDir: "~/.claude")
        let send = ScheduleAction.sendText(SendText(target: .tag("t1a2b3c4d"), text: "continue", to: .agent))
        func problems(_ trigger: ScheduleTrigger, codex: AgentLimits? = nil) -> [ScheduleProblem] {
            ScheduleValidation.problems(draft(trigger, send), accounts: [free], codex: codex, existing: 0, now: now)
        }
        // "Every time it resets" needs no limit now; once does.
        XCTAssertEqual(problems(.limitReset(account: "me", delay: 60)), [.accountNotLimited("me")])
        XCTAssertEqual(problems(.limitReset(account: "me", delay: 60, repeats: true)), [])
        XCTAssertEqual(problems(.limitReset(account: "gone", delay: 60, repeats: true)), [.accountUnknown("gone")])
        let limited = AgentLimits(agent: .codex, limits: [UsageLimit(id: UsageLimit.fiveHour, usedPercent: 100,
                                                                     resetsAt: now.addingTimeInterval(600))], updatedAt: now)
        XCTAssertEqual(problems(.codexLimitReset(delay: 60)), [.codexNotLimited])
        XCTAssertEqual(problems(.codexLimitReset(delay: 60), codex: limited), [])
        XCTAssertEqual(problems(.codexLimitReset(delay: 60, repeats: true)), [])
        XCTAssertEqual(problems(.codexLimitReset(delay: 7200, repeats: true)), [.delayOutOfRange])
    }
}
