import XCTest
@testable import CmdsCore

final class LoginItemTests: XCTestCase {
    func testApplicationsFolder() {
        let home = "/Users/me"
        XCTAssertTrue(LoginItemPolicy.isInApplicationsFolder("/Applications/cmds.app", home: home))
        XCTAssertTrue(LoginItemPolicy.isInApplicationsFolder("/Users/me/Applications/cmds.app", home: home))
        XCTAssertTrue(LoginItemPolicy.isInApplicationsFolder("/Applications/Dev/cmds.app/", home: home))
        XCTAssertFalse(LoginItemPolicy.isInApplicationsFolder("/Volumes/cmds 0.33.0/cmds.app", home: home))
        XCTAssertFalse(LoginItemPolicy.isInApplicationsFolder("/Users/me/Downloads/cmds.app", home: home))
        XCTAssertFalse(LoginItemPolicy.isInApplicationsFolder("/Users/me/src/cmds/build/dd/Build/Products/Debug/cmds.app", home: home))
        XCTAssertFalse(LoginItemPolicy.isInApplicationsFolder("/ApplicationsX/cmds.app", home: home))
        XCTAssertFalse(LoginItemPolicy.isInApplicationsFolder("/Applications/../tmp/cmds.app", home: home))
        XCTAssertFalse(LoginItemPolicy.isInApplicationsFolder("/Applications", home: home))
    }

    func testSummaryAndLenientDecoding() throws {
        XCTAssertEqual(LoginItemState(status: .on).summary, "on")
        XCTAssertEqual(LoginItemState(status: .needsApproval).summary, "needs approval: " + LoginItemPolicy.approvalHint)
        XCTAssertEqual(LoginItemState(status: .unavailable, problem: "x").summary, "unavailable: x")
        let state = try JSONDecoder().decode(LoginItemState.self, from: Data(#"{"status": "later"}"#.utf8))
        XCTAssertEqual(state.status, .unavailable)
    }
}
