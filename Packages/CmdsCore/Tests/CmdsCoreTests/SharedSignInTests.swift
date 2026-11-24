import Foundation
import XCTest
@testable import CmdsCore

/// Workspace profiles and the shared-sign-in warning.
final class SharedSignInTests: XCTestCase {
    func testWorkspaceProfileNames() {
        let notes = WorkspaceProfile.name(folder: "/Users/me/Source/project/NN/notes", title: "x", home: "/Users/me")
        XCTAssertTrue(notes.hasPrefix("notes · "), notes)
        XCTAssertEqual(notes, WorkspaceProfile.name(folder: "/Users/me/Source/project/NN/notes/", title: "y", home: "/Users/me"),
                       "the folder decides, not the title")
        XCTAssertNotEqual(WorkspaceProfile.name(folder: "/a/app", title: "", home: "/h"),
                          WorkspaceProfile.name(folder: "/b/app", title: "", home: "/h"), "two projects called app")
        XCTAssertTrue(WorkspaceProfile.name(folder: "/Users/me", title: "Research", home: "/Users/me").hasPrefix("Research · "))
        XCTAssertTrue(WorkspaceProfile.name(folder: nil, title: "", home: "/h").hasPrefix("workspace · "))
        let long = WorkspaceProfile.name(folder: "/p/" + String(repeating: "a", count: 200), title: "", home: "/h")
        XCTAssertLessThanOrEqual(long.count, BrowserProfile.maxLength)
        XCTAssertNoThrow(try BrowserProfile.validated(long))
    }

    func testSitesAndSignIns() throws {
        let x = try XCTUnwrap(SharedSignIn.site(forHost: "mobile.x.com"))
        XCTAssertEqual(x.name, "X")
        XCTAssertNil(SharedSignIn.site(forHost: "notx.com"))
        XCTAssertNil(SharedSignIn.site(forHost: "example.com"))
        XCTAssertTrue(SharedSignIn.isSignedIn(x, cookies: [("guest_id", ".x.com"), ("auth_token", ".x.com")]))
        XCTAssertFalse(SharedSignIn.isSignedIn(x, cookies: [("guest_id", ".x.com")]), "a visitor's cookies only")
        XCTAssertFalse(SharedSignIn.isSignedIn(x, cookies: [("auth_token", ".example.com")]), "another site's cookie")
        let amazon = try XCTUnwrap(SharedSignIn.site(forHost: "www.amazon.co.jp"))
        XCTAssertTrue(SharedSignIn.isSignedIn(amazon, cookies: [("at-acbjp", ".amazon.co.jp")]))
    }
}
