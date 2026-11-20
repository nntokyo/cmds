import Foundation
import CoreGraphics

/// Mutable binary split tree of a workspace (macOS app). Leaves hold pane IDs; inner nodes hold an axis and the first
/// child's share. A reference type so split views can keep a handle to "their" node while the user drags a divider.
/// Moving and swapping panes (#218) are tree operations here so they can be tested without the app.
/// A leaf can stack several panes as tabs (`tabs`); `paneID` is the one shown.
public final class SplitNode {
    public enum Content {
        /// The pane shown here (the selected tab when the leaf holds several).
        case leaf(paneID: String)
        case split(axis: SplitAxis, first: SplitNode, second: SplitNode)
    }

    public private(set) var content: Content
    /// Leaves: every pane stacked here, in tab order (just `paneID` when the leaf is no tab group). Empty for splits.
    public private(set) var tabs: [String]
    /// Fraction of the available length given to the first child (inner nodes only).
    public var ratio: Double
    public private(set) weak var parent: SplitNode?

    public static let minRatio = 0.08

    public init(paneID: String) {
        content = .leaf(paneID: paneID)
        tabs = [paneID]
        ratio = 0.5
    }

    /// A tab group: `tabs` in order, showing `selected` (the first tab when `selected` is not one of them).
    public init(tabs: [String], selected: String?) {
        precondition(!tabs.isEmpty, "a leaf needs a pane")
        let shown = selected.flatMap { tabs.contains($0) ? $0 : nil } ?? tabs[0]
        content = .leaf(paneID: shown)
        self.tabs = tabs
        ratio = 0.5
    }

    public init(axis: SplitAxis, ratio: Double, first: SplitNode, second: SplitNode) {
        content = .split(axis: axis, first: first, second: second)
        tabs = []
        self.ratio = ratio
        first.parent = self
        second.parent = self
    }

    public var paneID: String? {
        if case .leaf(let id) = content { return id }
        return nil
    }

    /// Pane IDs in reading order (left-to-right, top-to-bottom; the tabs of a leaf in tab order).
    public var paneIDs: [String] {
        switch content {
        case .leaf: return tabs
        case .split(_, let first, let second): return first.paneIDs + second.paneIDs
        }
    }

    /// Panes on screen: the shown tab of every leaf, in reading order.
    public var visiblePaneIDs: [String] {
        switch content {
        case .leaf(let id): return [id]
        case .split(_, let first, let second): return first.visiblePaneIDs + second.visiblePaneIDs
        }
    }

    /// The leaf holding `paneID`, shown or as a background tab.
    public func leaf(for paneID: String) -> SplitNode? {
        switch content {
        case .leaf: return tabs.contains(paneID) ? self : nil
        case .split(_, let first, let second): return first.leaf(for: paneID) ?? second.leaf(for: paneID)
        }
    }

    /// A leaf with more than one tab.
    public var isTabGroup: Bool { tabs.count > 1 }

    /// The pane is stacked in a leaf but not the one shown there.
    public func isBackgroundTab(_ paneID: String) -> Bool {
        guard let leaf = leaf(for: paneID) else { return false }
        return leaf.paneID != paneID
    }

    /// Adds `paneID` as a tab of this leaf, right after `after` (default: the shown tab), and shows it when `select`.
    public func addTab(_ paneID: String, after: String? = nil, select: Bool = true) {
        guard case .leaf(let shown) = content, !tabs.contains(paneID) else { return }
        let anchor = after.flatMap { tabs.firstIndex(of: $0) } ?? tabs.firstIndex(of: shown) ?? tabs.count - 1
        tabs.insert(paneID, at: anchor + 1)
        if select { content = .leaf(paneID: paneID) }
    }

    /// Shows the tab `paneID` of this leaf. False when it is not one of its tabs.
    @discardableResult
    public func selectTab(_ paneID: String) -> Bool {
        guard case .leaf = content, tabs.contains(paneID) else { return false }
        content = .leaf(paneID: paneID)
        return true
    }

    /// The tab `offset` places from the shown one, wrapping around (nil for a leaf without other tabs).
    public func tab(offset: Int) -> String? {
        guard case .leaf(let shown) = content, tabs.count > 1, let index = tabs.firstIndex(of: shown) else { return nil }
        let count = tabs.count
        return tabs[((index + offset) % count + count) % count]
    }

    /// Moves the tab `paneID` to `index` within this leaf's tabs (clamped). False when it is not one of them.
    @discardableResult
    public func moveTab(_ paneID: String, to index: Int) -> Bool {
        guard let from = tabs.firstIndex(of: paneID) else { return false }
        tabs.remove(at: from)
        tabs.insert(paneID, at: max(0, min(index, tabs.count)))
        return true
    }

    /// Turns this leaf into a split whose second child is `newPaneID`.
    public func split(axis: SplitAxis, newPaneID: String) {
        insert(newPaneID, side: axis == .horizontal ? .right : .bottom)
    }

