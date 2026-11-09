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
