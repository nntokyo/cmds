import XCTest
@testable import CmdsCore

final class TileArrangementTests: XCTestCase {
    private let tile = CGRect(x: 100, y: 50, width: 400, height: 200)

    // MARK: Drop zones

    func testZoneEdgesAndCentre() {
        XCTAssertEqual(TileDropZone.zone(at: CGPoint(x: 110, y: 150), in: tile), .left)
        XCTAssertEqual(TileDropZone.zone(at: CGPoint(x: 490, y: 150), in: tile), .right)
        XCTAssertEqual(TileDropZone.zone(at: CGPoint(x: 300, y: 55), in: tile), .top)
        XCTAssertEqual(TileDropZone.zone(at: CGPoint(x: 300, y: 245), in: tile), .bottom)
        XCTAssertEqual(TileDropZone.zone(at: CGPoint(x: 300, y: 150), in: tile), .center)
        // Just inside / outside the 25 % edge band (100 pt of 400 wide).
        XCTAssertEqual(TileDropZone.zone(at: CGPoint(x: 199, y: 150), in: tile), .left)
        XCTAssertEqual(TileDropZone.zone(at: CGPoint(x: 201, y: 150), in: tile), .center)
    }

    func testZoneCornerPicksTheRelativelyNearerEdge() {
        // 20 pt from the left (5 %) and 20 pt from the top (10 %): left wins.
        XCTAssertEqual(TileDropZone.zone(at: CGPoint(x: 120, y: 70), in: tile), .left)
        // 80 pt from the left (20 %) and 10 pt from the top (5 %): top wins.
        XCTAssertEqual(TileDropZone.zone(at: CGPoint(x: 180, y: 60), in: tile), .top)
    }

    func testZoneOutsideOrEmptyRect() {
        XCTAssertEqual(TileDropZone.zone(at: CGPoint(x: 0, y: 150), in: tile), .left, "clamped to the tile")
        XCTAssertEqual(TileDropZone.zone(at: .zero, in: .zero), .center)
    }

    func testHighlights() {
        let row = CGRect(x: 0, y: 50, width: 1000, height: 200)
        XCTAssertEqual(TileDropZone.left.highlight(tile: tile, row: row), CGRect(x: 100, y: 50, width: 200, height: 200))
        XCTAssertEqual(TileDropZone.right.highlight(tile: tile, row: row), CGRect(x: 300, y: 50, width: 200, height: 200))
        XCTAssertEqual(TileDropZone.top.highlight(tile: tile, row: row), CGRect(x: 0, y: 50, width: 1000, height: 100))
        XCTAssertEqual(TileDropZone.bottom.highlight(tile: tile, row: row), CGRect(x: 0, y: 150, width: 1000, height: 100))
        XCTAssertEqual(TileDropZone.center.highlight(tile: tile, row: row), tile)
    }

    // MARK: Arrangement

    func testInitDropsEmptyRowsAndDuplicates() {
        let arrangement = TileArrangement(rows: [["a", "b"], [], ["b", "c"]])
        XCTAssertEqual(arrangement.rows, [["a", "b"], ["c"]])
        XCTAssertEqual(arrangement.shape, [2, 1])
        XCTAssertEqual(arrangement.ids, ["a", "b", "c"])
    }

    func testAutoFollowsShape() {
        XCTAssertEqual(TileArrangement.auto(ids: ["a", "b", "c", "d", "e"], shape: [3, 2]).rows,
                       [["a", "b", "c"], ["d", "e"]])
        XCTAssertEqual(TileArrangement.auto(ids: ["a", "b", "c"], shape: [2]).rows, [["a", "b"], ["c"]],
                       "leftovers form a last row")
    }

    func testDropNewWorkspaceOnEdges() {
        let grid = TileArrangement(rows: [["a", "b"], ["c"]])
        XCTAssertEqual(grid.dropping(["x"], on: "b", zone: .left)?.rows, [["a", "x", "b"], ["c"]])
        XCTAssertEqual(grid.dropping(["x"], on: "b", zone: .right)?.rows, [["a", "b", "x"], ["c"]])
        XCTAssertEqual(grid.dropping(["x"], on: "b", zone: .top)?.rows, [["x"], ["a", "b"], ["c"]])
        XCTAssertEqual(grid.dropping(["x"], on: "c", zone: .bottom)?.rows, [["a", "b"], ["c"], ["x"]])
    }

    func testDropOnSingleWorkspaceMakesTwoTiles() {
        let single = TileArrangement(rows: [["a"]])
        XCTAssertEqual(single.dropping(["x"], on: "a", zone: .left)?.rows, [["x", "a"]])
        XCTAssertEqual(single.dropping(["x"], on: "a", zone: .bottom)?.rows, [["a"], ["x"]])
        XCTAssertEqual(single.dropping(["x"], on: "a", zone: .center)?.rows, [["x"]], "replace: the caller shows x alone")
    }

    func testCentreSwapsTilesAndReplacesWithNewOnes() {
        let grid = TileArrangement(rows: [["a", "b"], ["c"]])
        XCTAssertEqual(grid.dropping(["a"], on: "c", zone: .center)?.rows, [["c", "b"], ["a"]])
        XCTAssertEqual(grid.dropping(["x"], on: "b", zone: .center)?.rows, [["a", "x"], ["c"]])
        XCTAssertEqual(grid.dropping(["x", "y"], on: "c", zone: .center)?.rows, [["a", "b"], ["x", "y"]])
        XCTAssertNil(grid.dropping(["c"], on: "c", zone: .center))
    }