    /// Turns this leaf into an even split with `paneID` on `side` of the pane it held (#218: dropping a pane on another
    /// pane's edge, `pane.move` with `beside`). The leaf's tabs stay together on their side.
    public func insert(_ paneID: String, side: PaneSide) {
        guard case .leaf(let existing) = content else { return }
        let kept = SplitNode(tabs: tabs, selected: existing)
        let added = SplitNode(paneID: paneID)
        let (first, second) = side.placesFirst ? (added, kept) : (kept, added)
        content = .split(axis: side.axis, first: first, second: second)
        tabs = []
        ratio = 0.5
        first.parent = self
        second.parent = self
    }

    /// Removes `paneID`. A tab of a group leaves the group (the tab after it is shown, else the one before, when it
    /// was the shown one); the only pane of a leaf removes the leaf and its sibling takes the parent's place. Returns
    /// the new root (nil when the tree became empty).
    public static func removing(_ paneID: String, from root: SplitNode) -> SplitNode? {
        guard let leaf = root.leaf(for: paneID) else { return root }
        if leaf.tabs.count > 1, let index = leaf.tabs.firstIndex(of: paneID) {
            leaf.tabs.remove(at: index)
            if leaf.paneID == paneID { leaf.content = .leaf(paneID: leaf.tabs[min(index, leaf.tabs.count - 1)]) }
            return root
        }
        guard let parent = leaf.parent, case .split(_, let first, let second) = parent.content else { return nil }
        let sibling = first === leaf ? second : first
        // Collapse: the parent takes over the sibling's content.
        parent.content = sibling.content
        parent.tabs = sibling.tabs
        parent.ratio = sibling.ratio
        if case .split(_, let a, let b) = sibling.content {
            a.parent = parent
            b.parent = parent
        }
        return root
    }

    /// Exchanges the places of two panes, in one tree or in two (`pane.swap`, #218). False when either is missing or
    /// they are the same pane.
    @discardableResult
    public static func swapping(_ a: String, in rootA: SplitNode, with b: String, in rootB: SplitNode) -> Bool {
        guard a != b, let leafA = rootA.leaf(for: a), let leafB = rootB.leaf(for: b) else { return false }
        // Each pane takes the other's place: its tab position, and shown when the other one was.
        let shownA = leafA.paneID == a
        let shownB = leafB.paneID == b
        if leafA === leafB, let i = leafA.tabs.firstIndex(of: a), let j = leafA.tabs.firstIndex(of: b) {
            leafA.tabs.swapAt(i, j)
            if shownA { leafA.content = .leaf(paneID: b) } else if shownB { leafA.content = .leaf(paneID: a) }
            return true
        }
        leafA.replaceTab(a, with: b, shown: shownA)
        leafB.replaceTab(b, with: a, shown: shownB)
        return true
    }

    /// Puts `new` at the tab position of `old`, shown when `shown`.
    private func replaceTab(_ old: String, with new: String, shown: Bool) {
        guard let index = tabs.firstIndex(of: old) else { return }
        tabs[index] = new
        if shown { content = .leaf(paneID: new) }
    }

    /// Structural fingerprint (ignores ratios) used to decide when views must be rebuilt.
    public var structureKey: String {
        switch content {
        case .leaf(let id): return tabs.count > 1 ? "[\(tabs.joined(separator: ","))|\(id)]" : id
        case .split(let axis, let first, let second):
            return "(\(axis == .horizontal ? "h" : "v") \(first.structureKey) \(second.structureKey))"
        }
    }

    /// The tree as sent over the wire: a tab group is its shown pane (`PaneInfo.tabs` lists the group).
    public var layoutNode: LayoutNode {
        switch content {
        case .leaf(let id): return .pane(id: id)
        case .split(let axis, let first, let second):
            return .split(axis: axis, ratio: ratio, first: first.layoutNode, second: second.layoutNode)
        }
    }
}

/// Where a pane goes next to another one (#218): `pane.move` `side`, the edges of a pane while dragging one over it.
public enum PaneSide: String, Codable, Sendable, CaseIterable {
    case left, right, top, bottom

    /// Left / right split side by side, top / bottom stack.
    public var axis: SplitAxis { self == .left || self == .right ? .horizontal : .vertical }

    /// The moved pane is the first child (left of / above the other one).
    public var placesFirst: Bool { self == .left || self == .top }

    /// The side of a drop zone over a pane; nil for the centre (that swaps the two panes).
    public init?(zone: TileDropZone) {
        switch zone {
        case .left: self = .left
        case .right: self = .right
        case .top: self = .top
        case .bottom: self = .bottom
        case .center: return nil
        }
    }

    /// The translucent highlight while dragging a pane over `pane` (origin top-left, y down): the half the moved pane
    /// will take.
    public func highlight(in pane: CGRect) -> CGRect {
        switch self {
        case .left: return CGRect(x: pane.minX, y: pane.minY, width: pane.width / 2, height: pane.height)
        case .right: return CGRect(x: pane.midX, y: pane.minY, width: pane.width / 2, height: pane.height)
        case .top: return CGRect(x: pane.minX, y: pane.minY, width: pane.width, height: pane.height / 2)
        case .bottom: return CGRect(x: pane.minX, y: pane.midY, width: pane.width, height: pane.height / 2)
        }
    }
}
