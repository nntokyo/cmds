import XCTest
@testable import CmdsCore

/// Tab groups: several panes stacked in one leaf of the split tree.
final class SplitTreeTabTests: XCTestCase {
    func testAddingTabsShowsTheNewOneAfterTheAnchor() {
        let leaf = SplitNode(paneID: "p1")
        leaf.addTab("p2")
        leaf.addTab("p3", after: "p1")
        XCTAssertEqual(leaf.tabs, ["p1", "p3", "p2"])
        XCTAssertEqual(leaf.paneID, "p3")
        XCTAssertEqual(leaf.paneIDs, ["p1", "p3", "p2"], "every tab is a pane of the tree")
        XCTAssertEqual(leaf.visiblePaneIDs, ["p3"])
        XCTAssertEqual(leaf.structureKey, "[p1,p3,p2|p3]")
        XCTAssertEqual(leaf.layoutNode, .pane(id: "p3"), "the wire layout has the shown tab")
        leaf.addTab("p4", select: false)
        XCTAssertEqual(leaf.paneID, "p3")
        XCTAssertEqual(leaf.tabs, ["p1", "p3", "p4", "p2"])
        leaf.addTab("p1")
        XCTAssertEqual(leaf.tabs.count, 4, "a pane is never added twice")
    }

    func testLeafLookupAndBackgroundTabs() {
        let root = SplitNode(axis: .horizontal, ratio: 0.5, first: SplitNode(tabs: ["a", "b"], selected: "b"),
                             second: SplitNode(paneID: "c"))
        XCTAssertTrue(root.leaf(for: "a") === root.leaf(for: "b"))
        XCTAssertTrue(root.isBackgroundTab("a"))
        XCTAssertFalse(root.isBackgroundTab("b"))
        XCTAssertFalse(root.isBackgroundTab("c"))
        XCTAssertEqual(root.paneIDs, ["a", "b", "c"])
        XCTAssertEqual(root.visiblePaneIDs, ["b", "c"])
        XCTAssertTrue(root.leaf(for: "a")?.isTabGroup == true)
        XCTAssertFalse(root.leaf(for: "c")?.isTabGroup == true)
    }

    func testUnknownSelectionShowsTheFirstTab() {
        XCTAssertEqual(SplitNode(tabs: ["a", "b"], selected: "z").paneID, "a")
        XCTAssertEqual(SplitNode(tabs: ["a", "b"], selected: nil).paneID, "a")
    }

    func testSelectingAndCyclingTabs() {
        let leaf = SplitNode(tabs: ["a", "b", "c"], selected: "a")
        XCTAssertEqual(leaf.tab(offset: 1), "b")
        XCTAssertEqual(leaf.tab(offset: -1), "c", "wraps around")
        XCTAssertTrue(leaf.selectTab("c"))
        XCTAssertEqual(leaf.tab(offset: 1), "a")
        XCTAssertFalse(leaf.selectTab("z"))
        XCTAssertEqual(leaf.paneID, "c")
        XCTAssertNil(SplitNode(paneID: "x").tab(offset: 1), "no other tab")
    }

    func testMovingATab() {
        let leaf = SplitNode(tabs: ["a", "b", "c"], selected: "a")
        XCTAssertTrue(leaf.moveTab("a", to: 2))
        XCTAssertEqual(leaf.tabs, ["b", "c", "a"])
        XCTAssertTrue(leaf.moveTab("a", to: -5))
        XCTAssertEqual(leaf.tabs, ["a", "b", "c"])
        XCTAssertFalse(leaf.moveTab("z", to: 0))
        XCTAssertEqual(leaf.paneID, "a")
    }

    func testRemovingTheShownTabShowsTheNextOne() throws {
        let root = SplitNode(axis: .vertical, ratio: 0.4, first: SplitNode(tabs: ["a", "b", "c"], selected: "b"),
                             second: SplitNode(paneID: "d"))
        let result = try XCTUnwrap(SplitNode.removing("b", from: root))
        XCTAssertTrue(result === root)
        XCTAssertEqual(root.structureKey, "(v [a,c|c] d)")
        _ = SplitNode.removing("c", from: root)
        XCTAssertEqual(root.structureKey, "(v a d)", "the last tab before it; one tab left is a plain leaf")
        XCTAssertEqual(root.ratio, 0.4, "the split stays")
    }

    func testRemovingABackgroundTabKeepsTheShownOne() {
        let leaf = SplitNode(tabs: ["a", "b", "c"], selected: "c")
        _ = SplitNode.removing("a", from: leaf)
        XCTAssertEqual(leaf.tabs, ["b", "c"])
        XCTAssertEqual(leaf.paneID, "c")
    }

    func testCollapsingKeepsTheSiblingsTabs() throws {
        let root = SplitNode(axis: .horizontal, ratio: 0.5, first: SplitNode(paneID: "a"),
                             second: SplitNode(tabs: ["b", "c"], selected: "c"))
        let result = try XCTUnwrap(SplitNode.removing("a", from: root))
        XCTAssertEqual(result.structureKey, "[b,c|c]")
        XCTAssertEqual(result.tabs, ["b", "c"])
        XCTAssertTrue(result.leaf(for: "b") === result)
    }

    func testInsertingBesideAGroupKeepsItsTabsTogether() {
        let leaf = SplitNode(tabs: ["a", "b"], selected: "a")
        leaf.insert("x", side: .right)
        XCTAssertEqual(leaf.structureKey, "(h [a,b|a] x)")
        XCTAssertTrue(leaf.tabs.isEmpty, "a split holds no tabs")
        XCTAssertTrue(leaf.leaf(for: "b")?.parent === leaf)
    }

