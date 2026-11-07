import XCTest
@testable import CmdsCore

final class AntigravityStatusLineTests: XCTestCase {
    /// The shape agy 1.5.2 passes its status-line command (values shortened; `email` is never read).
    private let sample = """
    {"cwd":"/tmp/w","session_id":"","conversation_id":"c-123","transcript_path":"/x/transcript.jsonl",
     "model":{"id":"Gemini 4 Argon (Medium)","display_name":"Gemini 4 Argon (Medium)","effort":"medium"},
     "version":"1.5.2",
     "context_window":{"total_input_tokens":52428,"total_output_tokens":900,"context_window_size":1048576,
                       "used_percentage":5,"remaining_percentage":95,"current_usage":null},
     "product":"antigravity",
     "quota":{"3p-5h":{"remaining_fraction":1,"reset_time":"2026-11-07T03:51:16Z","reset_in_seconds":17999},
              "gemini-5h":{"remaining_fraction":0.9410565,"reset_time":"2026-11-07T01:10:41Z","reset_in_seconds":8364},
              "gemini-argon-wtu-weekly":{"remaining_fraction":0,"reset_time":"2026-11-07T08:06:55Z"},
              "gemini-weekly":{"remaining_fraction":0.97579914,"reset_time":"2026-11-12T09:25:13Z"}},
     "agent_state":"idle","plan_tier":"Google AI Pro","email":"someone@example.com","terminal_width":80}
    """

    func testParsesModelContextAndQuota() throws {
        let now = Date(timeIntervalSince1970: 1_794_000_000)
        let usage = try XCTUnwrap(AntigravityStatusLine.usage(fromJSON: Data(sample.utf8), now: now))
        XCTAssertEqual(usage.agent, .antigravity)
        XCTAssertEqual(usage.model, "Gemini 4 Argon (Medium)")
        XCTAssertEqual(usage.effort, "medium")
        XCTAssertEqual(usage.sessionID, "c-123")
        XCTAssertEqual(usage.contextUsedPercent, 5)
        XCTAssertEqual(usage.contextWindow, 1_048_576)
        XCTAssertEqual(usage.contextTokens, 52428)
        XCTAssertEqual(usage.plan, "Google AI Pro")
        XCTAssertEqual(usage.updatedAt, now)
        XCTAssertEqual(usage.limits.map(\.id), ["gemini-5h", "gemini-weekly", "gemini-argon-wtu-weekly", "3p-5h"])
        let gemini = try XCTUnwrap(usage.limits.first { $0.id == "gemini-5h" })
        XCTAssertEqual(gemini.usedPercent, 5.89435, accuracy: 0.001)
        XCTAssertEqual(gemini.windowMinutes, 300)
        XCTAssertEqual(gemini.resetsAt, FlexibleDate.date(from: "2026-11-07T01:10:41Z"))
        XCTAssertEqual(usage.limits.first { $0.id == "gemini-argon-wtu-weekly" }?.usedPercent, 100)
        // Nothing of the account's identity is kept.
        let encoded = String(decoding: try JSONEncoder().encode(usage), as: UTF8.self)
        XCTAssertFalse(encoded.contains("example.com"))
    }

    func testLabelsNameTheModelGroup() {
        func label(_ id: String) -> String {
            AgentFormat.limitLabel(UsageLimit(id: id, usedPercent: 1, windowMinutes: AntigravityStatusLine.windowMinutes(id)))
        }
        XCTAssertEqual(label("gemini-5h"), "Gemini 5h")
        XCTAssertEqual(label("gemini-weekly"), "Gemini 7d")
        XCTAssertEqual(label("3p-5h"), "3P 5h")
        XCTAssertEqual(label("3p-weekly"), "3P 7d")
        XCTAssertEqual(label("gemini-argon-wtu-weekly"), "Argon 7d")
        // Claude and Codex labels are unchanged.
        XCTAssertEqual(AgentFormat.limitLabel(UsageLimit(id: UsageLimit.fiveHour, usedPercent: 1)), "5h")
        XCTAssertEqual(AgentFormat.limitLabel(UsageLimit(id: "primary", usedPercent: 1, windowMinutes: 300)), "5h")
        XCTAssertNil(AntigravityStatusLine.groupName("primary"))
        XCTAssertNil(AntigravityStatusLine.windowMinutes("gemini-monthly"))
    }

    func testRejectsOtherInput() {
        XCTAssertNil(AntigravityStatusLine.usage(fromJSON: Data("not json".utf8)))
        XCTAssertNil(AntigravityStatusLine.usage(fromJSON: Data(#"{"cwd":"/tmp"}"#.utf8)))
        XCTAssertEqual(AgentProcessClassifier.agent(executablePath: "/Users/me/.local/bin/agy", arguments: ["agy"]), .antigravity)
        XCTAssertEqual(AgentKind(rawValue: "antigravity")?.displayName, "Antigravity")
    }
}
