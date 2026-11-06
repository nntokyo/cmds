import XCTest
@testable import CmdsCore

/// The menu bar item's workspace list and badge counts (#95).
final class MenuBarSummaryTests: XCTestCase {
    private func entry(_ id: String, needsUser: Bool = false, _ activity: MenuBarSummary.State? = nil) -> MenuBarSummary.Entry {
        MenuBarSummary.Entry(id: id, needsUser: needsUser, activity: activity)
    }

    func testWorkspacesWithoutAnAgentAreLeftOut() {
        let summary = MenuBarSummary([entry("w1"), entry("w2", .idle)])
        XCTAssertEqual(summary.entries.map(\.id), ["w2"])
        XCTAssertEqual(summary.needingUserCount, 0)
        XCTAssertEqual(summary.workingCount, 0)
    }

    func testMenuOrderIsByStateThenSidebarOrder() {
        let summary = MenuBarSummary([
            entry("w1", .working), entry("w2", needsUser: true, .idle), entry("w3", .stopped), entry("w4", .working),
            entry("w5", .done), entry("w6", needsUser: true), entry("w7", .idle),
        ])
        XCTAssertEqual(summary.entries.map(\.id), ["w2", "w6", "w1", "w4", "w5", "w7", "w3"])
        XCTAssertEqual(summary.needingUserCount, 2)
        XCTAssertEqual(summary.workingCount, 2)
    }

    func testNeedingTheUserWinsOverWorking() {
        let summary = MenuBarSummary([entry("w1", needsUser: true, .working)])
        XCTAssertEqual(summary.entries.map(\.state), [.needsUser])
        XCTAssertEqual(summary.workingCount, 0)
    }
}
