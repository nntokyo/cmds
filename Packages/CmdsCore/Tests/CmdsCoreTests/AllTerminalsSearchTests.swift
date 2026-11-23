import Foundation
import XCTest
@testable import CmdsCore

/// Find in All Terminals (#174 G12).
final class AllTerminalsSearchTests: XCTestCase {
    func testNewestFirstPerTerminalInOrder() {
        let hits = AllTerminalsSearch.search([
            (key: "p1", text: "build ok\nError: disk full\nmore\nerror: again"),
            (key: "p2", text: "no match here\n  ERROR in tests"),
        ], query: "error")
        XCTAssertEqual(hits.map(\.key), ["p1", "p1", "p2"])
        XCTAssertEqual(hits.map(\.line), ["error: again", "Error: disk full", "ERROR in tests"])
        XCTAssertEqual(hits.map(\.fromEnd), [0, 2, 0])
        XCTAssertEqual(hits[2].positions, [0, 1, 2, 3, 4], "positions after the indent is trimmed")
    }

    func testDiacriticsAndJapanese() {
        let hits = AllTerminalsSearch.search([(key: "p", text: "café crème\nビルドに失敗しました")], query: "CAFE")
        XCTAssertEqual(hits.first?.positions, [0, 1, 2, 3])
        XCTAssertEqual(AllTerminalsSearch.search([(key: "p", text: "ビルドに失敗しました")], query: "失敗").first?.positions, [4, 5])
    }

    func testLongLinesAreCutAroundTheMatch() {
        let line = String(repeating: "a", count: 100) + "NEEDLE" + String(repeating: "b", count: 300)
        let hit = try! XCTUnwrap(AllTerminalsSearch.search([(key: "p", text: line)], query: "needle").first)
        XCTAssertTrue(hit.line.hasPrefix("…"))
        XCTAssertTrue(hit.line.hasSuffix("…"))
        let chars = Array(hit.line)
        XCTAssertEqual(String(hit.positions.map { chars[$0] }), "NEEDLE")
    }

    func testEmptyQueryAndLimit() {
        XCTAssertTrue(AllTerminalsSearch.search([(key: "p", text: "x")], query: "  ").isEmpty)
        let many = Array(repeating: "hit", count: 50).joined(separator: "\n")
        XCTAssertEqual(AllTerminalsSearch.search([(key: "p", text: many)], query: "hit", limit: 10).count, 10)
    }
}
