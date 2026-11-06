import XCTest
@testable import CmdsCore

final class CodexHookTests: XCTestCase {
    private func payload(_ object: [String: Any]) -> CodexHook.Payload? {
        CodexHook.payload(fromHookInput: try! JSONSerialization.data(withJSONObject: object))
    }

    private let common: [String: Any] = [
        "session_id": "019a-thread", "cwd": "/Users/me/src/app", "transcript_path": NSNull(), "model": "gpt-5.5",
        "permission_mode": "default",
    ]

    private func with(_ extra: [String: Any]) -> [String: Any] { common.merging(extra) { $1 } }

    func testWorkingEvents() {
        for name in ["UserPromptSubmit", "PreToolUse", "PostToolUse"] {
            let parsed = payload(with(["hook_event_name": name, "turn_id": "t1", "prompt": "secret prompt"]))
            XCTAssertEqual(parsed?.event, .working, name)
            XCTAssertEqual(parsed?.sessionID, "019a-thread")
            XCTAssertEqual(parsed?.cwd, "/Users/me/src/app")
        }
        XCTAssertEqual(payload(with(["hook_event_name": "Interrupt", "turn_id": "t1"]))?.event, .interrupted)
    }

    func testStopNotifiesWithTheFirstLineOfTheReply() {
        let parsed = payload(with(["hook_event_name": "Stop", "turn_id": "t1", "stop_hook_active": false,
                                   "last_assistant_message": "\nFixed the invoice PDF.\nDetails follow."]))
        XCTAssertEqual(parsed?.event, .finished(.init(title: "Codex", body: "Fixed the invoice PDF.")))
        XCTAssertEqual(payload(with(["hook_event_name": "Stop", "last_assistant_message": NSNull()]))?.event.notification?.body,
                       "Finished")
        XCTAssertNil(payload(with(["hook_event_name": "Stop", "stop_hook_active": true, "last_assistant_message": "x"])))
    }

    func testPermissionRequestSaysWhatCodexWantsToDo() {
        let described = payload(with(["hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                      "tool_input": ["command": "rm -rf build", "description": "Remove the build folder"]]))
        XCTAssertEqual(described?.event, .needsInput(.init(title: "Codex", body: "Remove the build folder")))
        let command = payload(with(["hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                    "tool_input": ["command": "make test", "description": NSNull()]]))
        XCTAssertEqual(command?.event.notification?.body, "make test")
        let array = payload(with(["hook_event_name": "PermissionRequest", "tool_input": ["command": ["git", "push"]]]))
        XCTAssertEqual(array?.event.notification?.body, "git push")
        let tool = payload(with(["hook_event_name": "PermissionRequest", "tool_name": "apply_patch", "tool_input": [:]]))
        XCTAssertEqual(tool?.event.notification?.body, "Approve apply_patch?")
    }

    func testIgnoredInput() {
        // SessionEnd also fires after 30 idle minutes: it must not end the pane's agent.
        for name in ["SessionStart", "SessionEnd", "SubagentStart", "SubagentStop", "PreCompact", "Notification", ""] {
            XCTAssertNil(payload(with(["hook_event_name": name])), name)
        }
        XCTAssertNil(payload(common))
        XCTAssertNil(CodexHook.payload(fromHookInput: Data("not json".utf8)))
        XCTAssertNil(CodexHook.payload(fromHookInput: Data("[1]".utf8)))
    }

    func testForwardedInputCarriesNoPromptOrToolInputAndRoundTrips() throws {
        let original = try XCTUnwrap(payload(with(["hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                                   "tool_input": ["command": "cat ~/.secret", "description": "Read a file"]])))
        let forwarded = CodexHook.forwardedInput(original)
        let text = String(decoding: try JSONEncoder().encode(forwarded), as: UTF8.self)
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("gpt-5.5"))
        XCTAssertEqual(CodexHook.payload(fromForwarded: forwarded), original)

        for extra: [String: Any] in [["hook_event_name": "Stop", "last_assistant_message": "Done"],
                                     ["hook_event_name": "UserPromptSubmit", "prompt": "secret prompt"],
                                     ["hook_event_name": "Interrupt"]] {
            let parsed = try XCTUnwrap(payload(with(extra)))
            let forwarded = CodexHook.forwardedInput(parsed)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(forwarded), as: UTF8.self).contains("secret"))
            XCTAssertEqual(CodexHook.payload(fromForwarded: forwarded), parsed)
        }
        XCTAssertNil(CodexHook.payload(fromForwarded: .object(["hook_event_name": .string("SessionEnd")])))
        XCTAssertNil(CodexHook.payload(fromForwarded: .string("Stop")))
    }

    func testOnlyStopPrintsJSON() {
        func output(_ name: String) -> String? {
            CodexHook.standardOutput(forHookInput: try! JSONSerialization.data(withJSONObject: ["hook_event_name": name]))
        }
        XCTAssertEqual(output("Stop"), "{}")
        XCTAssertEqual(output("SubagentStop"), "{}")
        for name in ["UserPromptSubmit", "PreToolUse", "PermissionRequest", "Interrupt", "SessionStart"] {
            XCTAssertNil(output(name), name)
        }
        XCTAssertNil(CodexHook.standardOutput(forHookInput: Data("x".utf8)))
    }

    func testTargetPaneBySessionThenByDirectory() {
        let panes: [CodexHook.Pane] = [
            .init(paneID: "p1", cwd: "/Users/me/src/app", sessionID: "s1"),
            .init(paneID: "p2", cwd: "/Users/me/src/app", sessionID: nil),
            .init(paneID: "p3", cwd: "/Users/me/src/other", sessionID: nil),
        ]
        // The pane holding the session, whatever CMDS_PANE_ID the (daemon's) hook has.
        XCTAssertEqual(CodexHook.targetPane(sessionID: "s1", cwd: "/Users/me/src/app", envPane: "p3", panes: panes), "p1")
        // A new session: the only pane without a known session in that directory.
        XCTAssertEqual(CodexHook.targetPane(sessionID: "new", cwd: "/Users/me/src/app", envPane: "p1", panes: panes), "p2")
        XCTAssertEqual(CodexHook.targetPane(sessionID: "new", cwd: "/private/Users/me/src/other", envPane: nil, panes: panes), "p3")
        // Without a directory both p2 and p3 could be it: the environment's pane decides, else nobody.
        XCTAssertEqual(CodexHook.targetPane(sessionID: "new", cwd: nil, envPane: "p3", panes: panes), "p3")
        XCTAssertNil(CodexHook.targetPane(sessionID: "new", cwd: nil, envPane: "p1", panes: panes))
        XCTAssertNil(CodexHook.targetPane(sessionID: nil, cwd: nil, envPane: nil, panes: panes))
        // A directory with no such pane, or no Codex pane at all.
        XCTAssertNil(CodexHook.targetPane(sessionID: "new", cwd: "/tmp", envPane: "p2", panes: panes))
        XCTAssertNil(CodexHook.targetPane(sessionID: "s1", cwd: nil, envPane: "p1", panes: []))
    }
}
