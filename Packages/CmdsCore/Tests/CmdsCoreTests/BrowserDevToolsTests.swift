import Foundation
import XCTest
@testable import CmdsCore

/// Console buffer, targets, page tree text and request parsing of the browser DevTools (#167).
final class BrowserDevToolsTests: XCTestCase {
    func testConsoleBufferCapAndFilters() {
        var buffer = ConsoleBuffer(capacity: 3)
        let levels: [ConsoleEntry.Level] = [.debug, .log, .warn, .error, .info]
        for (index, level) in levels.enumerated() {
            buffer.append(ConsoleEntry(level: level, text: "m\(index)", time: Double(index)))
        }
        XCTAssertEqual(buffer.entries.map(\.text), ["m2", "m3", "m4"], "the cap keeps the newest")
        XCTAssertEqual(buffer.entries.map(\.seq), [3, 4, 5])
        XCTAssertEqual(buffer.dropped, 2)
        XCTAssertEqual(buffer.entries(level: .warn).map(\.text), ["m2", "m3"])
        XCTAssertEqual(buffer.entries(level: .log).map(\.text), ["m2", "m3", "m4"], "info counts as log")
        XCTAssertEqual(buffer.entries(since: 4).map(\.text), ["m4"])
        XCTAssertEqual(buffer.entries(limit: 1).map(\.text), ["m4"])
        let json = buffer.json(level: nil, since: nil, limit: nil)
        XCTAssertEqual(json["dropped"], .number(2))
        XCTAssertEqual(json["last"], .number(5))
        XCTAssertEqual(json["entries"]?.arrayValue?.count, 3)
        buffer.clear()
        XCTAssertTrue(buffer.entries.isEmpty)
        buffer.append(ConsoleEntry(level: .log, text: "after", time: 0))
        XCTAssertEqual(buffer.entries.first?.seq, 6, "seq keeps counting after a clear (for --follow)")
        XCTAssertEqual(ConsoleBuffer().capacity, 1_000)
    }

