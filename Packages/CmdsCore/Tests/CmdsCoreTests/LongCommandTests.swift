import Foundation
import XCTest
@testable import CmdsCore

/// Notifications for long commands that finish in a pane you are not looking at.
final class LongCommandTests: XCTestCase {
    func testNotifies() {
        XCTAssertTrue(LongCommand.notifies(duration: 31, threshold: 30, visible: false, agentRunning: false))
        XCTAssertTrue(LongCommand.notifies(duration: 30, threshold: 30, visible: false, agentRunning: false))
        XCTAssertFalse(LongCommand.notifies(duration: 29.9, threshold: 30, visible: false, agentRunning: false), "short")
        XCTAssertFalse(LongCommand.notifies(duration: 600, threshold: 30, visible: true, agentRunning: false), "you see it")
        XCTAssertFalse(LongCommand.notifies(duration: 600, threshold: 30, visible: false, agentRunning: true), "an agent's pane")
        XCTAssertFalse(LongCommand.notifies(duration: 600, threshold: 0, visible: false, agentRunning: false), "off")
    }

    func testFinish() {
        let failed = LongCommand.finish(exitCode: 2, nanoseconds: 1_500_000_000)
        XCTAssertEqual(failed.exitCode, 2)
        XCTAssertEqual(failed.duration, 1.5)
        XCTAssertNil(LongCommand.finish(exitCode: -1, nanoseconds: 0).exitCode)
        XCTAssertEqual(LongCommand.choices.first, 0)
        XCTAssertTrue(LongCommand.choices.contains(LongCommand.defaultSeconds))
    }
}
