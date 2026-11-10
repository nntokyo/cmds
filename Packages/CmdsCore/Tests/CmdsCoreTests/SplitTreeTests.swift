import XCTest
@testable import CmdsCore

/// The split tree operations behind moving and swapping panes (#218).
final class SplitTreeTests: XCTestCase {
    /// `(h p1 (v p2 p3))`: p1 on the left, p2 above p3 on the right.
    private func makeTree() -> SplitNode {
        SplitNode(axis: .horizontal, ratio: 0.3, first: SplitNode(paneID: "p1"),
                  second: SplitNode(axis: .vertical, ratio: 0.7, first: SplitNode(paneID: "p2"), second: SplitNode(paneID: "p3")))
    }

    func testRemovingCollapsesTheParent() throws {
        let root = makeTree()
        let result = try XCTUnwrap(SplitNode.removing("p2", from: root))
        XCTAssertEqual(result.structureKey, "(h p1 p3)")
        XCTAssertEqual(result.ratio, 0.3, "the root keeps its ratio")
        XCTAssertTrue(result.leaf(for: "p3")?.parent === result, "the sibling hangs off the collapsed parent")

        let other = try XCTUnwrap(SplitNode.removing("p1", from: makeTree()))
        XCTAssertEqual(other.structureKey, "(v p2 p3)")
        XCTAssertEqual(other.ratio, 0.7, "the sibling's ratio moves up with it")
        XCTAssertTrue(other.leaf(for: "p2")?.parent === other)
    }

    func testRemovingTheLastPaneEmptiesTheTree() {
        XCTAssertNil(SplitNode.removing("p1", from: SplitNode(paneID: "p1")))
        let root = SplitNode(paneID: "p1")
        XCTAssertTrue(SplitNode.removing("p9", from: root) === root, "an unknown pane changes nothing")
    }

    func testInsertOnEachSide() {
        let expected: [PaneSide: String] = [.left: "(h p9 p1)", .right: "(h p1 p9)", .top: "(v p9 p1)", .bottom: "(v p1 p9)"]
        for side in PaneSide.allCases {
            let leaf = SplitNode(paneID: "p1")
            leaf.ratio = 0.8
            leaf.insert("p9", side: side)
            XCTAssertEqual(leaf.structureKey, expected[side], "\(side)")
            XCTAssertEqual(leaf.ratio, 0.5, "an even split")
            XCTAssertTrue(leaf.leaf(for: "p9")?.parent === leaf)
            XCTAssertTrue(leaf.leaf(for: "p1")?.parent === leaf)
        }
    }

    func testInsertIntoASplitNodeDoesNothing() {
        let root = makeTree()
        root.insert("p9", side: .left)
        XCTAssertEqual(root.structureKey, "(h p1 (v p2 p3))")
    }

    func testSplitStillPutsTheNewPaneSecond() {
        let leaf = SplitNode(paneID: "p1")
        leaf.split(axis: .vertical, newPaneID: "p2")
        XCTAssertEqual(leaf.structureKey, "(v p1 p2)")
    }

    /// Moving within a workspace: take the pane out, then insert it beside the target (looked up again: the
    /// collapse may have moved the target into the parent node).
    func testMoveWithinOneTree() throws {
        let root = makeTree()
        let afterRemoval = try XCTUnwrap(SplitNode.removing("p1", from: root))
        try XCTUnwrap(afterRemoval.leaf(for: "p3")).insert("p1", side: .left)
        XCTAssertEqual(afterRemoval.structureKey, "(v p2 (h p1 p3))")
        XCTAssertEqual(afterRemoval.paneIDs, ["p2", "p1", "p3"])

        // The target was the moved pane's sibling: it is now the root leaf.
        let pair = SplitNode(axis: .horizontal, ratio: 0.5, first: SplitNode(paneID: "a"), second: SplitNode(paneID: "b"))
        let single = try XCTUnwrap(SplitNode.removing("a", from: pair))
        try XCTUnwrap(single.leaf(for: "b")).insert("a", side: .bottom)
        XCTAssertEqual(single.structureKey, "(v b a)")
    }