    func testConsoleEntryFromMessage() {
        let entry = ConsoleEntry(message: ["level": "error", "source": "rejection", "text": "Error: boom",
                                           "time": NSNumber(value: 1_800_000_000_000), "url": "http://x.test/"])
        XCTAssertEqual(entry?.level, .error)
        XCTAssertEqual(entry?.source, .rejection)
        XCTAssertEqual(entry?.time, 1_800_000_000)
        XCTAssertNil(ConsoleEntry(message: ["level": "shout", "text": "x"]))
        XCTAssertNil(ConsoleEntry(message: ["level": "log"]))
        let long = ConsoleEntry(message: ["level": "log", "text": String(repeating: "a", count: 10_000)])
        XCTAssertEqual(long?.text.count, ConsoleBuffer.maxTextLength)
        let line = ConsoleEntry(level: .error, source: .rejection, text: "Error: boom", time: 0, location: "a.js:1:2")
            .line(timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(line, "00:00:00 error  Unhandled rejection: Error: boom (a.js:1:2)")
    }

    func testConsoleScripts() {
        let hook = ConsoleCapture.hook(eventName: "cmds-console-1")
        XCTAssertTrue(hook.contains(#""cmds-console-1""#))
        XCTAssertTrue(hook.contains("unhandledrejection"))
        let listener = ConsoleCapture.listener(eventName: "cmds-console-1")
        XCTAssertTrue(listener.contains("messageHandlers.cmdsConsole"))
        XCTAssertEqual(ConsoleCapture.jsonString("a\"b"), #""a\"b""#)
    }

    func testConsoleRequest() throws {
        XCTAssertEqual(try BrowserConsoleRequest(params: nil), BrowserConsoleRequest())
        let request = try BrowserConsoleRequest(params: ["level": "Warning", "since": 4, "limit": 10, "clear": true, "pane": "p1"])
        XCTAssertEqual(request, BrowserConsoleRequest(level: .warn, since: 4, limit: 10, clear: true))
        XCTAssertEqual(try BrowserConsoleRequest(params: .object(request.params.compactMapValues { $0 })), request)
        for bad: JSONValue in [["level": "loud"], ["since": -1], ["limit": 1.5], ["clear": "yes"]] {
            XCTAssertThrowsError(try BrowserConsoleRequest(params: bad), "\(bad)")
        }
    }

    /// The API, CLI and MCP show these messages as they are.
    func testConsoleRequestMessages() {
        let cases: [(JSONValue, String)] = [
            (["level": "loud"], "level must be debug, log, info, warn or error"),
            (["level": 3], "level must be a string"),
            (["since": -1], "since must be a non-negative whole number"),
            (["limit": 1.5], "limit must be a non-negative whole number"),
            (["clear": "yes"], "clear must be a boolean"),
        ]
        for (params, message) in cases {
            XCTAssertThrowsError(try BrowserConsoleRequest(params: params), "\(params)") {
                XCTAssertEqual(($0 as? RPCError)?.message, message)
            }
        }
        let entry = ConsoleEntry(message: ["level": "log", "text": "x", "url": String(repeating: "u", count: 3_000),
                                           "location": String(repeating: "l", count: 3_000)])
        XCTAssertEqual(entry?.url?.count, 2_048)
        XCTAssertEqual(entry?.location?.count, 2_048)
    }

    func testTargets() throws {
        XCTAssertEqual(try ElementTarget.parse("e12"), .ref("e12"))
        XCTAssertEqual(try ElementTarget.parse(" #submit "), .selector("#submit"))
        XCTAssertEqual(try ElementTarget.parse("e12 > a"), .selector("e12 > a"))
        XCTAssertThrowsError(try ElementTarget.parse("  "))
        XCTAssertEqual(try ElementTarget(params: ["ref": "e3"]), .ref("e3"))
        XCTAssertEqual(try ElementTarget(params: ["selector": "form button"]), .selector("form button"))
        XCTAssertThrowsError(try ElementTarget(params: ["ref": "button"]))
        XCTAssertThrowsError(try ElementTarget(params: ["ref": "e1", "selector": "a"]))
        XCTAssertThrowsError(try ElementTarget(params: [:]))
    }

    func testPageActions() throws {
        XCTAssertEqual(try BrowserPageAction(method: "browser.snapshot_tree", params: nil), .tree(selector: nil, maxNodes: 2_000))
        XCTAssertEqual(try BrowserPageAction(method: "browser.snapshot_tree", params: ["selector": "main", "maxNodes": 50_000]),
                       .tree(selector: "main", maxNodes: 2_000))
        XCTAssertEqual(try BrowserPageAction(method: "browser.fill", params: ["ref": "e4", "value": ""]),
                       .fill(.ref("e4"), value: ""))
        XCTAssertEqual(try BrowserPageAction(method: "browser.wait_for", params: ["text": "Saved"]),
                       .waitFor(selector: nil, text: "Saved", timeout: 5))
        let actions: [BrowserPageAction] = [.tree(selector: "form", maxNodes: 10), .click(.selector("a")),
                                            .fill(.ref("e1"), value: "x"), .waitFor(selector: "#ok", text: nil, timeout: 2.5)]
        for action in actions {
            XCTAssertEqual(try BrowserPageAction(method: action.method, params: .object(action.params.compactMapValues { $0 })), action)
        }
        let bad: [(String, JSONValue)] = [
            ("browser.fill", ["ref": "e1"]), ("browser.wait_for", [:]), ("browser.wait_for", ["selector": "a", "text": "b"]),
            ("browser.wait_for", ["text": "a", "timeout": 61]), ("browser.wait_for", ["text": "a", "timeout": 0]),
            ("browser.click", [:]), ("browser.snapshot_tree", ["maxNodes": 0]), ("browser.nope", [:]),
        ]
        for (method, params) in bad {
            XCTAssertThrowsError(try BrowserPageAction(method: method, params: params), "\(method) \(params)")
        }
    }

    func testTreeText() throws {
        let nodes = [
            PageNode(ref: "e1", role: "heading", name: "Sign in", level: 1),
            PageNode(ref: "e2", role: "form", children: [
                PageNode(ref: "e3", role: "textbox", name: "Email", value: "a@b.c"),
                PageNode(ref: "e4", role: "checkbox", name: "Remember \"me\"", checked: false),
                PageNode(ref: "e5", role: "button", name: "Go", disabled: true),
            ]),
            PageNode(ref: "e6", role: "link", name: "Help", url: "https://x.test/help"),
        ]
        XCTAssertEqual(PageNode.text(nodes), """
            - heading "Sign in" level=1 [ref=e1]
            - form [ref=e2]
              - textbox "Email" value="a@b.c" [ref=e3]
              - checkbox "Remember \\"me\\"" unchecked [ref=e4]
              - button "Go" disabled [ref=e5]
            - link "Help" url=https://x.test/help [ref=e6]

            """)
        XCTAssertEqual(PageNode.count(nodes), 6)
        // The page script's JSON (no children key on leaves) decodes.
        let decoded = try JSONDecoder().decode([PageNode].self, from: Data(#"[{"ref":"e1","role":"button","name":"Go"}]"#.utf8))
        XCTAssertEqual(decoded, [PageNode(ref: "e1", role: "button", name: "Go")])
        XCTAssertTrue(PageScripts.tree.contains("__cmdsRefs"))
        XCTAssertTrue(PageScripts.fill.contains("'change'"))
    }
}
