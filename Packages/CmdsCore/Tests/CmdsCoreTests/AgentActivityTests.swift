import XCTest
@testable import CmdsCore

final class AgentTitleTests: XCTestCase {
    func testParsesClaudeTitles() {
        XCTAssertEqual(AgentTitle.parse("✳ 自走型売上基盤の対応"), .init(glyph: .idle, glyphCharacter: "✳", topic: "自走型売上基盤の対応"))
        XCTAssertEqual(AgentTitle.parse("◐ テスト作業").glyph, .busy)
        XCTAssertEqual(AgentTitle.parse("◐ テスト作業").topic, "テスト作業")
        XCTAssertEqual(AgentTitle.parse("⠂ Fix the build").glyph, .busy)
        XCTAssertEqual(AgentTitle.parse("✶ Fix").glyph, .busy)
        XCTAssertNil(AgentTitle.parse("✳ Claude Code").topic)
        XCTAssertEqual(AgentTitle.parse("✳ Claude Code").glyph, .idle)
    }

    func testShellTitlesAreNotAgentTitles() {
        XCTAssertEqual(AgentTitle.parse("zsh"), .init())
        XCTAssertEqual(AgentTitle.parse("~/Source/cmds"), .init())
        XCTAssertEqual(AgentTitle.parse(""), .init())
    }
}

final class AgentSignalsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testNoAgent() {
        XCTAssertEqual(AgentSignals().activity(at: t0), .none)
    }

    func testNotificationThenPromptSubmit() {
        var signals = AgentSignals()
        signals.hasUsage = true
        signals.hook = .needsInput
        signals.hookAt = t0
        XCTAssertEqual(signals.activity(at: t0 + 5), .needsInput)
        signals.hook = .busy
        signals.hookAt = t0 + 10
        XCTAssertEqual(signals.activity(at: t0 + 11), .busy)
        signals.hook = .finished
        signals.hookAt = t0 + 20
        XCTAssertEqual(signals.activity(at: t0 + 21), .idle)
    }

    func testReportAfterNotificationMeansBusyAgain() {
        var signals = AgentSignals()
        signals.hasUsage = true
        signals.hook = .needsInput
        signals.hookAt = t0
        signals.reportChangedAt = t0 + 1 // trails the notification
        XCTAssertEqual(signals.activity(at: t0 + 2), .needsInput)
        signals.reportChangedAt = t0 + 30
        XCTAssertEqual(signals.activity(at: t0 + 31), .busy)
        // Reports alone stop meaning busy after a while.
        XCTAssertEqual(signals.activity(at: t0 + 30 + AgentSignals.reportBusyTimeout + 1), .idle)
    }

    func testTitleSpinner() {
        var signals = AgentSignals()
        signals.titleGlyph = .busy
        signals.titleChangedAt = t0
        signals.titleAnimatedAt = t0
        XCTAssertEqual(signals.activity(at: t0 + 1), .busy)
        // A busy glyph stays busy (the title is the current state) even without animation.
        XCTAssertEqual(signals.activity(at: t0 + AgentSignals.busyTimeout + 10), .busy)
        // A notification after the last frame wins.
        signals.hook = .needsInput
        signals.hookAt = t0 + 2
        XCTAssertEqual(signals.activity(at: t0 + 3), .needsInput)
        // Spinning again afterwards: busy.
        signals.titleAnimatedAt = t0 + 5
        signals.titleChangedAt = t0 + 5
        XCTAssertEqual(signals.activity(at: t0 + 6), .busy)
        signals.titleGlyph = .idle
        signals.titleChangedAt = t0 + 8
        XCTAssertEqual(signals.activity(at: t0 + 9), .idle)
    }

    func testEvidenceBeforeExitIsIgnored() {
        var signals = AgentSignals()
        signals.titleGlyph = .idle
        signals.titleChangedAt = t0
        signals.endedAt = t0 + 1
        XCTAssertEqual(signals.activity(at: t0 + 2), .none)
    }

    func testWorkspaceOrder() {
        XCTAssertEqual([AgentActivity.idle, .needsInput, .busy, .none].max(), .needsInput)
        XCTAssertEqual([AgentActivity.idle, .busy, .none].max(), .busy)
    }
}

final class ClaudeHookEventTests: XCTestCase {
    func testEvents() {
        XCTAssertEqual(ClaudeHook.event(fromHookInput: Data(#"{"hook_event_name":"UserPromptSubmit","prompt":"hi"}"#.utf8)), .working)
        XCTAssertEqual(ClaudeHook.event(fromHookInput: Data(#"{"hook_event_name":"SessionEnd"}"#.utf8)), .ended)
        XCTAssertEqual(ClaudeHook.event(fromHookInput: Data(#"{"hook_event_name":"Notification","message":"Waiting"}"#.utf8)),
                       .needsInput(.init(title: "Claude Code", body: "Waiting")))
    }

    func testForwardedInputKeepsOnlyUsedFields() {
        let raw = Data(#"{"hook_event_name":"Stop","transcript_path":"/x","last_assistant_message":"Done.\nMore","session_id":"s"}"#.utf8)
        let event = ClaudeHook.event(fromHookInput: raw)!
        let forwarded = ClaudeHook.forwardedInput(fromHookInput: raw, event: event)
        XCTAssertEqual(forwarded, .object(["hook_event_name": .string("Stop"), "title": .string("Claude Code"),
                                           "last_assistant_message": .string("Done.")]))
        let data = try! JSONEncoder().encode(forwarded)
        XCTAssertEqual(ClaudeHook.event(fromHookInput: data, readTranscript: false), event)
        let prompt = ClaudeHook.forwardedInput(fromHookInput: Data(#"{"hook_event_name":"UserPromptSubmit","prompt":"secret"}"#.utf8), event: .working)
        XCTAssertEqual(prompt, .object(["hook_event_name": .string("UserPromptSubmit")]))
    }
}
