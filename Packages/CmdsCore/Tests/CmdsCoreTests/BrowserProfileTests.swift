import XCTest
@testable import CmdsCore

final class BrowserProfileTests: XCTestCase {
    func testNamesAreTrimmedAndEmptyMeansShared() throws {
        XCTAssertEqual(try BrowserProfile.validated("  work "), "work")
        XCTAssertEqual(try BrowserProfile.validated("エージェントA"), "エージェントA")
        XCTAssertNil(try BrowserProfile.validated(""))
        XCTAssertNil(try BrowserProfile.validated(" \n"))
        XCTAssertNil(try BrowserProfile.validated(nil))
    }

    func testLongNamesAndControlCharactersAreRefused() {
        XCTAssertNoThrow(try BrowserProfile.validated(String(repeating: "x", count: BrowserProfile.maxLength)))
        XCTAssertThrowsError(try BrowserProfile.validated(String(repeating: "x", count: BrowserProfile.maxLength + 1)))
        XCTAssertThrowsError(try BrowserProfile.validated("a\u{7}b"))
        XCTAssertThrowsError(try BrowserProfile.validated("a\nb"))
    }

    func testPaneInfoCarriesTheProfileAndOlderAnswersDecode() throws {
        let info = PaneInfo(id: "p1", kind: .browser, title: "", focused: false, attention: false, profile: "work")
        let decoded = try JSONDecoder().decode(PaneInfo.self, from: JSONEncoder().encode(info))
        XCTAssertEqual(decoded.profile, "work")
        let old = #"{"id":"p1","kind":"browser","title":"","focused":false,"attention":false}"#
        XCTAssertNil(try JSONDecoder().decode(PaneInfo.self, from: Data(old.utf8)).profile)
        XCTAssertEqual(BrowserProfile.label(nil), "shared (default)")
        XCTAssertEqual(BrowserProfile.label("work"), "\"work\"")
    }

    func testChangesTellSharedFromSpaces() throws {
        XCTAssertNil(try BrowserProfile.change(""))
        XCTAssertEqual(try BrowserProfile.change(" a "), "a")
        XCTAssertThrowsError(try BrowserProfile.change("   "))
    }

    func testIdentifiersComeFromTheNameAlone() {
        let id = BrowserProfile.identifier(for: "work")
        XCTAssertEqual(id, BrowserProfile.identifier(for: "work"))
        XCTAssertNotEqual(id, BrowserProfile.identifier(for: "Work"))
        XCTAssertEqual(id.uuidString.dropFirst(14).first, "5")  // version 5
        XCTAssertTrue("89AB".contains(id.uuidString.dropFirst(19).first!))  // RFC 4122 variant
    }
}
