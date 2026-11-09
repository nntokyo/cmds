import CmdsCore
import XCTest
@testable import cmds_cli

private extension ConsoleBuffer {
    static var sample: ConsoleBuffer {
        var buffer = ConsoleBuffer()
        buffer.append(ConsoleEntry(level: .error, source: .rejection, text: "Error: boom", time: 0))
        return buffer
    }
}

/// `cmds mcp` (#76): the JSON-RPC handling and the tools, with the app API replaced by a recorder.
final class MCPServerTests: XCTestCase {
    private struct Request { let method: String; let params: [String: JSONValue?] }

    private var requests: [Request] = []
    private var replies: [String: JSONValue] = [:]
    private var failure: CLIError?
    /// Panes the stub app no longer has: requests to them fail like the app's "pane not found".
    private var closedPanes: Set<String> = []
    /// The stub app's `Pane.openedBy`: pane id → the terminal pane it was opened from.
    private var openers: [String: String] = [:]

    private func server(inside: Bool = true) -> MCPServer {
        let environment = inside ? ["CMDS_PANE_ID": "p1", "CMDS_WORKSPACE_ID": "w1"] : [:]
        return MCPServer(environment: environment) { [unowned self] method, params, _ in
            self.requests.append(Request(method: method, params: params))
            if let failure = self.failure { throw failure }
            if let pane = params["pane"]??.stringValue, self.closedPanes.contains(pane) {
                throw CLIError.failure("pane not found: \(pane)")
            }
            if method == "pane.close", let pane = params["pane"]??.stringValue {
                if let openedBy = params["openedBy"]??.stringValue, self.openers[pane] != openedBy {
                    throw CLIError.failure("pane \(pane) was not opened from pane \(openedBy)")
                }
                self.closedPanes.insert(pane)
            }
            return self.replies[method] ?? .object([:])
        }
    }

