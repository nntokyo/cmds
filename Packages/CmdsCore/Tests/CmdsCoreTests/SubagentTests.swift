import XCTest
@testable import CmdsCore

final class SubagentTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-subagent-\(UUID().uuidString)")
            .appendingPathComponent("projects/-Users-me-proj/sess-1/subagents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent())
    }

    func testStartDerivesTranscriptPathFromParent() throws {
        let parent = dir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("sess-1.jsonl").path
        let json = #"{"hook_event_name":"SubagentStart","session_id":"sess-1","transcript_path":"\#(parent)","agent_id":"a1b2","agent_type":"Explore","prompt":"secret"}"#
        guard case .subagent(let agent)? = ClaudeHook.event(fromHookInput: Data(json.utf8)) else { return XCTFail() }
        XCTAssertTrue(agent.started)
        XCTAssertEqual(agent.agentID, "a1b2")
        XCTAssertEqual(agent.agentType, "Explore")
        XCTAssertEqual(agent.transcriptPath, dir.appendingPathComponent("agent-a1b2.jsonl").path)
        let forwarded = ClaudeHook.forwardedInput(fromHookInput: Data(json.utf8), event: .subagent(agent))
        XCTAssertEqual(forwarded, .object([
            "hook_event_name": "SubagentStart", "agent_id": "a1b2", "agent_type": "Explore",
            "agent_transcript_path": .string(agent.transcriptPath!),
        ]))
    }

    func testStopUsesItsPathAndDropsTheMessage() throws {
        let path = dir.appendingPathComponent("agent-a1b2.jsonl").path
        let json = #"{"hook_event_name":"SubagentStop","agent_id":"a1b2","agent_type":"general-purpose","agent_transcript_path":"\#(path)","last_assistant_message":"secret"}"#
        guard case .subagent(let agent)? = ClaudeHook.event(fromHookInput: Data(json.utf8)) else { return XCTFail() }
        XCTAssertFalse(agent.started)
        XCTAssertEqual(agent.transcriptPath, path)
        let forwarded = ClaudeHook.forwardedInput(fromHookInput: Data(json.utf8), event: .subagent(agent))
        XCTAssertNil(forwarded["last_assistant_message"])
    }

    func testRejectsBadIDsAndPaths() {
        XCTAssertNil(ClaudeHook.event(fromHookInput: Data(#"{"hook_event_name":"SubagentStart"}"#.utf8)))
        XCTAssertNil(ClaudeHook.event(fromHookInput: Data(#"{"hook_event_name":"SubagentStart","agent_id":"../x"}"#.utf8)))
        XCTAssertNil(SubagentTranscript.validatedPath("/etc/passwd", agentID: "a1"))
        XCTAssertNil(SubagentTranscript.validatedPath("/x/projects/p/s/subagents/agent-a2.jsonl", agentID: "a1"))
        XCTAssertNil(SubagentTranscript.validatedPath("/x/projects/p/../subagents/agent-a1.jsonl", agentID: "a1"))
        XCTAssertNil(SubagentTranscript.validatedPath("x/projects/p/s/subagents/agent-a1.jsonl", agentID: "a1"))
        XCTAssertNotNil(SubagentTranscript.validatedPath("/x/projects/p/s/subagents/agent-a1.jsonl", agentID: "a1"))
        // Without a usable path the event still counts (remote panes, older Claude Code).
        guard case .subagent(let agent)? = ClaudeHook.event(fromHookInput: Data(
            #"{"hook_event_name":"SubagentStop","agent_id":"a1","agent_transcript_path":"/etc/passwd"}"#.utf8)) else { return XCTFail() }
        XCTAssertNil(agent.transcriptPath)
        XCTAssertNil(agent.agentType)
    }

    func testActivityFromTranscriptTail() throws {
        let path = dir.appendingPathComponent("agent-a1.jsonl")
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"do the secret thing"}}"#,
            #"{"type":"assistant","cwd":"/Users/me/proj","message":{"content":[{"type":"text","text":"secret reply"},{"type":"tool_use","name":"Read","input":{"file_path":"/Users/me/proj/Sources/main.swift"}}],"usage":{"input_tokens":10,"cache_read_input_tokens":12000,"output_tokens":90}}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"file body"}]}}"#,
            #"{"type":"assistant","cwd":"/Users/me/proj","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"API_TOKEN=abc123 swift test\nsecond line"}}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
        let activity = try XCTUnwrap(SubagentTranscript.activity(path: path.path))
        XCTAssertEqual(activity.action, "Bash: API_TOKEN=*** swift test")
        XCTAssertEqual(activity.tokens, 12100)
        XCTAssertNil(SubagentTranscript.activity(path: dir.appendingPathComponent("missing.jsonl").path))
    }

    func testDescribe() {
        XCTAssertEqual(SubagentTranscript.describe(tool: "Read", input: ["file_path": .string("/p/Sources/main.swift")], cwd: "/p"), "Read Sources/main.swift")
        XCTAssertEqual(SubagentTranscript.describe(tool: "Grep", input: ["pattern": "TODO"]), "Grep TODO")
        XCTAssertEqual(SubagentTranscript.describe(tool: "WebFetch", input: ["url": "https://example.com/a?b"]), "WebFetch example.com")
        XCTAssertEqual(SubagentTranscript.describe(tool: "mcp__x__y", input: ["q": "secret"]), "mcp__x__y")
        XCTAssertEqual(SubagentTranscript.describe(tool: "Bash", input: ["command": "curl --password hunter2 x"]), "Bash: curl --password *** x")
        XCTAssertEqual(SubagentTranscript.describe(tool: "Bash", input: ["command": .string(String(repeating: "a", count: 200))]).count,
                       SubagentTranscript.maxActionLength)
    }

    func testMeta() throws {
        let meta = dir.appendingPathComponent("agent-a1.meta.json")
        try #"{"agentType":"Explore","description":"Find the hook code","prompt":"secret","toolUseId":"t"}"#
            .write(to: meta, atomically: true, encoding: .utf8)
        let result = SubagentTranscript.meta(transcriptPath: dir.appendingPathComponent("agent-a1.jsonl").path)
        XCTAssertEqual(result, SubagentTranscript.Meta(agentType: "Explore", description: "Find the hook code"))
    }
}
