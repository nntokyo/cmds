import XCTest
@testable import cmds_cli

/// Commands that read a pane take it only as `--pane P`. A bare pane id used to be ignored, so `cmds read p2` printed
/// the focused pane's screen instead of p2's (#61); it is now a usage error, given before anything is sent to the app.
final class PaneArgumentCLITests: XCTestCase {
    /// A socket that does not exist: a command line that passes the checks fails with `unavailable` when it connects.
    private let environment = ["CMDS_SOCKET_PATH": "/nonexistent/cmds-cli-tests/cmds.sock"]

    private func exitCode(_ words: [String]) -> Int32 {
        CLI.main(words, environment: environment)
    }

    func testReadRejectsABarePaneID() {
        XCTAssertEqual(exitCode(["read", "p2"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["read", "--pane", "p1", "p2"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["read", "--scrollback", "50", "p2"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["read", "--pane", "p2"]), CLIError.Code.unavailable.rawValue)
        XCTAssertEqual(exitCode(["read"]), CLIError.Code.unavailable.rawValue)
    }

    func testBrowserReadsRejectABarePaneID() {
        XCTAssertEqual(exitCode(["browser", "url", "p2"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["browser", "snapshot", "p2"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["browser", "url", "--pane", "p2"]), CLIError.Code.unavailable.rawValue)
    }
}
