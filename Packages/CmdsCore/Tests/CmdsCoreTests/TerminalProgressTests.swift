import Foundation
import XCTest
@testable import CmdsCore

/// OSC 9;4 progress reports of terminal panes (#174 G21).
final class TerminalProgressTests: XCTestCase {
    func testFromGhostty() {
        XCTAssertNil(TerminalProgress.fromGhostty(state: 0, progress: 50), "remove")
        XCTAssertEqual(TerminalProgress.fromGhostty(state: 1, progress: 42), TerminalProgress(state: .normal, percent: 42))
        XCTAssertEqual(TerminalProgress.fromGhostty(state: 1, progress: -1), TerminalProgress(state: .normal, percent: 0))
        XCTAssertEqual(TerminalProgress.fromGhostty(state: 2, progress: -1), TerminalProgress(state: .error))
        XCTAssertEqual(TerminalProgress.fromGhostty(state: 3, progress: 70), TerminalProgress(state: .indeterminate))
        XCTAssertEqual(TerminalProgress.fromGhostty(state: 4, progress: 30), TerminalProgress(state: .paused, percent: 30))
        XCTAssertNil(TerminalProgress.fromGhostty(state: 9, progress: 1), "unknown states remove it")
        XCTAssertEqual(TerminalProgress(state: .normal, percent: 140).percent, 100)
    }

    func testPickPrefersAFailureThenTheNewest() {
        let old = Date(timeIntervalSince1970: 0), new = Date(timeIntervalSince1970: 10)
        let building = TerminalProgress(state: .normal, percent: 40)
        let waiting = TerminalProgress(state: .indeterminate)
        let failed = TerminalProgress(state: .error, percent: 80)
        XCTAssertEqual(TerminalProgress.pick([(building, old), (waiting, new)]), waiting)
        XCTAssertEqual(TerminalProgress.pick([(failed, old), (waiting, new)]), failed)
        XCTAssertNil(TerminalProgress.pick([]))
    }
}
