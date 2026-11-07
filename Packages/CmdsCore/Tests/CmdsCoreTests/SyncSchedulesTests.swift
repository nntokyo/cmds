import XCTest
@testable import CmdsCore

/// The schedules on the phone (`SyncFeature.schedules`, #45 phase 3): the summary, its wire form, the pacing and the
/// feature negotiation. What the phone gets must never contain prompts, commands, texts, folders or session ids.
final class SyncSchedulesTests: XCTestCase {
    let codec = SyncCodec()
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    private static let secrets = ["SECRET-PROMPT", "secret-command --flag", "/Users/me/secret-folder", "SECRET-TEXT",
                                  "Secret title", "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0", "Secret workspace"]

    private func schedule(_ id: String, _ name: String, trigger: ScheduleTrigger, action: ScheduleAction,
                          enabled: Bool = true) -> Schedule {
        Schedule(id: id, draft: ScheduleDraft(name: name, enabled: enabled, trigger: trigger, action: action),
                 origin: .api(pane: "p3"), createdAt: now, nextFireAt: now.addingTimeInterval(3600))
    }

    /// One schedule of every action, each holding secrets the phone must not see.
    private func list() -> (ScheduleList, [ScheduleRun]) {
        let start = schedule("s00000001", "Morning tests",
                             trigger: .weekly(WeeklyRule(weekdays: Weekday.workdays, times: [TimeOfDay("09:00")!],
                                                         timeZone: "Asia/Tokyo")),
                             action: .startWorkspace(StartWorkspace(cwd: "/Users/me/secret-folder", title: "Secret title",
                                                                    account: "work", command: "secret-command --flag",
                                                                    prompt: "SECRET-PROMPT")))
        let resume = schedule("s00000002", "Continue",
                              trigger: .limitReset(account: "work", delay: 60, repeats: true),
                              action: .continueSession(ContinueSession(agent: .codex,
                                                                       sessionID: "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0",
                                                                       cwd: "/Users/me/secret-folder",
                                                                       prompt: "SECRET-PROMPT")))
        let send = schedule("s00000003", "Bench", trigger: .once(at: now.addingTimeInterval(7200)),
                            action: .sendText(SendText(target: .workspace(title: "Secret workspace"), text: "SECRET-TEXT",
                                                       to: .shell)),
                            enabled: false)
        let ended = ScheduleRun(id: "r00000001", scheduleID: "s00000001", scheduleName: "Morning tests", cause: .catchUp,
                                dueAt: now.addingTimeInterval(-86400), startedAt: now.addingTimeInterval(-86400),
                                endedAt: now.addingTimeInterval(-86300), state: .skipped, reason: .otherProgram,
                                workspace: "w1", pane: "p2", account: "work")
        let active = ScheduleRun(id: "r00000002", scheduleID: "s00000002", scheduleName: "Continue", cause: .scheduled,
                                 dueAt: now.addingTimeInterval(-60), startedAt: now.addingTimeInterval(-60),
                                 state: .waitingForAgent)
        let entries = [
            ScheduleListEntry(schedule: start, nextFireAt: start.nextFireAt, lastRun: ended, problem: "x"),
            ScheduleListEntry(schedule: resume, nextFireAt: resume.nextFireAt, activeRun: active),
            ScheduleListEntry(schedule: send, nextFireAt: nil),
        ]
        return (ScheduleList(schedules: entries), [active, ended])
    }

