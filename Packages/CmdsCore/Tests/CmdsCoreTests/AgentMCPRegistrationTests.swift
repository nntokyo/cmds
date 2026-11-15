@testable import CmdsCore
import XCTest

final class AgentMCPRegistrationTests: XCTestCase {
    private let app = "/Applications/cmds.app/Contents/Resources/bin/cmds"

    func testClaudeStates() {
        let none = AgentMCPRegistration.claudeState(nil)
        XCTAssertEqual(none, .missing)
        XCTAssertEqual(AgentMCPRegistration.claudeState(Data(#"{"mcpServers":{}}"#.utf8)), .missing)
        XCTAssertEqual(AgentMCPRegistration.claudeState(Data(#"{"other":1}"#.utf8)), .missing)
        XCTAssertEqual(AgentMCPRegistration.claudeState(Data("oops".utf8)), .unreadable)
        XCTAssertEqual(AgentMCPRegistration.claudeState(Data(#"{"mcpServers":{"cmds":{"command":"cmds","args":["mcp"]}}}"#.utf8)),
                       .registered(command: "cmds"))
        // Registered under another name by the user: counts.
        XCTAssertEqual(AgentMCPRegistration.claudeState(Data(#"{"mcpServers":{"term":{"command":"/usr/local/bin/cmds","args":["mcp"]}}}"#.utf8)),
                       .registered(command: "/usr/local/bin/cmds"))
        // cmds' own entry whose app moved.
        let gone = #"{"mcpServers":{"cmds":{"command":"\#(app)","args":["mcp"]}}}"#
        XCTAssertEqual(AgentMCPRegistration.claudeState(Data(gone.utf8), exists: { _ in false }), .stale(command: app))
        XCTAssertEqual(AgentMCPRegistration.claudeState(Data(gone.utf8), exists: { _ in true }), .registered(command: app))
    }

    func testClaudeFilesAndArguments() {
        XCTAssertEqual(AgentMCPRegistration.claudeConfigFile(configDir: nil, home: "/h"), "/h/.claude.json")
        XCTAssertEqual(AgentMCPRegistration.claudeConfigFile(configDir: "~/.claude-work", home: "/h"), "/h/.claude-work/.claude.json")
        XCTAssertEqual(AgentMCPRegistration.claudeAddArguments(cli: app), ["mcp", "add", "--scope", "user", "cmds", "--", app, "mcp"])
    }

    func testCodexStates() {
        XCTAssertEqual(AgentMCPRegistration.codexState(nil), .missing)
        let other = """
            model = "o3"

            [mcp_servers.node_repl]
            args = []
            command = "/x/node_repl"

            [mcp_servers.node_repl.env]
            command = "not a server"
            """
        XCTAssertEqual(AgentMCPRegistration.codexState(other), .missing)
        let added = AgentMCPRegistration.codexAppending(other, cli: app)
        XCTAssertTrue(added.hasPrefix(other + "\n\n# Added by cmds"))
        XCTAssertEqual(AgentMCPRegistration.codexState(added, exists: { _ in true }), .registered(command: app))
        XCTAssertEqual(AgentMCPRegistration.codexState(added, exists: { _ in false }), .stale(command: app))
        let moved = AgentMCPRegistration.codexReplacingCommand(added, stale: app, cli: "/Apps/cmds.app/Contents/Resources/bin/cmds")
        XCTAssertEqual(AgentMCPRegistration.codexState(moved, exists: { _ in true }),
                       .registered(command: "/Apps/cmds.app/Contents/Resources/bin/cmds"))
        XCTAssertTrue(moved.contains(#"env_vars = ["CMDS_PANE_ID", "CMDS_WORKSPACE_ID", "CMDS_SOCKET_PATH"]"#))
        // The user's own table under another name, and a quoted name.
        XCTAssertEqual(AgentMCPRegistration.codexState("[mcp_servers.term]\ncommand = 'cmds'\nargs = [\"mcp\"]\n"),
                       .registered(command: "cmds"))
        XCTAssertEqual(AgentMCPRegistration.codexState("[mcp_servers.\"cmds\"]\ncommand = \"cmds\" # mine\n"),
                       .registered(command: "cmds"))
        XCTAssertEqual(AgentMCPRegistration.codexAppending(nil, cli: "cmds"), AgentMCPRegistration.codexTable(cli: "cmds"))
    }
}
