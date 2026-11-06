import XCTest
@testable import CmdsCore

/// The menu bar item's title and lists (#95).
final class MenuBarSummaryTests: XCTestCase {
    private func entry(_ id: String, _ title: String, needsUser: Bool = false, working: Bool = false) -> MenuBarSummary.Entry {
        MenuBarSummary.Entry(id: id, title: title, needsUser: needsUser, working: working)
    }

    func testNothingWaitingOrWorkingShowsOnlyTheIcon() {
        XCTAssertEqual(MenuBarSummary([]).title, "")
        XCTAssertEqual(MenuBarSummary([entry("w1", "idle")]).title, "")
    }

    func testWorkingCountWhenNothingNeedsTheUser() {
        let summary = MenuBarSummary([entry("w1", "a", working: true), entry("w2", "b"), entry("w3", "c", working: true)])
        XCTAssertEqual(summary.title, "◐2")
        XCTAssertEqual(summary.working.map(\.id), ["w1", "w3"])
        XCTAssertEqual(summary.needingUser, [])
    }

    func testTheFirstWorkspaceNeedingTheUserIsNamedWithTheRestCounted() {
        let summary = MenuBarSummary([
            entry("w1", "my-app", working: true),
            entry("w2", "api-server", needsUser: true),
            entry("w3", "docs-site", needsUser: true),
        ])
        XCTAssertEqual(summary.title, "● api-server +1")
        XCTAssertEqual(summary.needingUser.map(\.id), ["w2", "w3"])
        XCTAssertEqual(MenuBarSummary([entry("w2", "api-server", needsUser: true)]).title, "● api-server")
    }

    func testAWorkspaceIsListedOnceUnderNeedsUser() {
        let summary = MenuBarSummary([entry("w1", "a", needsUser: true, working: true)])
        XCTAssertEqual(summary.needingUser.map(\.id), ["w1"])
        XCTAssertEqual(summary.working, [])
    }

    func testLongTitlesAreShortened() {
        let title = String(repeating: "x", count: 30)
        let shown = MenuBarSummary([entry("w1", title, needsUser: true)]).title
        XCTAssertEqual(shown, "● " + String(repeating: "x", count: MenuBarSummary.maxTitleLength - 1) + "…")
        XCTAssertEqual(MenuBarSummary.shortened(String(repeating: "y", count: MenuBarSummary.maxTitleLength)),
                       String(repeating: "y", count: MenuBarSummary.maxTitleLength))
    }
}