    func testSwappingTabsAcrossLeaves() {
        let root = SplitNode(axis: .horizontal, ratio: 0.5, first: SplitNode(tabs: ["a", "b"], selected: "a"),
                             second: SplitNode(paneID: "c"))
        XCTAssertTrue(SplitNode.swapping("b", in: root, with: "c", in: root))
        XCTAssertEqual(root.structureKey, "(h [a,c|a] b)", "the background tab's place stays in the background")
        XCTAssertTrue(SplitNode.swapping("a", in: root, with: "b", in: root))
        XCTAssertEqual(root.structureKey, "(h [b,c|b] a)", "the shown place stays shown")
    }

    func testSwappingTabsOfOneGroup() {
        let leaf = SplitNode(tabs: ["a", "b", "c"], selected: "a")
        XCTAssertTrue(SplitNode.swapping("a", in: leaf, with: "c", in: leaf))
        XCTAssertEqual(leaf.tabs, ["c", "b", "a"])
        XCTAssertEqual(leaf.paneID, "c", "the shown position stays shown")
        XCTAssertTrue(SplitNode.swapping("b", in: leaf, with: "a", in: leaf))
        XCTAssertEqual(leaf.tabs, ["c", "a", "b"])
        XCTAssertEqual(leaf.paneID, "c")
    }

    func testStackingTurnsPanesIntoATabGroup() throws {
        // (h a (v b c)) with b and c becoming tabs of a.
        let root = SplitNode(axis: .horizontal, ratio: 0.5, first: SplitNode(paneID: "a"),
                             second: SplitNode(axis: .vertical, ratio: 0.5, first: SplitNode(paneID: "b"), second: SplitNode(paneID: "c")))
        let stacked = try XCTUnwrap(SplitNode.stacking(["a", "b", "c"], selected: "b", in: root))
        XCTAssertEqual(stacked.structureKey, "[a,b,c|b]")
        let other = SplitNode(axis: .horizontal, ratio: 0.5, first: SplitNode(paneID: "a"), second: SplitNode(paneID: "b"))
        XCTAssertNil(SplitNode.stacking(["a", "z"], selected: nil, in: other), "a missing pane changes nothing")
        XCTAssertNil(SplitNode.stacking(["a", "a"], selected: nil, in: other))
        XCTAssertNil(SplitNode.stacking(["a"], selected: nil, in: other))
        XCTAssertEqual(other.structureKey, "(h a b)")
        let unknownSelection = try XCTUnwrap(SplitNode.stacking(["b", "a"], selected: "z", in: other))
        XCTAssertEqual(unknownSelection.structureKey, "[b,a|b]")
    }

    func testEvenColumnsStayShallow() throws {
        indirect enum T: Equatable { case leaf(Int), split(Double, T, T) }
        func depth(_ t: T) -> Int { if case .split(_, let a, let b) = t { return 1 + max(depth(a), depth(b)) }; return 0 }
        func leaves(_ t: T) -> [Int] { if case .split(_, let a, let b) = t { return leaves(a) + leaves(b) }; if case .leaf(let i) = t { return [i] }; return [] }
        let many = try XCTUnwrap(SplitNode.evenColumns((0..<100).map(T.leaf)) { .split($0, $1, $2) })
        XCTAssertEqual(leaves(many), Array(0..<100), "reading order kept")
        XCTAssertLessThanOrEqual(depth(many), 7)
        XCTAssertEqual(SplitNode.evenColumns([T.leaf(1)]) { .split($0, $1, $2) }, .leaf(1))
        XCTAssertNil(SplitNode.evenColumns([T]()) { .split($0, $1, $2) })
        if case .split(let ratio, _, _) = try XCTUnwrap(SplitNode.evenColumns((0..<3).map(T.leaf)) { .split($0, $1, $2) }) {
            XCTAssertEqual(ratio, 1.0 / 3.0, accuracy: 0.0001, "one column of three on the left")
        }
    }
}

final class TabSuspensionTests: XCTestCase {
    private func tab(hidden: TimeInterval = 3600, unused: TimeInterval = 3600, loading: Bool = false, scheme: String? = "https",
                     busy: Bool = false, suspended: Bool = false) -> TabSuspension.Candidate {
        .init(hiddenFor: hidden, unusedFor: unused, loading: loading, scheme: scheme, busy: busy, alreadySuspended: suspended)
    }

    func testOnlyIdleLoadedPagesAreSuspended() {
        XCTAssertTrue(TabSuspension.eligible(tab(), minutes: 30))
        XCTAssertFalse(TabSuspension.eligible(tab(), minutes: 0), "off")
        XCTAssertFalse(TabSuspension.eligible(tab(hidden: 60), minutes: 30), "shown recently")
        XCTAssertFalse(TabSuspension.eligible(tab(unused: 60), minutes: 30), "an agent used it recently")
        XCTAssertFalse(TabSuspension.eligible(tab(loading: true), minutes: 30))
        XCTAssertFalse(TabSuspension.eligible(tab(scheme: "about"), minutes: 30))
        XCTAssertFalse(TabSuspension.eligible(tab(scheme: nil), minutes: 30))
        XCTAssertFalse(TabSuspension.eligible(tab(busy: true), minutes: 30), "responsive view, watch or console")
        XCTAssertFalse(TabSuspension.eligible(tab(suspended: true), minutes: 30))
        XCTAssertTrue(TabSuspension.eligible(tab(scheme: "FILE"), minutes: 30))
    }
}
