import XCTest
@testable import CmdsCore

/// Codex's usage limit reached (`task_complete` error `usage_limit_exceeded`), its reset time and the stored limits (#227).
final class CodexLimitReachedTests: XCTestCase {
    /// codex-cli 0.165.0, 2026-11-07: a working session.
    static let working = #"{"timestamp":"2026-11-07T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":32.0,"window_minutes":300,"resets_at":1794051627},"secondary":{"used_percent":80.0,"window_minutes":10080,"resets_at":1794407593},"credits":{"has_credits":false,"unlimited":false,"balance":null},"plan_type":"plus"}}}"#
    /// 2026-11-11: the account over its limit — empty windows, then the refused turn.
    static let emptyWindows = #"{"timestamp":"2026-11-10T19:48:33.802Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"premium","limit_name":null,"primary":null,"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":null},"individual_limit":null,"spend_control_reached":null,"plan_type":null,"rate_limit_reached_type":null}}}"#
    static let reached = #"{"timestamp":"2026-11-10T19:48:33.810Z","type":"event_msg","payload":{"type":"task_complete","root_turn_id":"r","turn_id":"t","last_agent_message":null,"error":{"message":"You’ve hit your usage limit. Upgrade to Plus to continue using Codex (https://chatgpt.com/explore/plus), or try again at Dec 7th, 2026 11:05 PM.","codex_error_info":"usage_limit_exceeded"},"started_at":1794340109,"completed_at":1794340113,"duration_ms":3855}}"#
    static let modelNotFound = #"{"timestamp":"2026-11-10T19:50:00.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t2","last_agent_message":null,"error":{"message":"The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account.","codex_error_info":"model_not_found"}}}"#

    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let event = Date(timeIntervalSince1970: 1_794_340_113.810) // 2026-11-10T19:48:33.810Z

    private func parse(_ lines: [String]) -> CodexRollout.Snapshot {
        CodexRollout.parse(Data((lines.joined(separator: "\n") + "\n").utf8)).snapshot
    }

    private func utc(_ string: String) -> Date { try! Date(string, strategy: .iso8601) }

