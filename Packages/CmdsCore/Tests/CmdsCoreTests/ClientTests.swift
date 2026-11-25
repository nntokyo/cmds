import XCTest
@testable import CmdsCore

final class ClientLineBufferTests: XCTestCase {
    func testSplitsPartialAndMultipleLines() throws {
        var buffer = JSONLineBuffer()
        XCTAssertEqual(try buffer.append(Data("{\"a\"".utf8)), [])
        XCTAssertEqual(buffer.pendingCount, 4)
        let lines = try buffer.append(Data(":1}\n\n{\"b\":2}\r\n{\"c\"".utf8))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["{\"a\":1}", "{\"b\":2}"])
        XCTAssertEqual(try buffer.append(Data(":3}\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["{\"c\":3}"])
        XCTAssertEqual(buffer.pendingCount, 0)
    }

    func testRejectsOverlongLine() throws {
        var buffer = JSONLineBuffer(maxLineLength: 8)
        XCTAssertEqual(try buffer.append(Data("12345678\n".utf8)).count, 1)
        XCTAssertThrowsError(try buffer.append(Data("123456789".utf8)))
        var other = JSONLineBuffer(maxLineLength: 8)
        XCTAssertThrowsError(try other.append(Data("123456789\n".utf8)))
    }

    func testEncodeLineIsSingleLine() throws {
        let data = try JSONLineBuffer.encodeLine(RPCRequest(id: 1, method: "notify", params: ["body": "a\nb"]))
        XCTAssertEqual(data.last, 0x0A)
        XCTAssertEqual(data.filter { $0 == 0x0A }.count, 1)
    }
}

final class ClientSocketTests: XCTestCase {
    private var path = ""
    private var listener: Int32 = -1

    override func setUpWithError() throws {
        path = "/tmp/cmds-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
        unlink(path)
        listener = try UnixSocket.makeStreamSocket()
        try UnixSocket.bindAndListen(listener, path: path)
    }

    override func tearDown() {
        close(listener)
        unlink(path)
    }

    /// Accepts one connection and answers each request line with `respond`.
    private func serve(_ respond: @escaping @Sendable (RPCRequest) -> [String]) {
        let listener = listener
        Thread.detachNewThread {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var buffer = JSONLineBuffer()
            while let chunk = try? UnixSocket.read(fd), !chunk.isEmpty {
                for line in (try? buffer.append(chunk)) ?? [] {
                    guard let request = try? JSONDecoder().decode(RPCRequest.self, from: line) else { continue }
                    for reply in respond(request) { try? UnixSocket.writeAll(fd, Data((reply + "\n").utf8)) }
                }
            }
        }
    }

