import Foundation
import XCTest
@testable import CmdsCore

/// The sidebar's pull request and checks from `gh pr view --json` (#174 G16).
final class PullRequestSummaryTests: XCTestCase {
    private func parse(_ json: String) -> PullRequestSummary? { PullRequestSummary.parse(Data(json.utf8)) }

    func testChecksOfBothKinds() {
        let summary = parse("""
            {"number": 405, "state": "OPEN", "isDraft": false, "url": "https://github.com/o/r/pull/405",
             "statusCheckRollup": [
               {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"},
               {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SKIPPED"},
               {"__typename": "CheckRun", "status": "IN_PROGRESS", "conclusion": ""},
               {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "CANCELLED"},
               {"__typename": "StatusContext", "state": "SUCCESS"},
               {"__typename": "StatusContext", "state": "PENDING"}
             ]}
            """)
        XCTAssertEqual(summary, PullRequestSummary(number: 405, state: .open, url: "https://github.com/o/r/pull/405",
                                                   passed: 3, failed: 1, pending: 2))
        XCTAssertEqual(summary?.checks, .failing)
        XCTAssertEqual(summary?.badge, "#405 ✗")
    }

    func testStatesAndBadges() {
        XCTAssertEqual(parse(#"{"number": 7, "state": "OPEN", "isDraft": true, "statusCheckRollup": []}"#)?.state, .draft)
        XCTAssertEqual(parse(#"{"number": 7, "state": "OPEN", "isDraft": true, "statusCheckRollup": []}"#)?.badge, "#7")
        XCTAssertEqual(parse(#"{"number": 8, "state": "MERGED", "statusCheckRollup": []}"#)?.badge, "#8 merged")
        XCTAssertEqual(parse(#"{"number": 9, "state": "CLOSED"}"#)?.badge, "#9 closed")
        XCTAssertEqual(PullRequestSummary(number: 1, state: .open, pending: 1).badge, "#1 ●")
        XCTAssertEqual(PullRequestSummary(number: 1, state: .open, passed: 2).badge, "#1 ✓")
        XCTAssertNil(parse("no pull requests found for branch \"x\""))
        XCTAssertNil(parse(#"{"state": "OPEN"}"#))
    }

    func testWhichRepositoriesAndBranches() {
        XCTAssertTrue(PullRequestSummary.hasGitHubRemote(config: "[remote \"origin\"]\n\turl = git@github.com:o/r.git\n"))
        XCTAssertTrue(PullRequestSummary.hasGitHubRemote(config: "[remote \"origin\"]\n\turl = https://github.com/o/r\n"))
        XCTAssertFalse(PullRequestSummary.hasGitHubRemote(config: "[remote \"origin\"]\n\turl = https://gitlab.com/o/r\n"))
        XCTAssertFalse(PullRequestSummary.hasGitHubRemote(config: "[core]\n\tbare = false\n"))
        XCTAssertFalse(PullRequestSummary.asksAbout(branch: "main"))
        XCTAssertTrue(PullRequestSummary.asksAbout(branch: "feature/x"))
    }

    func testAgainstRealGhOutput() throws {
        // The shape `gh pr view --json number,state,isDraft,url,statusCheckRollup` printed for PR #405 of this repository.
        let real = #"{"isDraft":false,"number":405,"state":"MERGED","statusCheckRollup":[{"__typename":"CheckRun","completedAt":"2026-11-23T19:45:10Z","conclusion":"SUCCESS","detailsUrl":"https://github.com/x","name":"Website and update feed","startedAt":"2026-11-23T19:45:05Z","status":"COMPLETED","workflowName":"CI"},{"__typename":"CheckRun","completedAt":"0001-01-01T00:00:00Z","conclusion":"","detailsUrl":"https://github.com/x","name":"Swift packages and String Catalogs","startedAt":"2026-11-23T19:45:04Z","status":"IN_PROGRESS","workflowName":"CI"}],"url":"https://github.com/nntokyo/cmds/pull/405"}"#
        let summary = try XCTUnwrap(parse(real))
        XCTAssertEqual(summary.number, 405)
        XCTAssertEqual(summary.state, .merged)
        XCTAssertEqual(summary.passed, 1)
        XCTAssertEqual(summary.pending, 1)
    }
}
