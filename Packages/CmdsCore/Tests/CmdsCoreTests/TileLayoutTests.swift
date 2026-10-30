import XCTest
@testable import CmdsCore

final class TileLayoutTests: XCTestCase {
    func testShapes() {
        XCTAssertEqual(TileLayout.shape(count: 1, aspect: 1.6), [1])
        XCTAssertEqual(TileLayout.shape(count: 2, aspect: 1.6), [2])
        XCTAssertEqual(TileLayout.shape(count: 2, aspect: 0.6), [1, 1])
        XCTAssertEqual(TileLayout.shape(count: 3, aspect: 1.9), [3])
        XCTAssertEqual(TileLayout.shape(count: 3, aspect: 1.3), [2, 1])
        XCTAssertEqual(TileLayout.shape(count: 4, aspect: 1.6), [2, 2])
        XCTAssertEqual(TileLayout.shape(count: 5, aspect: 1.6), [3, 2])
        XCTAssertEqual(TileLayout.shape(count: 6, aspect: 1.6), [3, 3])
        XCTAssertEqual(TileLayout.shape(count: 7, aspect: 1.6), [3, 2, 2])
        XCTAssertEqual(TileLayout.shape(count: 9, aspect: 1.6), [3, 3, 3])
        XCTAssertEqual(TileLayout.shape(count: 14, aspect: 1.6), [3, 3, 3], "capped at maxTiles")
    }

    func testFramesFillTheAreaWithGaps() {
        let frames = TileLayout.frames(shape: [3, 2], ratios: nil, width: 1001, height: 600, gap: 1)
        XCTAssertEqual(frames.count, 5)
        // First row: three columns ending exactly at the right edge.
        XCTAssertEqual(frames[0].x, 0)
        XCTAssertEqual(frames[2].x + frames[2].width, 1001)
        XCTAssertEqual(frames[1].x, frames[0].width + 1)
        // Second row starts below the first plus the gap and ends at the bottom.
        XCTAssertEqual(frames[3].y, frames[0].height + 1)
        XCTAssertEqual(frames[4].y + frames[4].height, 600)
        XCTAssertEqual(frames[3].width + frames[4].width + 1, 1001)
    }

    func testMismatchedRatiosFallBackToEven() {
        let ratios = TileRatios(rows: [0.7, 0.3], columns: [[0.5, 0.5], [1]])
        let frames = TileLayout.frames(shape: [2, 2], ratios: ratios, width: 400, height: 400, gap: 0)
        XCTAssertEqual(frames.map(\.height), [200, 200, 200, 200])
        XCTAssertTrue(ratios.fits([2, 1]))
        XCTAssertFalse(ratios.fits([2, 2]))
    }

    func testDividerMovesOnlyItsNeighboursAndKeepsAMinimum() {
        var ratios = TileRatios.even(shape: [3, 2])
        ratios.moveColumnDivider(row: 0, after: 0, to: 0.5)
        XCTAssertEqual(ratios.columns[0][0], 0.5, accuracy: 1e-9)
        XCTAssertEqual(ratios.columns[0][1], 1.0 / 6, accuracy: 1e-9)
        XCTAssertEqual(ratios.columns[0][2], 1.0 / 3, accuracy: 1e-9)
        ratios.moveColumnDivider(row: 0, after: 1, to: 0.99)
        XCTAssertEqual(ratios.columns[0][2], TileLayout.minFraction, accuracy: 1e-9)
        XCTAssertEqual(ratios.columns[0].reduce(0, +), 1, accuracy: 1e-9)
        ratios.moveRowDivider(after: 0, to: -3)
        XCTAssertEqual(ratios.rows[0], TileLayout.minFraction, accuracy: 1e-9)
        XCTAssertEqual(ratios.rows.reduce(0, +), 1, accuracy: 1e-9)
        // Out of range: nothing happens.
        let before = ratios
        ratios.moveRowDivider(after: 1, to: 0.5)
        ratios.moveColumnDivider(row: 5, after: 0, to: 0.5)
        XCTAssertEqual(ratios, before)
    }

    func testStatusRoundTrips() throws {
        let status = TileStatus(mode: .selected, workspaces: ["w1", "w3"], active: "w3", zoomed: nil, hidden: 0)
        let data = try JSONEncoder().encode(status)
        XCTAssertEqual(try JSONDecoder().decode(TileStatus.self, from: data), status)
    }
}
