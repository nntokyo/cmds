#if os(macOS)
import Foundation
import XCTest
@testable import CmdsCore

/// Short commands run by `/bin/sh` (no files touched).
final class CommandOutputTests: XCTestCase {
    private func sh(_ script: String, timeout: TimeInterval = 5, drainTimeout: TimeInterval = 2) -> Data? {
        CommandOutput.run("/bin/sh", ["-c", script], timeout: timeout, drainTimeout: drainTimeout)
    }

    func testStdoutOfASuccessfulRun() {
        XCTAssertEqual(sh("printf 'a\\0b'"), Data("a\0b".utf8))
        XCTAssertEqual(sh("true"), Data())
    }

    func testOutputLargerThanThePipeBuffer() {
        // 1 MB: blocks unless read while it runs.
        XCTAssertEqual(sh("head -c 1048576 /dev/zero")?.count, 1_048_576)
    }

    func testFailureAndMissingExecutable() {
        XCTAssertNil(sh("echo partial; exit 3"))
        XCTAssertNil(CommandOutput.run("/nonexistent/tool", [], timeout: 1))
    }

    func testTooSlowIsTerminated() {
        let start = Date()
        XCTAssertNil(sh("sleep 30", timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testAChildKeepingStdoutOpenDoesNotHang() {
        // The background sleep inherits stdout and keeps the pipe open after sh exits.
        let start = Date()
        let output = sh("echo done; sleep 4 &", drainTimeout: 0.5)
        XCTAssertEqual(output, Data("done\n".utf8))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "not held until the child exits")
    }

    func testEnvironment() {
        let output = CommandOutput.run("/bin/sh", ["-c", "printf %s \"$CMDS_TEST_VALUE\""],
                                       environment: ["CMDS_TEST_VALUE": "x y"], timeout: 5)
        XCTAssertEqual(output, Data("x y".utf8))
    }
}
#endif
