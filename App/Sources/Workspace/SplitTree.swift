import Foundation
import CmdsCore

/// Mutable binary split tree. Leaves hold pane IDs; inner nodes hold an axis and the first child's share.
/// A reference type so split views can keep a handle to "their" node while the user drags a divider.
final class SplitNode {
    enum Content {
        case leaf(paneID: String)
        case split(axis: SplitAxis, first: SplitNode, second: SplitNode)
    }

    private(set) var content: Content
    /// Fraction of the available length given to the first child (inner nodes only).
    var ratio: Double
    private(set) weak var parent: SplitNode?

    static let minRatio = 0.08

    init(paneID: String) {
        content = .leaf(paneID: paneID)
        ratio = 0.5
    }

    init(axis: SplitAxis, ratio: Double, first: SplitNode, second: SplitNode) {
        content = .split(axis: axis, first: first, second: second)
        self.ratio = ratio
        first.parent = self
        second.parent = self
    }

    var paneID: String? {
        if case .leaf(let id) = content { return id }
        return nil
    }

    /// Pane IDs in reading order (left-to-right, top-to-bottom).
    var paneIDs: [String] {
        switch content {
        case .leaf(let id): return [id]
        case .split(_, let first, let second): return first.paneIDs + second.paneIDs
        }
    }

    func leaf(for paneID: String) -> SplitNode? {
        switch content {
        case .leaf(let id): return id == paneID ? self : nil
        case .split(_, let first, let second): return first.leaf(for: paneID) ?? second.leaf(for: paneID)
        }
    }

    /// Turns this leaf into a split whose second child is `newPaneID`.
    func split(axis: SplitAxis, newPaneID: String) {
        guard case .leaf(let existing) = content else { return }
        let first = SplitNode(paneID: existing)
        let second = SplitNode(paneID: newPaneID)
        content = .split(axis: axis, first: first, second: second)
        ratio = 0.5
        first.parent = self
        second.parent = self
    }

    /// Removes the leaf for `paneID`. Returns the new root (nil when the tree became empty).
    static func removing(_ paneID: String, from root: SplitNode) -> SplitNode? {
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

    /// Structural fingerprint (ignores ratios) used to decide when views must be rebuilt.
    var structureKey: String {
        switch content {
        case .leaf(let id): return id
        case .split(let axis, let first, let second):
            return "(\(axis == .horizontal ? "h" : "v") \(first.structureKey) \(second.structureKey))"
        }
    }

    var layoutNode: LayoutNode {
        switch content {
        case .leaf(let id): return .pane(id: id)
        case .split(let axis, let first, let second):
            return .split(axis: axis, ratio: ratio, first: first.layoutNode, second: second.layoutNode)
        }
    }
}
