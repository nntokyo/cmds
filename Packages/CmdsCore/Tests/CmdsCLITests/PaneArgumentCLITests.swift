import XCTest
import CmdsCore
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

    /// `cmds browser device` (#168): bad sizes and schemes are usage errors before anything is sent.
    func testBrowserDevice() throws {
        XCTAssertEqual(exitCode(["browser", "device", "nokia"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["browser", "device", "20x20"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["browser", "device", "--scheme", "sepia"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["browser", "device", "iphone", "ipad"]), CLIError.Code.usage.rawValue)
        XCTAssertEqual(exitCode(["browser", "device", "--pane", "p2", "iphone-se"]), CLIError.Code.unavailable.rawValue)
        XCTAssertEqual(exitCode(["browser", "device", "--list"]), 0)

        let args = try Arguments(["--rotate", "--ua", "", "--scheme", "dark", "390x844"], options: ["pane", "ua", "scheme"],
                                 flags: ["rotate", "list"])
        let change = try CLI.browserViewportChange(args)
        XCTAssertEqual(change.params["width"] ?? nil, .number(390))
        XCTAssertEqual(change.params["height"] ?? nil, .number(844))
        XCTAssertEqual(change.params["rotate"] ?? nil, .bool(true))
        XCTAssertEqual(change.params["userAgent"] ?? nil, .string(""))
        XCTAssertEqual(change.params["colorScheme"] ?? nil, .string("dark"))
        XCTAssertEqual(try CLI.browserViewportChange(try Arguments(["off"])).params["device"] ?? nil, .string("off"))
        XCTAssertTrue(CLI.presetTable().contains("iphone-se"))
    }
}