    func testCallReturnsResultAndQueuesEvents() throws {
        serve { request in
            [#"{"event":"notification","params":{"body":"hi"}}"#,
             #"{"id":\#(request.id),"result":{"method":"\#(request.method)"}}"#]
        }
        let client = try CmdsClient(socketPath: path, timeout: 5)
        let result = try client.call("system.ping")
        XCTAssertEqual(result["method"]?.stringValue, "system.ping")
        let event = try client.nextEvent()
        XCTAssertEqual(event?.event, "notification")
        XCTAssertEqual(event?.params?["body"]?.stringValue, "hi")
    }

    func testCallThrowsRPCError() throws {
        serve { request in [#"{"id":\#(request.id),"error":{"code":404,"message":"pane not found: p9"}}"#] }
        let client = try CmdsClient(socketPath: path, timeout: 5)
        XCTAssertThrowsError(try client.call("pane.focus", params: ["pane": "p9"])) { error in
            XCTAssertEqual((error as? RPCError)?.code, 404)
            XCTAssertEqual((error as? RPCError)?.message, "pane not found: p9")
        }
    }

    func testVoidResultIsNull() throws {
        serve { request in [#"{"id":\#(request.id)}"#] }
        let client = try CmdsClient(socketPath: path, timeout: 5)
        XCTAssertEqual(try client.call("pane.focus"), .null)
    }

    func testNextEventReturnsNilOnClose() throws {
        serve { _ in [] }
        let client = try CmdsClient(socketPath: path, timeout: 5)
        // The server closes after we shut down our write side.
        shutdown(client.fd, SHUT_WR)
        XCTAssertNil(try client.nextEvent())
    }

    func testNotRunning() {
        XCTAssertThrowsError(try CmdsClient(socketPath: "/tmp/cmds-missing-\(getpid()).sock")) { error in
            guard case .notRunning? = error as? CmdsClient.ClientError else { return XCTFail("\(error)") }
        }
    }
}

final class ClientClaudeHookTests: XCTestCase {
    func testNotificationEvent() {
        let input = #"{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash","cwd":"/tmp"}"#
        XCTAssertEqual(ClaudeHook.notification(fromHookInput: Data(input.utf8)),
                       .init(title: "Claude Code", body: "Claude needs your permission to use Bash"))
    }

    /// Claude Code's notice a minute after a turn ended is not a question: the agent sits at its prompt.
    func testIdleNoticeIsNotAQuestion() {
        func event(_ json: String) -> ClaudeHook.Event? { ClaudeHook.event(fromHookInput: Data(json.utf8)) }
        let idleNote = ClaudeHook.Notification(title: "Claude Code", body: "Claude is waiting for your input")
        let idle = #"{"hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}"#
        XCTAssertEqual(event(idle), .atPrompt(idleNote))
        // Older Claude Code: no type, told by the message.
        XCTAssertEqual(event(#"{"hook_event_name":"Notification","message":"Claude is waiting for your input"}"#), .atPrompt(idleNote))
        // A permission prompt, with or without a type, asks.
        let permission = ClaudeHook.Notification(title: "Claude Code", body: "Claude needs your permission to use Bash")
        XCTAssertEqual(event(#"{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}"#),
                       .needsInput(permission))
        XCTAssertEqual(event(#"{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}"#), .needsInput(permission))
        // The type decides, not the words.
        let worded = #"{"hook_event_name":"Notification","message":"The script is waiting for your input: allow?","notification_type":"permission_prompt"}"#
        guard case .needsInput? = event(worded) else { return XCTFail("a typed permission prompt must ask") }
        // What the CLI forwards to the app keeps the difference.
        for (json, expected) in [(idle, "idle_prompt"), (worded, "permission_prompt")] {
            let forwarded = ClaudeHook.forwardedInput(fromHookInput: Data(json.utf8), event: event(json)!)
            XCTAssertEqual(forwarded["notification_type"]?.stringValue, expected)
            let again = ClaudeHook.event(fromHookInput: try! JSONEncoder().encode(forwarded), readTranscript: false)
            XCTAssertEqual(again, event(json))
        }
        // A prompt without a type whose words say "waiting for your input" is forwarded as a question.
        let untyped = #"{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}"#
        XCTAssertEqual(ClaudeHook.forwardedInput(fromHookInput: Data(untyped.utf8), event: event(untyped)!)["notification_type"]?.stringValue,
                       "permission_prompt")
    }

    func testStopEventReadsTranscriptTail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\nAll tests pass.\nDetails follow"}]}}"#,
            #"{"type":"system","content":"x"}"#,
        ]
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let input = #"{"hook_event_name":"Stop","stop_hook_active":false,"transcript_path":"\#(url.path)"}"#
        XCTAssertEqual(ClaudeHook.notification(fromHookInput: Data(input.utf8))?.body, "All tests pass.")
    }

    func testLastAssistantTextDropsTheLineCutByTheTail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = #"{"type":"assistant","message":{"content":"older reply"}}"#
        let second = #"{"type":"assistant","message":{"content":[{"type":"text","text":" \n "},{"type":"tool_use"}]}}"#
        try [first, second].joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeHook.lastAssistantText(transcriptPath: url.path), "older reply")
        // A tail that starts inside the first line drops it as cut mid-line: no text left.
        XCTAssertNil(ClaudeHook.lastAssistantText(transcriptPath: url.path, tailBytes: second.utf8.count + 3))
        XCTAssertNil(ClaudeHook.lastAssistantText(transcriptPath: "/nonexistent.jsonl"))
    }

    func testStopWithoutTranscript() {
        let input = #"{"hook_event_name":"Stop","transcript_path":"/nonexistent.jsonl"}"#
        XCTAssertEqual(ClaudeHook.notification(fromHookInput: Data(input.utf8))?.body, "Finished")
    }

    func testIgnoredEvents() {
        XCTAssertNil(ClaudeHook.notification(fromHookInput: Data(#"{"hook_event_name":"PreToolUse"}"#.utf8)))
        XCTAssertNil(ClaudeHook.notification(fromHookInput: Data(#"{"hook_event_name":"Stop","stop_hook_active":true}"#.utf8)))
        XCTAssertNil(ClaudeHook.notification(fromHookInput: Data("not json".utf8)))
    }

    func testLongBodyIsTruncated() {
        let input = #"{"hook_event_name":"Notification","message":"\#(String(repeating: "x", count: 500))"}"#
        XCTAssertEqual(ClaudeHook.notification(fromHookInput: Data(input.utf8))?.body.count, ClaudeHook.maxBodyLength)
    }
}
