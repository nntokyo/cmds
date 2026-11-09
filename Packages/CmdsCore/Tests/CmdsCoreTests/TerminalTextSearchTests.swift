import XCTest
@testable import CmdsCore

/// The find bar's own search over terminal rows (Match Case, regular expressions; #173).
final class TerminalTextSearchTests: XCTestCase {
    private let rows = [
        "$ make build",
        "error: Build failed (ERROR 2)",
        "",
        "日本語 error here",
        "no hits",
    ]

    func testPlainIgnoresCaseByDefault() throws {
        let hits = try TerminalTextSearch.matches("error", in: rows, options: TerminalSearchOptions())
        XCTAssertEqual(hits, [
            TerminalSearchMatch(row: 1, column: 0, width: 5),
            TerminalSearchMatch(row: 1, column: 21, width: 5),
            TerminalSearchMatch(row: 3, column: 7, width: 5), // three wide characters and a space before it
        ])
    }

    func testMatchCase() throws {
        let hits = try TerminalTextSearch.matches("ERROR", in: rows, options: TerminalSearchOptions(caseSensitive: true))
        XCTAssertEqual(hits, [TerminalSearchMatch(row: 1, column: 21, width: 5)])
        XCTAssertEqual(try TerminalTextSearch.matches("build", in: rows, options: TerminalSearchOptions(caseSensitive: true)).map(\.row), [0])
    }

    func testRegexIgnoresCaseUnlessMatchCase() throws {
        let any = try TerminalTextSearch.matches(#"error \d|failed"#, in: rows, options: TerminalSearchOptions(regex: true))
        XCTAssertEqual(any.map(\.column), [13, 21])
        let exact = try TerminalTextSearch.matches(#"[A-Z]{5}"#, in: rows, options: TerminalSearchOptions(caseSensitive: true, regex: true))
        XCTAssertEqual(exact, [TerminalSearchMatch(row: 1, column: 21, width: 5)])
    }

    func testWideCharactersCountTwoCells() throws {
        let hits = try TerminalTextSearch.matches("本語", in: rows, options: TerminalSearchOptions())
        XCTAssertEqual(hits, [TerminalSearchMatch(row: 3, column: 2, width: 4)])
    }

    func testRowsAreOffsetByFirstRow() throws {
        let hits = try TerminalTextSearch.matches("make", in: rows, firstRow: 100, options: TerminalSearchOptions())
        XCTAssertEqual(hits, [TerminalSearchMatch(row: 100, column: 2, width: 4)])
    }

    func testEmptyQueryAndZeroLengthMatchesFindNothing() throws {
        XCTAssertEqual(try TerminalTextSearch.matches("", in: rows, options: TerminalSearchOptions()), [])
        XCTAssertEqual(try TerminalTextSearch.matches("x*", in: rows, options: TerminalSearchOptions(regex: true)), [])
    }

    func testInvalidRegexThrows() {
        XCTAssertThrowsError(try TerminalTextSearch.matches("(", in: rows, options: TerminalSearchOptions(regex: true))) { error in
            XCTAssertEqual(error as? TerminalTextSearch.QueryError, .invalidRegex("("))
        }
        // As plain text it is just a character.
        XCTAssertEqual(try TerminalTextSearch.matches("(", in: rows, options: TerminalSearchOptions()).count, 1)
    }

    func testOverlappingOccurrencesCountOnce() throws {
        XCTAssertEqual(try TerminalTextSearch.matches("aa", in: ["aaaa"], options: TerminalSearchOptions()).map(\.column), [0, 2])
    }

    func testLimit() throws {
        let many = Array(repeating: "x x x", count: 10)
        XCTAssertEqual(try TerminalTextSearch.matches("x", in: many, options: TerminalSearchOptions(), limit: 7).count, 7)
    }

    func testNearestIndexGoesUpFromTheGivenRow() {
        let hits = [TerminalSearchMatch(row: 2, column: 0, width: 1), TerminalSearchMatch(row: 5, column: 0, width: 1),
                    TerminalSearchMatch(row: 9, column: 0, width: 1)]
        XCTAssertEqual(TerminalTextSearch.nearestIndex(in: hits, atOrAbove: nil), 2)
        XCTAssertEqual(TerminalTextSearch.nearestIndex(in: hits, atOrAbove: 6), 1)
        XCTAssertEqual(TerminalTextSearch.nearestIndex(in: hits, atOrAbove: 5), 1)
        XCTAssertEqual(TerminalTextSearch.nearestIndex(in: hits, atOrAbove: 1), 2)
        XCTAssertNil(TerminalTextSearch.nearestIndex(in: [], atOrAbove: 3))
    }

    func testLongScrollbackIsQuick() throws {
        let big = (0..<100_000).map { "line \($0) some output text" + ($0 % 1000 == 0 ? " NEEDLE" : "") }
        let start = Date()
        let hits = try TerminalTextSearch.matches("needle", in: big, options: TerminalSearchOptions())
        XCTAssertEqual(hits.count, 100)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
