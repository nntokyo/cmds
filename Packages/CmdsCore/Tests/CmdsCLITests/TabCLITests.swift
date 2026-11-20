import XCTest
import CmdsCore
@testable import cmds_cli

/// Tabs on the command line: `cmds tab`, `cmds pane move --tab`, and `cmds ls` listing every tab of a group.
final class TabCLITests: XCTestCase {
    private let environment = ["CMDS_SOCKET_PATH": "/nonexistent/cmds-cli-tests/cmds.sock"]

    private func exitCode(_ words: [String]) -> Int32 {
        CLI.main(words, environment: environment)
    }

    func testUsageErrors() {
        let usage = CLIError.Code.usage.rawValue
        XCTAssertEqual(exitCode(["tab", "extra"]), usage)
        XCTAssertEqual(exitCode(["tab", "--", "ls"]), usage, "a tab runs no command")
        XCTAssertEqual(exitCode(["pane", "move", "p1", "--tab"]), usage, "--tab needs --beside")
        XCTAssertEqual(exitCode(["pane", "move", "p1", "--beside", "p2", "--side", "left", "--tab"]), usage)
        XCTAssertEqual(exitCode(["pane", "move", "p1", "--new-workspace", "--tab"]), usage)
    }

    func testReachesTheApp() {
        let unavailable = CLIError.Code.unavailable.rawValue
        XCTAssertEqual(exitCode(["tab", "--pane", "p1", "--browser", "https://example.com", "--no-focus"]), unavailable)
        XCTAssertEqual(exitCode(["pane", "move", "p1", "--beside", "p2", "--tab"]), unavailable)
    }

    func testMoveParamsWithTab() throws {
        let request = try CLI.paneMoveParams(try Arguments(["p1", "--beside", "p2", "--tab"],
                                                           options: ["to", "beside", "side"],
                                                           flags: ["new-workspace", "no-focus", "tab"]))
        XCTAssertEqual(request.params["tab"] ?? nil, .bool(true))
        XCTAssertEqual(request.params["beside"] ?? nil, .string("p2"))
    }

    func testListShowsEveryTab() {
        let tabs = ["p2", "p3"]
        let workspace = WorkspaceInfo(id: "w1", title: "proj", selected: true, panes: [
            PaneInfo(id: "p1", kind: .terminal, title: "zsh", focused: false, attention: false),
            PaneInfo(id: "p2", kind: .browser, title: "Docs", focused: true, attention: false, url: "https://a.example/", tabs: tabs),
            PaneInfo(id: "p3", kind: .browser, title: "API", focused: false, attention: false, url: "https://b.example/",
                     tabs: tabs, background: true),
        ], layout: .split(axis: .horizontal, ratio: 0.5, first: .pane(id: "p1"), second: .pane(id: "p2")))
        let text = Format.workspaces([workspace], currentPane: nil)
        XCTAssertTrue(text.contains("tabs (2)"), text)
        XCTAssertTrue(text.contains("p3"), "the background tab is listed: \(text)")
        XCTAssertTrue(text.contains("(shown)"), text)
    }
}
