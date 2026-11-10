import XCTest
import CmdsCore
@testable import cmds_cli

/// `cmds pane move` / `cmds pane swap` (#218): bad command lines are usage errors before anything is sent; good ones
/// reach the (missing) app.
final class PaneMoveCLITests: XCTestCase {
    private let environment = ["CMDS_SOCKET_PATH": "/nonexistent/cmds-cli-tests/cmds.sock"]

    private func exitCode(_ words: [String]) -> Int32 {
        CLI.main(words, environment: environment)
    }

    func testMoveUsageErrors() {
        let usage = CLIError.Code.usage.rawValue
        XCTAssertEqual(exitCode(["pane", "move"]), usage)
        XCTAssertEqual(exitCode(["pane", "move", "p1"]), usage, "no destination")
        XCTAssertEqual(exitCode(["pane", "move", "p1", "p2", "--beside", "p3"]), usage, "two panes")
        XCTAssertEqual(exitCode(["pane", "move", "p1", "--beside", "p2", "--side", "middle"]), usage)
        XCTAssertEqual(exitCode(["pane", "move", "p1", "--beside", "p1"]), usage)
        XCTAssertEqual(exitCode(["pane", "move", "p1", "--new-workspace", "--to", "w2"]), usage)
        XCTAssertEqual(exitCode(["pane", "move", "p1", "--new-workspace", "--side", "left"]), usage)
        XCTAssertEqual(exitCode(["pane", "nudge", "p1"]), usage, "unknown subcommand")
    }

    func testMoveReachesTheApp() {
        let unavailable = CLIError.Code.unavailable.rawValue
        XCTAssertEqual(exitCode(["pane", "move", "p1", "--beside", "p2", "--side", "top"]), unavailable)
        XCTAssertEqual(exitCode(["pane", "move", "p1", "--new-workspace", "--no-focus"]), unavailable)
        XCTAssertEqual(exitCode(["pane", "move", "p1", "--to", "w2"]), unavailable)
    }

    func testMoveParams() throws {
        let beside = try CLI.paneMoveParams(try Arguments(["p1", "--beside", "p2", "--side", "bottom", "--no-focus"],
                                                          options: ["to", "beside", "side"],
                                                          flags: ["new-workspace", "no-focus"]))
        XCTAssertEqual(beside.params["pane"] ?? nil, .string("p1"))
        XCTAssertEqual(beside.params["beside"] ?? nil, .string("p2"))
        XCTAssertEqual(beside.params["side"] ?? nil, .string("bottom"))
        XCTAssertEqual(beside.params["focus"] ?? nil, .bool(false))
        XCTAssertNil(beside.params["newWorkspace"] ?? nil)
        XCTAssertNil(beside.to)

        let fresh = try CLI.paneMoveParams(try Arguments(["p1", "--new-workspace"], options: ["to", "beside", "side"],
                                                         flags: ["new-workspace", "no-focus"]))
        XCTAssertEqual(fresh.params["newWorkspace"] ?? nil, .bool(true))
        XCTAssertNil(fresh.params["focus"] ?? nil)

        let into = try CLI.paneMoveParams(try Arguments(["p1", "--to", "2"], options: ["to", "beside", "side"],
                                                        flags: ["new-workspace", "no-focus"]))
        XCTAssertEqual(into.to, "2", "resolved against the app's list (id, index or title) before sending")
        XCTAssertNil(into.params["workspace"] ?? nil)
    }

    func testSwapUsage() {
        XCTAssertEqual(exitCode(["pane", "swap", "p1"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["pane", "swap", "p1", "p1"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["pane", "swap", "p1", "p2", "p3"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["pane", "swap", "p1", "p2"]), CLIError.Code.unavailable.rawValue)
    }

    /// A pane moved to another workspace keeps CMDS_WORKSPACE_ID of the one it started in: the CLI looks its pane up.
    func testWorkspaceContainingThePane() {
        let pane = PaneInfo(id: "p3", kind: .terminal, title: "t", focused: false, attention: false)
        let list = [
            WorkspaceInfo(id: "w1", title: "a", selected: true, attention: false, panes: []),
            WorkspaceInfo(id: "w2", title: "b", selected: false, attention: false, panes: [pane]),
        ]
        XCTAssertEqual(workspaceID(containing: "p3", in: list), "w2")
        XCTAssertNil(workspaceID(containing: "p9", in: list))
    }

    /// CMDS_WORKSPACE_ID when outside a pane (no request), when the list cannot be read, or when no workspace has the pane.
    func testCurrentWorkspaceFallsBackToTheStartingOne() {
        struct Unreachable: Error {}
        let pane = PaneInfo(id: "p3", kind: .terminal, title: "t", focused: false, attention: false)
        let list = [WorkspaceInfo(id: "w2", title: "b", selected: false, attention: false, panes: [pane])]
        XCTAssertEqual(currentWorkspaceID(pane: "p3", started: "w1") { list }, "w2")
        XCTAssertEqual(currentWorkspaceID(pane: "p9", started: "w1") { list }, "w1")
        XCTAssertEqual(currentWorkspaceID(pane: "p3", started: "w1") { throw Unreachable() }, "w1")
        XCTAssertEqual(currentWorkspaceID(pane: nil, started: "w1") { XCTFail("asked without a pane"); return list }, "w1")
        XCTAssertNil(currentWorkspaceID(pane: nil, started: nil) { list })
    }
}
