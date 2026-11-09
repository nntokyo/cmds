import XCTest
import CmdsCore
@testable import cmds_cli

/// `cmds new --worktree`, `cmds changes`, `cmds close --remove-worktree` (#172): argument checks and the params sent.
final class WorktreeCLITests: XCTestCase {
    private let environment = ["CMDS_SOCKET_PATH": "/nonexistent/cmds-cli-tests/cmds.sock"]

    private func exitCode(_ words: [String]) -> Int32 {
        CLI.main(words, environment: environment)
    }

    private func params(_ words: [String]) throws -> [String: JSONValue] {
        let args = try Arguments(words, options: ["title", "cwd", "account", "worktree", "base", "path"])
        return try CLI.newWorkspaceParams(args, currentDirectory: "/src/app").compactMapValues { $0 }
    }

    func testWorktreeParams() throws {
        XCTAssertEqual(try params(["--worktree", "fix/login"]),
                       ["cwd": "/src/app", "worktree": "fix/login"])
        XCTAssertEqual(try params(["--worktree", "x", "--base", "develop", "--path", "../wt/x", "--cwd", "sub",
                                   "--title", "T", "--", "claude", "--resume"]),
                       ["cwd": "/src/app/sub", "worktree": "x", "base": "develop", "worktreePath": "/src/wt/x",
                        "title": "T", "command": "claude --resume"])
        XCTAssertEqual(try params(["--worktree", "x", "--path", "~/wt"])["worktreePath"],
                       .string(NSHomeDirectory() + "/wt"))
        XCTAssertEqual(try params(["--cwd", "/tmp"]), ["cwd": "/tmp"])
    }

    func testWorktreeOptionsNeedAWorktree() {
        XCTAssertThrowsError(try params(["--base", "develop"]))
        XCTAssertThrowsError(try params(["--path", "/x"]))
        XCTAssertThrowsError(try params(["--worktree", " "]))
    }

    func testExitCodes() {
        XCTAssertEqual(exitCode(["new", "--base", "develop"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["new", "--ssh", "host", "--worktree", "x"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["new", "--worktree"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["new", "--worktree", "x"]), CLIError.Code.unavailable.rawValue)
        XCTAssertEqual(exitCode(["changes", "a", "b"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["changes"]), CLIError.Code.unavailable.rawValue)
        XCTAssertEqual(exitCode(["close", "--remove-worktree=yes"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["close", "--remove-worktree"]), CLIError.Code.unavailable.rawValue)
    }
}

/// Bare arguments are never silently dropped (#185): `cmds new --worktree B /repo` used to ignore `/repo` and create the
/// branch and worktree in the current directory's repository.
final class PositionalArgumentCLITests: XCTestCase {
    private let environment = ["CMDS_SOCKET_PATH": "/nonexistent/cmds-cli-tests/cmds.sock"]

    private func exitCode(_ words: [String]) -> Int32 {
        CLI.main(words, environment: environment)
    }

    private func params(_ words: [String]) throws -> [String: JSONValue] {
        let args = try Arguments(words, options: ["title", "cwd", "account", "worktree", "base", "path"])
        return try CLI.newWorkspaceParams(args, currentDirectory: "/src/app",
                                          isDirectory: { ["/repo", "/src/app/sub", "/src"].contains($0) })
            .compactMapValues { $0 }
    }

    func testNewTakesABareDirectoryAsCwd() throws {
        XCTAssertEqual(try params(["--worktree", "B", "/repo"]), ["cwd": "/repo", "worktree": "B"])
        XCTAssertEqual(try params(["sub", "--", "claude"]), ["cwd": "/src/app/sub", "command": "claude"])
        XCTAssertEqual(try params([".."]), ["cwd": "/src"])
    }

    func testNewRefusesAmbiguousBareArguments() {
        // Not a directory (e.g. a command without --), two of them, or together with --cwd.
        XCTAssertThrowsError(try params(["--worktree", "B", "/missing"]))
        XCTAssertThrowsError(try params(["claude"]))
        XCTAssertThrowsError(try params(["/repo", "/src"]))
        XCTAssertThrowsError(try params(["--cwd", "/repo", "/src"]))
        XCTAssertThrowsError(try params(["--cwd", "/repo", "/repo"]))
    }

    func testNewExitCodes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-cli-185-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(exitCode(["new", "--worktree", "B", directory.path + "/missing"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["new", "--cwd", directory.path, directory.path]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["new", "--ssh", "host", directory.path]), CLIError.Code.usage.rawValue)
        // Passes the checks, then fails to reach the (nonexistent) app socket.
        XCTAssertEqual(exitCode(["new", directory.path]), CLIError.Code.unavailable.rawValue)
    }

    /// Commands without positional arguments refuse them with their usage instead of ignoring them.
    func testCommandsWithoutPositionalsRefuseThem() {
        for words in [["ping", "x"], ["quit", "x"], ["identify", "x"], ["ls", "x"], ["panes", "w2"],
                      ["remote-helper", "x"], ["events", "x"], ["mcp", "x"]] {
            XCTAssertEqual(exitCode(words), CLIError.Code.usage.rawValue, words.joined(separator: " "))
        }
        XCTAssertEqual(exitCode(["ls"]), CLIError.Code.unavailable.rawValue)
        XCTAssertEqual(exitCode(["panes", "--workspace", "w2"]), CLIError.Code.unavailable.rawValue)
    }

    /// Every command either checks its positional arguments or uses them all: run each with one extra bare word
    /// more than it takes and expect a usage error before the app is contacted. Hooks are exempt (they must always
    /// exit 0 for the agent), as are commands whose bare words are free text or a list.
    func testNoCommandIgnoresAnExtraBareArgument() {
        let exempt: Set<String> = ["hook claude-status", "hook agy-status", "hook claude", "hook codex",
                                   "send", "notify", "status", "tile"]
        for command in CLI.commands where !exempt.contains(command.name) {
            let words = command.name.split(separator: " ").map(String.init) + Array(repeating: "x", count: 4)
            XCTAssertEqual(exitCode(words), CLIError.Code.usage.rawValue, "cmds \(command.name) x x x x")
        }
    }
}