    func testSwapWithinOneTreeKeepsTheLayout() {
        let root = makeTree()
        XCTAssertTrue(SplitNode.swapping("p1", in: root, with: "p3", in: root))
        XCTAssertEqual(root.structureKey, "(h p3 (v p2 p1))")
        XCTAssertEqual(root.ratio, 0.3)
    }

    func testSwapAcrossTrees() {
        let a = makeTree()
        let b = SplitNode(axis: .vertical, ratio: 0.5, first: SplitNode(paneID: "q1"), second: SplitNode(paneID: "q2"))
        XCTAssertTrue(SplitNode.swapping("p2", in: a, with: "q2", in: b))
        XCTAssertEqual(a.structureKey, "(h p1 (v q2 p3))")
        XCTAssertEqual(b.structureKey, "(v q1 p2)")
    }

    func testSwapRefusesTheSamePaneOrAMissingOne() {
        let root = makeTree()
        XCTAssertFalse(SplitNode.swapping("p1", in: root, with: "p1", in: root))
        XCTAssertFalse(SplitNode.swapping("p1", in: root, with: "p9", in: root))
        XCTAssertEqual(root.structureKey, "(h p1 (v p2 p3))")
    }

    func testPaneSideFromDropZones() {
        XCTAssertEqual(PaneSide(zone: .left), .left)
        XCTAssertEqual(PaneSide(zone: .bottom), .bottom)
        XCTAssertNil(PaneSide(zone: .center), "the centre swaps")
        let pane = CGRect(x: 10, y: 20, width: 200, height: 100)
        XCTAssertEqual(PaneSide.left.highlight(in: pane), CGRect(x: 10, y: 20, width: 100, height: 100))
        XCTAssertEqual(PaneSide.right.highlight(in: pane), CGRect(x: 110, y: 20, width: 100, height: 100))
        XCTAssertEqual(PaneSide.top.highlight(in: pane), CGRect(x: 10, y: 20, width: 200, height: 50))
        XCTAssertEqual(PaneSide.bottom.highlight(in: pane), CGRect(x: 10, y: 70, width: 200, height: 50))
    }

    // MARK: pane.move params

    func testMoveRequestDestinations() throws {
        let beside = try PaneMoveRequest(params: ["pane": "p1", "beside": "p2", "side": "top"])
        XCTAssertEqual(beside, PaneMoveRequest(pane: "p1", beside: "p2", side: .top))
        let into = try PaneMoveRequest(params: ["pane": "p1", "workspace": "w2", "focus": false])
        XCTAssertEqual(into, PaneMoveRequest(pane: "p1", workspace: "w2", side: .right, focus: false))
        let fresh = try PaneMoveRequest(params: ["pane": "p1", "newWorkspace": true])
        XCTAssertTrue(fresh.newWorkspace)
        XCTAssertTrue(fresh.focus)
    }

    func testMoveRequestRefusesBadParams() {
        let bad: [JSONValue] = [
            ["workspace": "w2"],
            ["pane": "p1"],
            ["pane": "p1", "newWorkspace": false],
            ["pane": "p1", "beside": "p1"],
            ["pane": "p1", "beside": "p2", "side": "middle"],
            ["pane": "p1", "newWorkspace": true, "workspace": "w2"],
            ["pane": "p1", "newWorkspace": true, "side": "left"],
            ["pane": "p1", "workspace": 2],
            ["pane": "p1", "workspace": "w2", "focus": "yes"],
        ]
        for params in bad {
            XCTAssertThrowsError(try PaneMoveRequest(params: params), "\(params)") { error in
                XCTAssertEqual((error as? RPCError)?.code, RPCError.invalidParams("").code)
            }
        }
    }

    // MARK: Processes follow a moved pane

    func testProcessOriginFollowsItsPane() {
        let origin = ProcessOrigins.Origin(workspace: "w1", pane: "p3")
        XCTAssertEqual(origin.following(["p3": "w2"]), ProcessOrigins.Origin(workspace: "w2", pane: "p3"))
        XCTAssertEqual(origin.following(["p3": "w1"]), origin)
        XCTAssertEqual(origin.following([:]), origin, "a closed pane's processes stay (leftovers)")
        let noPane = ProcessOrigins.Origin(workspace: "w1")
        XCTAssertEqual(noPane.following(["p3": "w2"]), noPane)
    }
}
