import Foundation
import XCTest
@testable import CmdsCore

/// Notification levels (#174 G21).
final class NotificationLevelTests: XCTestCase {
    func testParse() throws {
        XCTAssertEqual(try NotificationLevel.parse(nil), .info)
        XCTAssertEqual(try NotificationLevel.parse(""), .info)
        XCTAssertEqual(try NotificationLevel.parse("Error"), .error)
        XCTAssertThrowsError(try NotificationLevel.parse("fatal"))
    }

    func testDecorate() {
        XCTAssertEqual(NotificationLevel.info.decorate("Bell"), "Bell")
        XCTAssertEqual(NotificationLevel.success.decorate("Tests passed"), "✓ Tests passed")
        XCTAssertEqual(NotificationLevel.warning.decorate("Limit"), "⚠︎ Limit")
        XCTAssertEqual(NotificationLevel.error.decorate("Command failed (exit 1)"), "✗ Command failed (exit 1)")
    }

    func testWorkspaceInfoLeavesInfoOut() throws {
        let plain = WorkspaceInfo(id: "w1", title: "t", selected: true, notificationText: "x")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("notificationLevel"))
        let error = WorkspaceInfo(id: "w1", title: "t", selected: true, notificationText: "x", notificationLevel: .error)
        let decoded = try JSONDecoder().decode(WorkspaceInfo.self, from: try JSONEncoder().encode(error))
        XCTAssertEqual(decoded.notificationLevel, .error)
    }
}
