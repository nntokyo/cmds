import XCTest
@testable import CmdsCore

/// The menu bar item's lists (#95).
final class MenuBarSummaryTests: XCTestCase {
    private func entry(_ id: String, needsUser: Bool = false, working: Bool = false) -> MenuBarSummary.Entry {
        MenuBarSummary.Entry(id: id, title: id, needsUser: needsUser, working: working)
    }

    func testNothingWaitingOrWorkingIsQuiet() {
        XCTAssertTrue(MenuBarSummary([]).isQuiet)
        XCTAssertTrue(MenuBarSummary([entry("w1")]).isQuiet)
    }

    func testWorkspacesAreSplitInSidebarOrder() {
        let summary = MenuBarSummary([
            entry("w1", working: true), entry("w2", needsUser: true), entry("w3"), entry("w4", working: true),
            entry("w5", needsUser: true),
        ])
        XCTAssertFalse(summary.isQuiet)
        XCTAssertEqual(summary.needingUser.map(\.id), ["w2", "w5"])
        XCTAssertEqual(summary.working.map(\.id), ["w1", "w4"])
    }

    func testAWorkspaceIsListedOnceUnderNeedsUser() {
        let summary = MenuBarSummary([entry("w1", needsUser: true, working: true)])
        XCTAssertEqual(summary.needingUser.map(\.id), ["w1"])
        XCTAssertEqual(summary.working, [])
    }
}
