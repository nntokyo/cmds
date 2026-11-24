import Foundation
import XCTest
@testable import CmdsCore

/// Was a Claude Code turn cut off? From the end of its transcript.
final class ClaudeTurnStateTests: XCTestCase {
    private func tail(_ lines: [String]) -> Data { Data(("{\"partial line" + "\n" + lines.joined(separator: "\n") + "\n").utf8) }
    private let user = #"{"type":"user","message":{"role":"user","content":"fix the tests"}}"#
    private let toolUse = #"{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use"}]}}"#
    private let toolResult = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#
    private let done = #"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}"#
    private let other = #"{"type":"system","subtype":"turn_duration"}"#

    func testFinishedTurns() {
        XCTAssertEqual(ClaudeTurnState.cutOff(transcriptTail: tail([user, toolUse, toolResult, done, other])), false)
        let esc = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        XCTAssertEqual(ClaudeTurnState.cutOff(transcriptTail: tail([user, toolUse, esc])), false, "stopped by the user")
        let command = #"{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>"}}"#
        XCTAssertEqual(ClaudeTurnState.cutOff(transcriptTail: tail([done, command])), false, "a local command")
        let meta = #"{"type":"user","isMeta":true,"message":{"role":"user","content":"Caveat"}}"#
        XCTAssertEqual(ClaudeTurnState.cutOff(transcriptTail: tail([done, meta])), false)
    }

    func testCutOffTurns() {
        XCTAssertEqual(ClaudeTurnState.cutOff(transcriptTail: tail([done, user, toolUse])), true, "a tool call without its result")
        XCTAssertEqual(ClaudeTurnState.cutOff(transcriptTail: tail([done, user, toolUse, toolResult, other])), true, "mid tool loop")
        XCTAssertEqual(ClaudeTurnState.cutOff(transcriptTail: tail([done, user])), true, "a prompt without a reply")
        XCTAssertNil(ClaudeTurnState.cutOff(transcriptTail: tail([other])))
    }

    func testReadsTheSessionsTranscript() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("turn-\(UUID().uuidString)")
        let folder = home.appendingPathComponent(".claude/projects/-tmp-app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let id = "11111111-2222-4333-8444-555555555555"
        try tail([user, toolUse]).write(to: folder.appendingPathComponent("\(id).jsonl"))
        XCTAssertEqual(ClaudeTurnState.cutOff(sessionID: id, configDir: nil, home: home.path), true)
        XCTAssertNil(ClaudeTurnState.cutOff(sessionID: "22222222-2222-4333-8444-555555555555", configDir: nil, home: home.path))
    }
}