    func testReachedLimitWithResetFromMessage() throws {
        // The message's time is the Mac's local time; pin it for the test.
        let snapshot = parse([Self.emptyWindows, Self.reached])
        let reached = try XCTUnwrap(snapshot.limitReached)
        XCTAssertEqual(try XCTUnwrap(reached.date).timeIntervalSince1970, event.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertNotNil(reached.resetsAt)
        let reset = CodexRollout.limitReset(fromMessage: "… or try again at Dec 7th, 2026 11:05 PM.", eventDate: event, timeZone: tokyo)
        XCTAssertEqual(reset, utc("2026-12-07T14:05:00Z"))
        // Without figures before, the reached limit alone.
        var pinned = snapshot
        pinned.limitReached?.resetsAt = reset
        let limits = try XCTUnwrap(pinned.accountLimits(fallbackDate: Date()))
        XCTAssertEqual(limits.limits, [UsageLimit(id: UsageLimit.usageLimit, usedPercent: 100, resetsAt: reset)])
        XCTAssertEqual(limits.updatedAt, reached.date)
        XCTAssertEqual(limits.exhaustedReset, reset)
        XCTAssertEqual(AgentFormat.limitLabel(limits.limits[0]), "limit")
        XCTAssertEqual(AgentFormat.limitLines(limits.limits, now: event).first?.hasPrefix("Usage limit 100% used · resets "), true)
    }

    func testEmptyWindowsKeepKnownFiguresAndReachedAddsToThem() throws {
        let snapshot = parse([Self.working, Self.emptyWindows, Self.reached, Self.modelNotFound])
        XCTAssertEqual(snapshot.limits.map(\.id), [UsageLimit.fiveHour, UsageLimit.sevenDay])
        XCTAssertEqual(snapshot.plan, "plus")
        XCTAssertNotNil(snapshot.limitReached, "model_not_found does not clear it")
        let limits = try XCTUnwrap(snapshot.accountLimits(fallbackDate: Date()))
        XCTAssertEqual(limits.limits.map(\.id), [UsageLimit.fiveHour, UsageLimit.sevenDay, UsageLimit.usageLimit])
        XCTAssertEqual(limits.limits.map(\.usedPercent), [32, 80, 100])
        // At the event the 5-hour window had reset already.
        XCTAssertEqual(limits.active(at: event)?.limits.map(\.id), [UsageLimit.sevenDay, UsageLimit.usageLimit])

        // Incremental reads: the empty-windows event alone wipes nothing, the reached one is merged.
        var merged = parse([Self.working])
        merged.merge(parse([Self.emptyWindows]))
        XCTAssertEqual(merged.limits.count, 2)
        XCTAssertNil(merged.limitReached)
        merged.merge(parse([Self.reached]))
        XCTAssertNotNil(merged.limitReached)
        // A later event with figures replaces the reached state.
        let later = Self.working.replacingOccurrences(of: "2026-11-07T10:00:00.000Z", with: "2026-11-10T20:00:00.000Z")
        merged.merge(parse([later]))
        XCTAssertNil(merged.limitReached)
        XCTAssertEqual(merged.accountLimits(fallbackDate: Date())?.limits.count, 2)
        // Within one read too.
        XCTAssertNil(parse([Self.reached, later]).limitReached)
    }

    func testModelNotFoundAloneIsNoLimit() {
        let snapshot = parse([Self.modelNotFound])
        XCTAssertNil(snapshot.limitReached)
        XCTAssertNil(snapshot.accountLimits(fallbackDate: Date()))
    }

    func testReachedResetMatchingAWindowMarksItFull() throws {
        var snapshot = parse([Self.working])
        // The 7-day window resets 2026-11-11T14:33:13Z; Codex's message says 11:33 PM Tokyo.
        snapshot.limitReached = .init(date: event, resetsAt: utc("2026-11-11T14:33:00Z"))
        let limits = try XCTUnwrap(snapshot.accountLimits(fallbackDate: Date()))
        XCTAssertEqual(limits.limits.map(\.usedPercent), [32, 100])
        XCTAssertEqual(limits.exhaustedReset, Date(timeIntervalSince1970: 1_794_407_593))
    }

    func testReachedWithoutResetLastsADay() throws {
        let message = Self.reached.replacingOccurrences(of: ", or try again at Dec 7th, 2026 11:05 PM.", with: ".")
        let snapshot = parse([message])
        XCTAssertNotNil(snapshot.limitReached)
        XCTAssertNil(snapshot.limitReached?.resetsAt)
        let limits = try XCTUnwrap(snapshot.accountLimits(fallbackDate: Date()))
        XCTAssertEqual(limits.limits, [UsageLimit(id: UsageLimit.usageLimit, usedPercent: 100)])
        XCTAssertNil(limits.exhaustedReset)
        XCTAssertNotNil(limits.active(at: event.addingTimeInterval(23 * 3600)))
        XCTAssertNil(limits.active(at: event.addingTimeInterval(25 * 3600)))
    }

    func testErrorEventAndObjectErrorInfo() {
        let errorEvent = #"{"timestamp":"2026-11-10T19:48:33.810Z","type":"event_msg","payload":{"type":"error","message":"You've hit your usage limit. Try again in 2 hours 30 minutes.","codex_error_info":{"usage_limit_exceeded":{}}}}"#
        let reached = parse([errorEvent]).limitReached
        XCTAssertEqual(reached?.resetsAt?.timeIntervalSince1970 ?? 0, event.timeIntervalSince1970 + 9000, accuracy: 0.01)
    }

    func testResetMessageForms() {
        func reset(_ text: String) -> Date? { CodexRollout.limitReset(fromMessage: text, eventDate: event, timeZone: tokyo) }
        // The event is 2026-11-11 04:48 in Tokyo.
        XCTAssertEqual(reset("try again at Dec 7th, 2026 11:05 PM."), utc("2026-12-07T14:05:00Z"))
        XCTAssertEqual(reset("try again at December 1st, 2026 9:00 AM"), utc("2026-12-01T00:00:00Z"))
        XCTAssertEqual(reset("try again at Nov 22nd, 2026 1:30 pm."), utc("2026-11-22T04:30:00Z"))
        XCTAssertEqual(reset("Try again at Nov 23rd 2026 12:00 AM."), utc("2026-11-22T15:00:00Z"))
        // Without the year: the next such date.
        XCTAssertEqual(reset("try again at Dec 7th, 11:05 PM."), utc("2026-12-07T14:05:00Z"))
        XCTAssertEqual(reset("try again at Jan 2nd, 8:00 AM."), utc("2027-01-01T23:00:00Z"))
        // Only the time: today, else tomorrow.
        XCTAssertEqual(reset("try again at 11:05 PM."), utc("2026-11-11T14:05:00Z"))
        XCTAssertEqual(reset("try again at 3:00 AM."), utc("2026-11-11T18:00:00Z"))
        XCTAssertEqual(reset("try again at 3:00\u{202F}AM."), utc("2026-11-11T18:00:00Z"))
        // Relative.
        XCTAssertEqual(reset("try again in 3 days."), event.addingTimeInterval(3 * 86400))
        XCTAssertEqual(reset("Try again in 1 hour 5 minutes."), event.addingTimeInterval(3900))
        // Not understood.
        XCTAssertNil(reset("You've hit your usage limit."))
        XCTAssertNil(reset("try again at some point."))
        XCTAssertNil(reset("try again in a while."))
    }

    func testStoreRoundTripAndExpiry() throws {
        let limits = AgentLimits(agent: .codex, limits: [
            UsageLimit(id: UsageLimit.sevenDay, usedPercent: 80, resetsAt: Date(timeIntervalSince1970: 1_794_407_593)),
            UsageLimit(id: UsageLimit.usageLimit, usedPercent: 100, resetsAt: utc("2026-12-07T14:05:00Z")),
        ], plan: "plus", updatedAt: event)
        let data = try CodexLimitsStore.encode(limits)
        XCTAssertEqual(CodexLimitsStore.decode(data, now: event), limits)
        // The 7-day window has reset: only the reached limit is left.
        XCTAssertEqual(CodexLimitsStore.decode(data, now: utc("2026-11-20T00:00:00Z"))?.limits.map(\.id), [UsageLimit.usageLimit])
        // Everything has reset: ignored.
        XCTAssertNil(CodexLimitsStore.decode(data, now: utc("2026-12-08T00:00:00Z")))
        // Damaged or another agent's.
        XCTAssertNil(CodexLimitsStore.decode(Data("{".utf8), now: event))
        var claude = limits
        claude.agent = .claude
        XCTAssertNil(CodexLimitsStore.decode(try CodexLimitsStore.encode(claude), now: event))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-limits-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(CodexLimitsStore.load(supportDirectory: directory, now: event))
        try CodexLimitsStore.save(limits, supportDirectory: directory)
        XCTAssertEqual(CodexLimitsStore.load(supportDirectory: directory, now: event), limits)

        XCTAssertFalse(CodexLimitsStore.changed(limits, AgentLimits(agent: .codex, limits: limits.limits, plan: "plus")))
        XCTAssertTrue(CodexLimitsStore.changed(nil, limits))
        XCTAssertTrue(CodexLimitsStore.changed(limits, AgentLimits(agent: .codex, limits: [limits.limits[0]], plan: "plus")))
    }
}
