import CmdsCore
import XCTest
@testable import cmds_cli

/// `cmds mcp` (#76): the JSON-RPC handling and the tools, with the app API replaced by a recorder.
final class MCPServerTests: XCTestCase {
    private struct Request { let method: String; let params: [String: JSONValue?] }

    private var requests: [Request] = []
    private var replies: [String: JSONValue] = [:]
    private var failure: CLIError?

    private func server(inside: Bool = true) -> MCPServer {
        let environment = inside ? ["CMDS_PANE_ID": "p1", "CMDS_WORKSPACE_ID": "w1"] : [:]
        return MCPServer(environment: environment) { [unowned self] method, params, _ in
            self.requests.append(Request(method: method, params: params))
            if let failure = self.failure { throw failure }
            return self.replies[method] ?? .object([:])
        }
    }

    private func send(_ server: MCPServer, _ line: String) -> JSONValue? {
        server.handle(line: line)
    }

    private func callTool(_ server: MCPServer, _ name: String, _ arguments: String = "{}") -> JSONValue? {
        send(server, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#)?["result"]
    }

    private func text(_ result: JSONValue?) -> String? {
        result?["content"]?.arrayValue?.first?["text"]?.stringValue
    }

    func testInitializeNegotiatesTheVersionAndGivesInstructions() throws {
        let response = try XCTUnwrap(send(server(), #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#))
        XCTAssertEqual(response["id"], .number(1))
        XCTAssertEqual(response["result"]?["protocolVersion"]?.stringValue, "2025-03-26")
        XCTAssertEqual(response["result"]?["serverInfo"]?["name"]?.stringValue, "cmds")
        XCTAssertNotNil(response["result"]?["capabilities"]?["tools"])
        XCTAssertTrue(response["result"]?["instructions"]?.stringValue?.contains("instead of Chrome") == true)

        let unknown = send(server(), #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual(unknown?["id"], .string("a"))
        XCTAssertEqual(unknown?["result"]?["protocolVersion"]?.stringValue, MCPServer.protocolVersions[0])
    }

    func testNotificationsGetNoResponseAndUnknownMethodsAnError() {
        let server = server()
        XCTAssertNil(send(server, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertEqual(send(server, #"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#)?["error"]?["code"], .number(-32601))
        XCTAssertEqual(send(server, "not json")?["error"]?["code"], .number(-32700))
        XCTAssertEqual(send(server, #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)?["result"], .object([:]))
        XCTAssertEqual(send(server, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nope"}}"#)?["error"]?["code"], .number(-32602))
    }

    func testToolsAreListedOnlyInsideCmds() {
        let inside = send(server(), #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)?["result"]?["tools"]?.arrayValue ?? []
        XCTAssertEqual(inside.compactMap { $0["name"]?.stringValue },
                       ["browser_open", "browser_navigate", "browser_url", "browser_eval", "browser_snapshot",
                        "open_file", "close_pane", "set_status"])
        XCTAssertEqual(send(server(inside: false), #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)?["result"]?["tools"], .array([]))

        let result = callTool(server(inside: false), "browser_open", #"{"url":"http://localhost:3000"}"#)
        XCTAssertEqual(result?["isError"], .bool(true))
        XCTAssertTrue(requests.isEmpty)
    }

    func testBrowserOpenSplitsWithoutFocusAndLaterToolsUseThatPane() {
        let server = server()
        replies["browser.open"] = .object(["id": "p9"])
        XCTAssertEqual(text(callTool(server, "browser_open", #"{"url":"http://localhost:3000"}"#)), "Opened browser pane p9.")
        XCTAssertEqual(requests.last?.method, "browser.open")
        XCTAssertEqual(requests.last?.params["pane"] ?? nil, .string("p1"))
        XCTAssertEqual(requests.last?.params["focus"] ?? nil, .bool(false))

        replies["browser.eval"] = .object(["value": .object(["n": 1])])
        XCTAssertEqual(text(callTool(server, "browser_eval", #"{"script":"({n: 1})"}"#)), #"{"n":1}"#)
        XCTAssertEqual(requests.last?.params["pane"] ?? nil, .string("p9"))

        _ = callTool(server, "browser_url", #"{"pane":"p4"}"#)
        XCTAssertEqual(requests.last?.params["pane"] ?? nil, .string("p4"))
    }

    func testBrowserToolsWithoutAnOpenedPaneTargetTheWorkspace() {
        _ = callTool(server(), "browser_url")
        XCTAssertNil(requests.last?.params["pane"] ?? nil)
        XCTAssertEqual(requests.last?.params["workspace"] ?? nil, .string("w1"))
    }

    func testSnapshotReturnsAnImage() throws {
        replies["browser.snapshot"] = .object(["png_base64": "iVBORw0K"])
        let content = try XCTUnwrap(callTool(server(), "browser_snapshot")?["content"]?.arrayValue?.first)
        XCTAssertEqual(content["type"]?.stringValue, "image")
        XCTAssertEqual(content["mimeType"]?.stringValue, "image/png")
        XCTAssertEqual(content["data"]?.stringValue, "iVBORw0K")
    }

    func testClosePaneOnlyClosesPanesTheServerOpened() {
        let server = server()
        let refused = callTool(server, "close_pane", #"{"pane":"p1"}"#)
        XCTAssertEqual(refused?["isError"], .bool(true))
        XCTAssertTrue(requests.isEmpty)

        replies["browser.open"] = .object(["id": "p9"])
        _ = callTool(server, "browser_open", #"{"url":"https://example.com"}"#)
        XCTAssertEqual(callTool(server, "close_pane", #"{"pane":"p9"}"#)?["isError"], .bool(false))
        XCTAssertEqual(requests.last?.method, "pane.close")
        XCTAssertEqual(server.openedPanes, [])
        XCTAssertEqual(callTool(server, "close_pane", #"{"pane":"p9"}"#)?["isError"], .bool(true))
    }

    func testOpenFileChecksThePathAndOpensWithoutFocus() throws {
        let server = server()
        XCTAssertEqual(callTool(server, "open_file", #"{"path":"/nonexistent/cmds-mcp-test.md"}"#)?["isError"], .bool(true))
        XCTAssertTrue(requests.isEmpty)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-mcp-test-\(UUID().uuidString).diff")
        try Data("--- a\n+++ b\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        replies["pane.open_file"] = .object(["id": "p5"])
        let result = callTool(server, "open_file", #"{"path":"\#(file.path)","diff":true}"#)
        XCTAssertEqual(result?["isError"], .bool(false))
        XCTAssertEqual(requests.last?.params["focus"] ?? nil, .bool(false))
        XCTAssertEqual(requests.last?.params["format"] ?? nil, .string("diff"))
        XCTAssertEqual(server.openedPanes, ["p5"])
    }

    func testAppErrorsBecomeToolErrors() {
        failure = CLIError.failure("no browser pane in workspace w1")
        let result = callTool(server(), "browser_eval", #"{"script":"1"}"#)
        XCTAssertEqual(result?["isError"], .bool(true))
        XCTAssertEqual(text(result), "no browser pane in workspace w1")
        XCTAssertEqual(callTool(server(), "browser_eval")?["isError"], .bool(true))  // missing script
    }
}