    func testSummaryCarriesNoPromptsCommandsOrPaths() throws {
        let (list, runs) = list()
        let message = SyncSchedules.message(list: list, runs: runs)
        let json = String(decoding: try codec.encode(.schedules(message)), as: UTF8.self)
        for secret in Self.secrets {
            XCTAssertFalse(json.contains(secret), "\(secret) reached the phone: \(json)")
        }
        // Only these keys describe an action.
        XCTAssertTrue(json.contains(#""action":{"type":"startWorkspace"}"#), json)
        XCTAssertTrue(json.contains(#""action":{"agent":"codex","type":"continueSession"}"#), json)
        XCTAssertTrue(json.contains(#""action":{"to":"shell","type":"sendText"}"#), json)
        XCTAssertFalse(json.contains("\"cwd\""), json)
        XCTAssertFalse(json.contains("\"prompt\""), json)
        XCTAssertFalse(json.contains("\"command\""), json)
        XCTAssertFalse(json.contains("\"sessionID\""), json)
        XCTAssertFalse(json.contains("\"problem\""), json)
        XCTAssertTrue(json.hasPrefix(#"{"#) && json.contains(#""type":"schedules""#), json)
    }

    func testSummaryFields() throws {
        let (list, runs) = list()
        let message = SyncSchedules.message(list: list, runs: runs)
        XCTAssertEqual(message.schedules.map(\.id), ["s00000001", "s00000002", "s00000003"])
        let first = message.schedules[0]
        XCTAssertEqual(first.name, "Morning tests")
        XCTAssertTrue(first.enabled)
        XCTAssertEqual(first.trigger, .weekly(WeeklyRule(weekdays: Weekday.workdays, times: [TimeOfDay("09:00")!],
                                                         timeZone: "Asia/Tokyo")))
        XCTAssertEqual(first.nextFireAt, now.addingTimeInterval(3600))
        XCTAssertEqual(first.lastRun?.reason, .otherProgram)
        XCTAssertNil(first.activeRun)
        XCTAssertEqual(message.schedules[1].activeRun?.state, .waitingForAgent)
        XCTAssertEqual(message.schedules[1].action, SyncScheduleAction(type: "continueSession", agent: .codex))
        XCTAssertFalse(message.schedules[2].enabled)
        XCTAssertNil(message.schedules[2].nextFireAt)
        XCTAssertEqual(message.runs.map(\.id), ["r00000002", "r00000001"])
        XCTAssertNil(message.readOnly)
        XCTAssertEqual(SyncSchedules.message(list: ScheduleList(schedules: [], readOnly: true), runs: []).readOnly, true)
    }

    func testRunsAreCapped() {
        let runs = (0..<100).map { i in
            ScheduleRun(id: String(format: "r%08x", i), scheduleID: "s00000001", scheduleName: "x", cause: .scheduled,
                        dueAt: now, startedAt: now, endedAt: now, state: .succeeded, reason: .confirmed)
        }
        let message = SyncSchedules.message(list: ScheduleList(schedules: []), runs: runs)
        XCTAssertEqual(message.runs.count, SyncSchedules.maxRuns)
        XCTAssertEqual(message.runs.first?.id, "r00000000", "newest first, as given")
    }

    func testRoundTrip() throws {
        let (list, runs) = list()
        let message = ServerMessage.schedules(SyncSchedules.message(list: list, runs: runs))
        let data = try codec.encode(message)
        XCTAssertEqual(codec.peekType(data), "schedules")
        XCTAssertEqual(try codec.decodeServerMessage(data), message)
        let empty = ServerMessage.schedules(.init(schedules: [], runs: []))
        XCTAssertEqual(try codec.decodeServerMessage(try codec.encode(empty)), empty)
        // Dates are epoch seconds, as everywhere in the protocol.
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""nextFireAt":1793003600"#))
    }

    /// A newer Mac's trigger, action or run state does not cost the phone the rest of the list.
    func testDecodingIsLenient() throws {
        let json = #"""
        {"type":"schedules","schedules":[
          {"id":"s00000001","name":"New trigger","enabled":true,"trigger":{"type":"lunar","phase":"full"},
           "action":{"type":"newAction","extra":1},"nextFireAt":1793003600},
          {"name":"no id"},
          {"id":"s00000002","name":"Known","enabled":false,"trigger":{"type":"once","at":1793003600},
           "action":{"type":"sendText","to":"agent"},"lastRun":{"id":"r00000009"}}
        ],"runs":[
          {"id":"r00000001","scheduleID":"s00000001","scheduleName":"New trigger","state":"teleporting","dueAt":1793000000},
          {"id":"r00000002","scheduleID":"s00000002","scheduleName":"Known","state":"failed","dueAt":1793000000,
           "reason":"someNewReason"}
        ],"future":true}
        """#
        guard case .schedules(let message) = try codec.decodeServerMessage(Data(json.utf8)) else {
            return XCTFail("not schedules")
        }
        XCTAssertEqual(message.schedules.map(\.id), ["s00000001", "s00000002"])
        XCTAssertNil(message.schedules[0].trigger)
        XCTAssertEqual(message.schedules[0].action.type, "newAction")
        XCTAssertEqual(message.schedules[1].trigger, .once(at: Date(timeIntervalSince1970: 1_793_003_600)))
        XCTAssertEqual(message.schedules[1].action, SyncScheduleAction(type: "sendText", to: .agent))
        XCTAssertNil(message.schedules[1].lastRun, "an incomplete run is dropped")
        XCTAssertEqual(message.runs.map(\.id), ["r00000002"])
        XCTAssertEqual(message.runs[0].reason, .other)
    }

    func testFeatureNegotiation() throws {
        // An older phone (no features, or features without schedules) never gets the message.
        XCTAssertFalse(SyncSchedules.isWanted(by: .init(deviceName: "old", token: "t")))
        XCTAssertFalse(SyncSchedules.isWanted(by: .init(deviceName: "0.11", features: [SyncFeature.previewPanes,
                                                                                    SyncFeature.styles], token: "t")))
        XCTAssertTrue(SyncSchedules.isWanted(by: .init(deviceName: "new", features: [SyncFeature.schedules], token: "t")))
        // The hello of a new phone carries it on the wire; an older Mac ignores the unknown feature string.
        let hello = ClientMessage.hello(.init(deviceName: "new", features: [SyncFeature.schedules], token: "t"))
        let data = try codec.encode(hello)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""features":["schedules"]"#))
        guard case .hello(let decoded) = try codec.decodeClientMessage(data) else { return XCTFail() }
        XCTAssertTrue(SyncSchedules.isWanted(by: decoded))
        // An older Mac's welcome has no features: the phone does not offer the list.
        let old = try codec.decodeServerMessage(Data(#"{"type":"welcome","protocolVersion":2,"macName":"m","token":"t"}"#.utf8))
        guard case .welcome(let welcome) = old else { return XCTFail() }
        XCTAssertFalse(welcome.features?.contains(SyncFeature.schedules) == true)
        XCTAssertEqual(SyncProtocol.version, 2, "the feature is additive; the protocol version stays")
    }

    func testPacing() {
        XCTAssertEqual(SyncSchedules.delay(lastSentAt: nil, now: now), 0)
        XCTAssertEqual(SyncSchedules.delay(lastSentAt: now, now: now), 1)
        XCTAssertEqual(SyncSchedules.delay(lastSentAt: now.addingTimeInterval(-0.25), now: now), 0.75, accuracy: 1e-9)
        XCTAssertEqual(SyncSchedules.delay(lastSentAt: now.addingTimeInterval(-5), now: now), 0)
        // A clock that went back never makes the wait longer than the interval.
        XCTAssertEqual(SyncSchedules.delay(lastSentAt: now.addingTimeInterval(30), now: now), 1)
    }
}