    private func callTool(_ server: MCPServer, _ name: String, _ arguments: String = "{}") -> JSONValue? {
        server.handle(line: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#)?["result"]
    }

    private func text(_ result: JSONValue?) -> String? {
        result?["content"]?.arrayValue?.first?["text"]?.stringValue
    }

    func testInitializeNegotiatesTheVersionAndGivesInstructions() throws {
        let response = try XCTUnwrap(server().handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#))
        XCTAssertEqual(response["id"], .number(1))
        XCTAssertEqual(response["result"]?["protocolVersion"]?.stringValue, "2025-03-26")
        XCTAssertEqual(response["result"]?["serverInfo"]?["name"]?.stringValue, "cmds")
        XCTAssertNotNil(response["result"]?["capabilities"]?["tools"])
        XCTAssertTrue(response["result"]?["instructions"]?.stringValue?.contains("instead of Chrome") == true)

        let unknown = server().handle(line: #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual(unknown?["id"], .string("a"))
        XCTAssertEqual(unknown?["result"]?["protocolVersion"]?.stringValue, MCPServer.protocolVersions[0])
    }

    func testNotificationsGetNoResponseAndUnknownMethodsAnError() {
        let server = server()
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertEqual(server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#)?["error"]?["code"], .number(-32601))
        XCTAssertEqual(server.handle(line: "not json")?["error"]?["code"], .number(-32700))
        XCTAssertEqual(server.handle(line: "[]")?["error"]?["code"], .number(-32600))
        XCTAssertEqual(server.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)?["result"], .object([:]))
        XCTAssertEqual(server.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nope"}}"#)?["error"]?["code"], .number(-32602))
    }

    func testToolsAreListedOnlyInsideCmds() {
        let inside = server().handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)?["result"]?["tools"]?.arrayValue ?? []
        XCTAssertEqual(inside.compactMap { $0["name"]?.stringValue },
                       ["browser_open", "browser_navigate", "browser_url", "browser_eval", "browser_snapshot", "browser_set_viewport", "browser_console", "browser_snapshot_tree", "browser_click", "browser_fill", "browser_wait_for", "browser_responsive",
                        "open_file", "close_pane", "set_status"])
        XCTAssertEqual(server(inside: false).handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)?["result"]?["tools"], .array([]))

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

    /// browser_set_viewport (#168) sends `browser.set_viewport` with the same params as `cmds browser device`.
    func testSetViewport() {
        let server = server()
        replies["browser.set_viewport"] = BrowserEmulation(device: "iphone-se", size: .init(width: 667, height: 375),
                                                           userAgent: DevicePreset.iPhoneUserAgent, colorScheme: .dark).json
        let result = callTool(server, "browser_set_viewport", #"{"device":"iphone-se","rotate":true,"colorScheme":"dark","pane":"p4"}"#)
        XCTAssertEqual(result?["isError"], .bool(false))
        XCTAssertEqual(text(result), "iPhone SE 667×375 (rotated), user agent iPhone Safari, color scheme dark")
        XCTAssertEqual(requests.last?.method, "browser.set_viewport")
        XCTAssertEqual(requests.last?.params["pane"] ?? nil, .string("p4"))
        XCTAssertEqual(requests.last?.params["device"] ?? nil, .string("iphone-se"))
        XCTAssertEqual(requests.last?.params["rotate"] ?? nil, .bool(true))
        XCTAssertEqual(requests.last?.params["colorScheme"] ?? nil, .string("dark"))

        _ = callTool(server, "browser_set_viewport", #"{"device":"500x900","userAgent":""}"#)
        XCTAssertEqual(requests.last?.params["width"] ?? nil, .number(500))
        XCTAssertEqual(requests.last?.params["height"] ?? nil, .number(900))
        XCTAssertEqual(requests.last?.params["userAgent"] ?? nil, .string(""))
        XCTAssertEqual(requests.last?.params["workspace"] ?? nil, .string("w1"))

        // Bad values are refused before anything is sent.
        let count = requests.count
        XCTAssertEqual(callTool(server, "browser_set_viewport", #"{"device":"nokia"}"#)?["isError"], .bool(true))
        XCTAssertEqual(callTool(server, "browser_set_viewport", #"{"colorScheme":"sepia"}"#)?["isError"], .bool(true))
        XCTAssertEqual(requests.count, count)
        let definition = MCPServer.tools.first { $0.name == "browser_set_viewport" }?.definition
        XCTAssertTrue(definition?["description"]?.stringValue?.contains("device pixel ratio") == true)
    }

    /// browser_snapshot (#169): full page, element and several devices, one image per size after a line naming it.
    func testSnapshotVariants() {
        let server = server()
        replies["browser.snapshot"] = BrowserSnapshotImage.result([
            BrowserSnapshotImage(device: "iphone", width: 393, height: 2000, png: Data([1])),
            BrowserSnapshotImage(device: "ipad", width: 820, height: 1800, png: Data([2])),
        ])
        let result = callTool(server, "browser_snapshot", #"{"pane":"p4","fullPage":true,"devices":["iphone","ipad"]}"#)
        XCTAssertEqual(result?["isError"], .bool(false))
        let content = result?["content"]?.arrayValue ?? []
        XCTAssertEqual(content.map { $0["type"]?.stringValue ?? "" }, ["text", "image", "text", "image"])
        XCTAssertEqual(content[0]["text"]?.stringValue, "iphone, full page, 393×2000 CSS px")
        XCTAssertEqual(content[3]["data"]?.stringValue, Data([2]).base64EncodedString())
        XCTAssertEqual(requests.last?.params["fullPage"] ?? nil, .bool(true))
        XCTAssertEqual(requests.last?.params["devices"] ?? nil, .array(["iphone", "ipad"]))
        XCTAssertEqual(requests.last?.params["pane"] ?? nil, .string("p4"))

        // A plain snapshot stays one image.
        replies["browser.snapshot"] = BrowserSnapshotImage.result([BrowserSnapshotImage(device: nil, width: 1, height: 1, png: Data([1]))])
        XCTAssertEqual(callTool(server, "browser_snapshot")?["content"]?.arrayValue?.map { $0["type"]?.stringValue ?? "" }, ["image"])

        // Bad arguments are refused before anything is sent.
        let count = requests.count
        XCTAssertEqual(callTool(server, "browser_snapshot", #"{"device":"nokia"}"#)?["isError"], .bool(true))
        XCTAssertEqual(requests.count, count)

        // An app older than #169 ignores the params and returns the visible page: say so instead of passing it off.
        replies["browser.snapshot"] = .object(["png_base64": "AQ=="])
        let old = callTool(server, "browser_snapshot", #"{"selector":"h1"}"#)
        XCTAssertEqual(old?["isError"], .bool(true))
        XCTAssertTrue(text(old)?.contains("update cmds") == true)
        XCTAssertEqual(callTool(server, "browser_snapshot")?["isError"], .bool(false))
    }

    /// browser_responsive (#170): with a url it opens a pane (recorded as ours) and turns the view on.
    func testResponsive() {
        let server = server()
        replies["browser.open"] = .object(["id": "p9"])
        replies["browser.set_responsive"] = BrowserResponsive(devices: ["iphone-se", "ipad"]).json
        let opened = callTool(server, "browser_responsive", #"{"url":"http://localhost:3000","devices":["iphone-se","ipad"]}"#)
        XCTAssertEqual(text(opened), "Opened browser pane p9: responsive view: iphone-se, ipad.")
        XCTAssertEqual(requests.map(\.method), ["browser.open", "browser.set_responsive"])
        XCTAssertEqual(requests[0].params["focus"] ?? nil, .bool(false))
        XCTAssertEqual(requests[1].params["pane"] ?? nil, .string("p9"))
        XCTAssertEqual(requests[1].params["on"] ?? nil, .bool(true))
        XCTAssertEqual(requests[1].params["devices"] ?? nil, .array(["iphone-se", "ipad"]))
        XCTAssertEqual(server.openedPanes, ["p9"])

        replies["browser.set_responsive"] = BrowserResponsive.offJSON
        XCTAssertEqual(text(callTool(server, "browser_responsive", #"{"off":true}"#)), "responsive view off")
        XCTAssertEqual(requests.last?.params["on"] ?? nil, .bool(false))
        XCTAssertEqual(requests.last?.params["pane"] ?? nil, .string("p9"), "the pane this server opened last")

        let count = requests.count
        XCTAssertEqual(callTool(server, "browser_responsive", #"{"devices":["iphone"]}"#)?["isError"], .bool(true))
        XCTAssertEqual(callTool(server, "browser_responsive", #"{"url":"http://x.test","pane":"p2"}"#)?["isError"], .bool(true))
        XCTAssertEqual(requests.count, count)

        // A responsive pane's plain snapshot: one labelled image per frame.
        replies["browser.snapshot"] = BrowserSnapshotImage.result([
            BrowserSnapshotImage(device: "iphone", width: 393, height: 852, png: Data([1])),
            BrowserSnapshotImage(device: "ipad", width: 820, height: 1180, png: Data([2])),
        ])
        let shot = callTool(server, "browser_snapshot")?["content"]?.arrayValue ?? []
        XCTAssertEqual(shot.map { $0["type"]?.stringValue ?? "" }, ["text", "image", "text", "image"])
    }

    /// DevTools tools (#167): console lines, the tree's text, click / fill / wait_for params, bad arguments refused.
    func testDevTools() {
        let server = server()
        replies["browser.console"] = ConsoleBuffer.sample.json(level: nil, since: nil, limit: nil)
        let console = text(callTool(server, "browser_console", #"{"pane":"p4","level":"error","clear":true}"#)) ?? ""
        XCTAssertTrue(console.contains("Unhandled rejection: Error: boom"), console)
        XCTAssertEqual(requests.last?.params["level"] ?? nil, .string("error"))
        XCTAssertEqual(requests.last?.params["clear"] ?? nil, .bool(true))

        replies["browser.snapshot_tree"] = .object(["title": "Form", "url": "http://x.test/", "text": "- button \"Go\" [ref=e1]\n",
                                                    "truncated": false, "count": 1])
        XCTAssertEqual(text(callTool(server, "browser_snapshot_tree", #"{"pane":"p4"}"#)),
                       "Form — http://x.test/\n- button \"Go\" [ref=e1]\n")

        replies["browser.fill"] = .object(["ref": "e2", "value": "x"])
        XCTAssertEqual(text(callTool(server, "browser_fill", #"{"pane":"p4","ref":"e2","value":"x"}"#)), "Filled e2.")
        XCTAssertEqual(requests.last?.params["ref"] ?? nil, .string("e2"))
        XCTAssertEqual(requests.last?.params["value"] ?? nil, .string("x"))
        replies["browser.click"] = .object(["ref": "e7"])
        XCTAssertEqual(text(callTool(server, "browser_click", #"{"pane":"p4","selector":"#go"}"#)), "Clicked e7.")
        XCTAssertEqual(requests.last?.params["selector"] ?? nil, .string("#go"))

        let count = requests.count
        XCTAssertEqual(callTool(server, "browser_click", #"{"pane":"p4"}"#)?["isError"], .bool(true))
        XCTAssertEqual(callTool(server, "browser_wait_for", #"{"pane":"p4","timeout":5}"#)?["isError"], .bool(true))
        XCTAssertEqual(callTool(server, "browser_console", #"{"level":"loud"}"#)?["isError"], .bool(true))
        XCTAssertEqual(requests.count, count)

        // The app's timeout error reaches the agent as a tool error.
        failure = CLIError.failure("timed out after 1 s waiting for text \"Saved\"")
        let timedOut = callTool(server, "browser_wait_for", #"{"pane":"p4","text":"Saved","timeout":1}"#)
        XCTAssertEqual(timedOut?["isError"], .bool(true))
        XCTAssertTrue(text(timedOut)?.contains("timed out") == true)
        failure = CLIError.failure("method not found: browser.console")
        XCTAssertTrue(text(callTool(server, "browser_console", #"{"pane":"p4"}"#))?.contains("update cmds") == true)
        failure = nil
    }

    func testBrowserToolsWithoutAnOpenedPaneTargetTheWorkspace() {
        _ = callTool(server(), "browser_url")
        XCTAssertNil(requests.last?.params["pane"] ?? nil)
        XCTAssertEqual(requests.last?.params["workspace"] ?? nil, .string("w1"))
    }

    func testAClosedLastPaneFallsBackToTheWorkspace() {
        let server = server()
        replies["browser.open"] = .object(["id": "p9"])
        _ = callTool(server, "browser_open", #"{"url":"https://example.com"}"#)
        closedPanes = ["p9"]  // the user closed it

        XCTAssertEqual(callTool(server, "browser_url")?["isError"], .bool(false))
        XCTAssertNil(requests.last?.params["pane"] ?? nil)
        XCTAssertEqual(requests.last?.params["workspace"] ?? nil, .string("w1"))
        XCTAssertEqual(server.openedPanes, [])

        // An explicit pane is not replaced: its error is the answer.
        XCTAssertEqual(callTool(server, "browser_url", #"{"pane":"p9"}"#)?["isError"], .bool(true))
    }

    func testSnapshotReturnsAnImage() throws {
        replies["browser.snapshot"] = .object(["png_base64": "iVBORw0K"])
        let content = try XCTUnwrap(callTool(server(), "browser_snapshot")?["content"]?.arrayValue?.first)
        XCTAssertEqual(content["type"]?.stringValue, "image")
        XCTAssertEqual(content["mimeType"]?.stringValue, "image/png")
        XCTAssertEqual(content["data"]?.stringValue, "iVBORw0K")
    }

    func testClosePaneClosesAPaneTheServerOpened() {
        let server = server()
        replies["browser.open"] = .object(["id": "p9"])
        _ = callTool(server, "browser_open", #"{"url":"https://example.com"}"#)
        XCTAssertEqual(callTool(server, "close_pane", #"{"pane":"p9"}"#)?["isError"], .bool(false))
        XCTAssertEqual(requests.last?.method, "pane.close")
        XCTAssertEqual(requests.last?.params["openedBy"] ?? nil, nil)
        XCTAssertEqual(server.openedPanes, [])
        XCTAssertEqual(callTool(server, "close_pane", #"{"pane":"p9"}"#)?["isError"], .bool(true))  // gone
    }

    /// #165: a pane opened from the same terminal with the CLI, or by an earlier server (MCP restart).
    func testClosePaneClosesAPaneOpenedFromTheSameTerminal() {
        openers["p9"] = "p1"
        let server = server()  // a new server that never opened p9
        XCTAssertEqual(text(callTool(server, "close_pane", #"{"pane":"p9"}"#)), "Closed p9.")
        XCTAssertEqual(requests.last?.method, "pane.close")
        XCTAssertEqual(requests.last?.params["openedBy"] ?? nil, .string("p1"))
        XCTAssertTrue(closedPanes.contains("p9"))
    }

    func testClosePaneRefusesPanesFromAnotherTerminalOrWithoutOpener() throws {
        openers["p8"] = "p2"
        let server = server()
        for pane in ["p8", "p7", "p1"] {  // another terminal's pane, one the user opened, our own terminal
            let refused = callTool(server, "close_pane", #"{"pane":"\#(pane)"}"#)
            XCTAssertEqual(refused?["isError"], .bool(true))
            let message = try XCTUnwrap(text(refused))
            XCTAssertTrue(message.contains("was not opened from your terminal (p1)"), message)
            XCTAssertTrue(message.contains("`cmds close-pane \(pane)`"), message)
            XCTAssertEqual(requests.last?.params["openedBy"] ?? nil, .string("p1"))
        }
        XCTAssertTrue(closedPanes.isEmpty)
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

    func testSetStatusAcceptsEmptyTextToClear() {
        XCTAssertEqual(text(callTool(server(), "set_status", #"{"text":""}"#)), "Cleared the status.")
        XCTAssertEqual(requests.last?.params["workspace"] ?? nil, .string("w1"))
        XCTAssertEqual(callTool(server(), "set_status")?["isError"], .bool(true))
    }

    func testAppErrorsBecomeToolErrors() {
        failure = CLIError.failure("no browser pane in workspace w1")
        let result = callTool(server(), "browser_eval", #"{"script":"1"}"#)
        XCTAssertEqual(result?["isError"], .bool(true))
        XCTAssertEqual(text(result), "no browser pane in workspace w1")
        XCTAssertEqual(callTool(server(), "browser_eval")?["isError"], .bool(true))  // missing script
    }
}