    func testMovingATileTakesItOutOfItsOldPlace() {
        let grid = TileArrangement(rows: [["a", "b"], ["c"]])
        // c to the left of a: the bottom row disappears.
        XCTAssertEqual(grid.dropping(["c"], on: "a", zone: .left)?.rows, [["c", "a", "b"]])
        // a below c: a new row.
        XCTAssertEqual(grid.dropping(["a"], on: "c", zone: .bottom)?.rows, [["b"], ["c"], ["a"]])
        // b above its own row: a row of its own on top.
        XCTAssertEqual(grid.dropping(["b"], on: "a", zone: .top)?.rows, [["b"], ["a"], ["c"]])
        // a on its own edge or to where it already is: nothing changes.
        XCTAssertNil(grid.dropping(["a"], on: "a", zone: .right))
        XCTAssertNil(grid.dropping(["a"], on: "b", zone: .left))
    }

    func testDropRefusedBeyondMaxOrOnUnknownTarget() {
        let full = TileArrangement.auto(ids: (1...TileLayout.maxTiles).map { "w\($0)" }, shape: [3, 3, 3])
        XCTAssertNil(full.dropping(["x"], on: "w1", zone: .left))
        XCTAssertNotNil(full.dropping(["x"], on: "w1", zone: .center), "replacing keeps the count")
        XCTAssertNotNil(full.dropping(["w9"], on: "w1", zone: .left), "moving keeps the count")
        XCTAssertNil(full.dropping(["x"], on: "nope", zone: .left))
        XCTAssertNil(full.dropping([], on: "w1", zone: .left))
    }

    func testRemovingAndReconciling() {
        let grid = TileArrangement(rows: [["a", "b"], ["c"]])
        XCTAssertEqual(grid.removing(["c"]).rows, [["a", "b"]])
        XCTAssertEqual(grid.reconciled(with: ["a", "c", "d"]).rows, [["a"], ["c", "d"]])
        XCTAssertEqual(grid.reconciled(with: ["a", "b", "c", "d", "e"]).rows, [["a", "b"], ["c", "d"], ["e"]])
    }

    func testKeyboardMoves() {
        let grid = TileArrangement(rows: [["a", "b", "c"], ["d"]])
        XCTAssertEqual(grid.moving("b", .left)?.rows, [["b", "a", "c"], ["d"]])
        XCTAssertEqual(grid.moving("b", .right)?.rows, [["a", "c", "b"], ["d"]])
        XCTAssertNil(grid.moving("a", .left))
        XCTAssertNil(grid.moving("c", .right))
        XCTAssertEqual(grid.moving("c", .down)?.rows, [["a", "b"], ["d", "c"]], "column clamped to the row's end")
        XCTAssertEqual(grid.moving("a", .down)?.rows, [["b", "c"], ["a", "d"]])
        XCTAssertEqual(grid.moving("d", .up)?.rows, [["d", "a", "b", "c"]], "the emptied row disappears")
        XCTAssertEqual(grid.moving("b", .up)?.rows, [["b"], ["a", "c"], ["d"]], "a new row on top")
        XCTAssertNil(grid.moving("d", .down), "alone in the bottom row")
        XCTAssertNil(grid.moving("x", .left))
    }

    func testCodableRoundTrip() throws {
        let grid = TileArrangement(rows: [["a", "b"], ["c"]])
        let data = try JSONEncoder().encode(grid)
        XCTAssertEqual(try JSONDecoder().decode(TileArrangement.self, from: data), grid)
        let status = TileStatus(mode: .selected, workspaces: ["a", "b", "c"], active: "a", zoomed: nil, hidden: 0,
                                rows: grid.rows)
        XCTAssertEqual(try JSONDecoder().decode(TileStatus.self, from: JSONEncoder().encode(status)), status)
        // Older payloads without rows still decode.
        let old = #"{"mode":"all","workspaces":["a","b"],"hidden":0}"#.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(TileStatus.self, from: old).rows)
    }

    // MARK: Sidebar reorder

    func testReorderSingleRow() {
        let order = ["a", "b", "c", "d"]
        XCTAssertEqual(ReorderMath.reorder(order, moving: ["a"], toGap: 3), ["b", "c", "a", "d"])
        XCTAssertEqual(ReorderMath.reorder(order, moving: ["a"], toGap: 4), ["b", "c", "d", "a"])
        XCTAssertEqual(ReorderMath.reorder(order, moving: ["d"], toGap: 0), ["d", "a", "b", "c"])
        XCTAssertEqual(ReorderMath.reorder(order, moving: ["c"], toGap: 1), ["a", "c", "b", "d"])
        XCTAssertNil(ReorderMath.reorder(order, moving: ["b"], toGap: 1), "dropped just above itself")
        XCTAssertNil(ReorderMath.reorder(order, moving: ["b"], toGap: 2), "dropped just below itself")
        XCTAssertNil(ReorderMath.reorder(order, moving: ["x"], toGap: 0))
    }

    func testReorderSeveralRowsKeepsTheirOrder() {
        let order = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(ReorderMath.reorder(order, moving: ["d", "a"], toGap: 3), ["b", "c", "a", "d", "e"])
        XCTAssertEqual(ReorderMath.reorder(order, moving: ["b", "e"], toGap: 0), ["b", "e", "a", "c", "d"])
        XCTAssertEqual(ReorderMath.reorder(order, moving: ["a", "c"], toGap: 99), ["b", "d", "e", "a", "c"])
    }
}
