import XCTest
@testable import CmdsCore

/// The command palette's matcher (#173).
final class FuzzyMatchTests: XCTestCase {
    func testSubsequenceMatches() {
        XCTAssertNotNil(FuzzyMatch.match("nwk", "New Workspace"))
        XCTAssertNotNil(FuzzyMatch.match("splr", "Split Right"))
        XCTAssertNil(FuzzyMatch.match("rs", "Split"))
        XCTAssertNil(FuzzyMatch.match("xyz", "New Workspace"))
        XCTAssertNil(FuzzyMatch.match("splitt", "Split"))
    }

    func testIgnoresCaseAndWidth() {
        XCTAssertNotNil(FuzzyMatch.match("SPLIT", "split right"))
        XCTAssertNotNil(FuzzyMatch.match("ＡＢＣ", "abc"))
        XCTAssertNotNil(FuzzyMatch.match("abc", "ＡＢＣ"))
    }

    func testJapaneseKanaAreInterchangeable() {
        XCTAssertNotNil(FuzzyMatch.match("わーく", "ワークスペース"))
        XCTAssertNotNil(FuzzyMatch.match("ワーク", "わーくすぺーす"))
        XCTAssertNotNil(FuzzyMatch.match("分割", "右に分割"))
        XCTAssertNil(FuzzyMatch.match("分割", "右に移動"))
    }

    func testPositionsPointAtMatchedCharacters() {
        let result = FuzzyMatch.match("sr", "Split Right")
        XCTAssertEqual(result?.positions, [0, 6]) // word starts preferred over the "r" nowhere else
        XCTAssertEqual(FuzzyMatch.match("ght", "Split Right")?.positions, [8, 9, 10])
    }

    func testPrefersAdjacentAndWordStarts() {
        let adjacent = FuzzyMatch.match("work", "Workspace")!.score
        let scattered = FuzzyMatch.match("work", "Was Over Rock Kit")!.score
        let buried = FuzzyMatch.match("work", "Homework")!.score
        XCTAssertGreaterThan(adjacent, buried)
        XCTAssertGreaterThan(adjacent, scattered)
        let wordStarts = FuzzyMatch.match("sr", "Split Right")!.score
        let inside = FuzzyMatch.match("sr", "Usurp")!.score
        XCTAssertGreaterThan(wordStarts, inside)
    }

    func testWordsMatchInAnyOrder() {
        XCTAssertNotNil(FuzzyMatch.match("right split", "Split Right"))
        XCTAssertNil(FuzzyMatch.match("right merge", "Split Right"))
        XCTAssertEqual(FuzzyMatch.match("  ", "Anything")?.score, 0)
    }

    func testRankOrdersBestFirstAndKeepsOrderForTies() {
        let items = ["Close Pane", "Split Right", "Split Down", "Spotify"]
        let ranked = FuzzyMatch.rank(items, query: "split") { FuzzyMatch.Candidate($0) }.map(\.item)
        XCTAssertEqual(ranked, ["Split Right", "Split Down"])
        XCTAssertEqual(FuzzyMatch.rank(items, query: "") { FuzzyMatch.Candidate($0) }.map(\.item), items)
        let best = FuzzyMatch.rank(["Homework", "Workspace 2", "Was Over Rock Kit"], query: "work") { FuzzyMatch.Candidate($0) }
        XCTAssertEqual(best.first?.item, "Workspace 2")
        XCTAssertEqual(best.count, 3)
    }

    func testCharactersThatFoldLongerKeepOffsets() {
        // "ß" folds to "ss": it stays one character, so offsets still index the candidate.
        let result = FuzzyMatch.match("st", "Straße test")
        XCTAssertEqual(result?.positions, [0, 1])
        XCTAssertNotNil(FuzzyMatch.match("ße", "Straße"))
    }
}
