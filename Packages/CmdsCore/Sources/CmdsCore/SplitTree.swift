import Foundation
import CoreGraphics

/// Mutable binary split tree of a workspace (macOS app). Leaves hold pane IDs; inner nodes hold an axis and the first
/// child's share. A reference type so split views can keep a handle to "their" node while the user drags a divider.
/// Moving and swapping panes (#218) are tree operations here so they can be tested without the app.
public final class SplitNode {
    public enum Content {
        case leaf(paneID: String)
        case split(axis: SplitAxis, first: SplitNode, second: SplitNode)
    }

    public private(set) var content: Content
    /// Fraction of the available length given to the first child (inner nodes only).
    public var ratio: Double
    public private(set) weak var parent: SplitNode?

    public static let minRatio = 0.08

    public init(paneID: String) {
        content = .leaf(paneID: paneID)
        ratio = 0.5
    }

    public init(axis: SplitAxis, ratio: Double, first: SplitNode, second: SplitNode) {
        content = .split(axis: axis, first: first, second: second)
        self.ratio = ratio
        first.parent = self
        second.parent = self
    }

    public var paneID: String? {
        if case .leaf(let id) = content { return id }
        return nil
    }

    /// Pane IDs in reading order (left-to-right, top-to-bottom).
    public var paneIDs: [String] {
        switch content {
        case .leaf(let id): return [id]
        case .split(_, let first, let second): return first.paneIDs + second.paneIDs
        }
    }

    public func leaf(for paneID: String) -> SplitNode? {
        switch content {
        case .leaf(let id): return id == paneID ? self : nil
        case .split(_, let first, let second): return first.leaf(for: paneID) ?? second.leaf(for: paneID)
        }
    }

    /// Turns this leaf into a split whose second child is `newPaneID`.
    public func split(axis: SplitAxis, newPaneID: String) {
        insert(newPaneID, side: axis == .horizontal ? .right : .bottom)
    }

    /// Turns this leaf into an even split with `paneID` on `side` of the pane it held (#218: dropping a pane on another
    /// pane's edge, `pane.move` with `beside`).
    public func insert(_ paneID: String, side: PaneSide) {
        guard case .leaf(let existing) = content else { return }
        let kept = SplitNode(paneID: existing)
        let added = SplitNode(paneID: paneID)
        let (first, second) = side.placesFirst ? (added, kept) : (kept, added)
        content = .split(axis: side.axis, first: first, second: second)
        ratio = 0.5
        first.parent = self
        second.parent = self
    }

    /// Removes the leaf for `paneID`; its sibling takes the parent's place. Returns the new root (nil when the tree
    /// became empty).
    public static func removing(_ paneID: String, from root: SplitNode) -> SplitNode? {
        guard let leaf = root.leaf(for: paneID) else { return root }
        guard let parent = leaf.parent, case .split(_, let first, let second) = parent.content else { return nil }
        let sibling = first === leaf ? second : first
        // Collapse: the parent takes over the sibling's content.
        parent.content = sibling.content
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
        leafA.content = .leaf(paneID: b)
        leafB.content = .leaf(paneID: a)
        return true
    }

    /// Structural fingerprint (ignores ratios) used to decide when views must be rebuilt.
    public var structureKey: String {
        switch content {
        case .leaf(let id): return id
        case .split(let axis, let first, let second):
            return "(\(axis == .horizontal ? "h" : "v") \(first.structureKey) \(second.structureKey))"
        }
    }

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
