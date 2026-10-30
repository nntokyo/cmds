import Foundation
import CoreGraphics

/// Where a drag over a tile (or over the single workspace shown) would put what is dragged
/// (docs/guide/workspaces-and-panes.md "Tiled view").
public enum TileDropZone: String, Codable, Equatable, Sendable, CaseIterable {
    /// Next to the tile in its row.
    case left, right
    /// A new row above / below the tile's row.
    case top, bottom
    /// In place of the tile: swaps two tiles, or replaces the tile with a workspace that was not tiled.
    case center

    /// Share of a tile's width / height that counts as its edge.
    public static let edgeFraction = 0.25

    /// Zone of `point` in `rect` (origin top-left, y down): the nearest edge when within `edgeFraction` of it, else
    /// the centre. Edges are compared relative to the tile's size, so tall and wide tiles behave alike.
    public static func zone(at point: CGPoint, in rect: CGRect) -> TileDropZone {
        guard rect.width > 0, rect.height > 0 else { return .center }
        let x = min(max((point.x - rect.minX) / rect.width, 0), 1)
        let y = min(max((point.y - rect.minY) / rect.height, 0), 1)
        let distances: [(TileDropZone, Double)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < edgeFraction else { return .center }
        return nearest.0
    }

    /// The translucent highlight shown while hovering: half of the tile for left / right, half of the whole row
    /// (the new row spans the width) for top / bottom, the tile itself for the centre. Origin top-left, y down.
    public func highlight(tile: CGRect, row: CGRect) -> CGRect {
        switch self {
        case .left: return CGRect(x: tile.minX, y: tile.minY, width: tile.width / 2, height: tile.height)
        case .right: return CGRect(x: tile.midX, y: tile.minY, width: tile.width / 2, height: tile.height)
        case .top: return CGRect(x: row.minX, y: row.minY, width: row.width, height: row.height / 2)
        case .bottom: return CGRect(x: row.minX, y: row.midY, width: row.width, height: row.height / 2)
        case .center: return tile
        }
    }
}

/// An explicit tile arrangement: rows of workspace ids, top to bottom, each left to right. Made when the user drags
/// tiles or sidebar rows onto the content area (or moves a tile with ⌃⇧⌘ + arrow); without one the grid follows
/// `TileLayout.shape`. Pure value logic, shared with the tests.
public struct TileArrangement: Codable, Equatable, Sendable {
    public private(set) var rows: [[String]]

    /// Empty rows and repeated ids are dropped (first occurrence wins).
    public init(rows: [[String]]) {
        var seen = Set<String>()
        self.rows = rows.map { row in row.filter { seen.insert($0).inserted } }.filter { !$0.isEmpty }
    }

    /// `ids` in reading order cut into rows of `shape` (e.g. the automatic grid on screen); leftovers form a last row.
    public static func auto(ids: [String], shape: [Int]) -> TileArrangement {
        var rows: [[String]] = []
        var rest = ids[...]
        for count in shape where !rest.isEmpty {
            rows.append(Array(rest.prefix(max(count, 0))))
            rest = rest.dropFirst(max(count, 0))
        }
        if !rest.isEmpty { rows.append(Array(rest)) }
        return TileArrangement(rows: rows)
    }

    /// Tile ids in reading order.
    public var ids: [String] { rows.flatMap { $0 } }
    /// Tiles per row (the grid shape).
    public var shape: [Int] { rows.map(\.count) }
    public var count: Int { rows.reduce(0) { $0 + $1.count } }

    public func position(of id: String) -> (row: Int, column: Int)? {
        for (row, members) in rows.enumerated() {
            if let column = members.firstIndex(of: id) { return (row, column) }
        }
        return nil
    }

    /// Without `ids` (rows left empty disappear).
    public func removing(_ ids: [String]) -> TileArrangement {
        let gone = Set(ids)
        return TileArrangement(rows: rows.map { $0.filter { !gone.contains($0) } })
    }

    /// Keeps only `ids` (in their current places) and appends the new ones of `ids` to the last row, or as a new row
    /// when the last row already has as many tiles as the widest row. Used when the tiled set changes another way
    /// (⌘-click in the sidebar, a closed workspace).
    public func reconciled(with ids: [String]) -> TileArrangement {
        let wanted = Set(ids)
        var result = TileArrangement(rows: rows.map { $0.filter(wanted.contains) })
        let present = Set(result.ids)
        for id in ids where !present.contains(id) {
            let widest = result.rows.map(\.count).max() ?? 0
            if let last = result.rows.indices.last, result.rows[last].count < max(widest, 2) {
                result.rows[last].append(id)
            } else {
                result.rows.append([id])
            }
        }
        return result
    }

    /// `moving` (sidebar rows or a tile; in this order) dropped on `zone` of tile `target`. Tiles already in the
    /// arrangement move; others join. `center` swaps a single tile with `target`, or puts the new workspaces in
    /// `target`'s place (`target` leaves the tiled view). nil when nothing would change, `target` is not a tile,
    /// or the result would exceed `TileLayout.maxTiles`.
    public func dropping(_ moving: [String], on target: String, zone: TileDropZone) -> TileArrangement? {
        var unique: [String] = []
        for id in moving where !unique.contains(id) { unique.append(id) }
        guard !unique.isEmpty, position(of: target) != nil else { return nil }
        let result: TileArrangement
        if zone == .center {
            guard !unique.contains(target) else { return nil }
            if unique.count == 1, let other = unique.first, let from = position(of: other),
               let to = position(of: target) {
                var swapped = rows
                swapped[from.row][from.column] = target
                swapped[to.row][to.column] = other
                result = TileArrangement(rows: swapped)
            } else {
                // Replace: the moving ids take target's place (taken out of their old places first).
                var rest = removing(unique).rows
                guard let to = TileArrangement(rows: rest).position(of: target) else { return nil }
                rest[to.row].replaceSubrange(to.column...to.column, with: unique)
                result = TileArrangement(rows: rest)
            }
        } else {
            if unique == [target] { return nil }
            let others = unique.filter { $0 != target }
            var rest = removing(others).rows
            guard let to = TileArrangement(rows: rest).position(of: target) else { return nil }
            switch zone {
            case .left: rest[to.row].insert(contentsOf: others, at: to.column)
            case .right: rest[to.row].insert(contentsOf: others, at: to.column + 1)
            case .top: rest.insert(others, at: to.row)
            case .bottom: rest.insert(others, at: to.row + 1)
            case .center: break
            }
            result = TileArrangement(rows: rest)
        }
        guard result != self, result.count <= TileLayout.maxTiles else { return nil }
        return result
    }

    public enum Direction: String, Sendable { case left, right, up, down }

    /// Keyboard move of tile `id` (View › Move Tile …): left / right swap with the neighbour in the row; up / down
    /// move it into the row above / below at the same column (clamped), or — from the top / bottom row when it shares
    /// the row — into a new row of its own. nil when it cannot move that way.
    public func moving(_ id: String, _ direction: Direction) -> TileArrangement? {
        guard let from = position(of: id) else { return nil }
        var rows = self.rows
        switch direction {
        case .left, .right:
            let to = from.column + (direction == .left ? -1 : 1)
            guard rows[from.row].indices.contains(to) else { return nil }
            rows[from.row].swapAt(from.column, to)
        case .up, .down:
            let target = from.row + (direction == .up ? -1 : 1)
            if rows.indices.contains(target) {
                rows[from.row].remove(at: from.column)
                rows[target].insert(id, at: min(from.column, rows[target].count))
            } else {
                guard rows[from.row].count > 1 else { return nil }
                rows[from.row].remove(at: from.column)
                rows.insert([id], at: direction == .up ? 0 : rows.count)
            }
        }
        let result = TileArrangement(rows: rows)
        return result == self ? nil : result
    }
}

/// Sidebar drag-reorder: index math for moving rows of an ordered list.
public enum ReorderMath {
    /// `order` with `moving` (kept in their current relative order) taken out and inserted before the item that was
    /// at `dropIndex` (0…order.count, a gap index as `NSTableView` reports drops "above" a row). nil if unchanged.
    public static func reorder(_ order: [String], moving: [String], toGap dropIndex: Int) -> [String]? {
        let movingSet = Set(moving)
        let moved = order.filter(movingSet.contains)
        guard !moved.isEmpty else { return nil }
        let gap = min(max(dropIndex, 0), order.count)
        // Items before the gap that stay: their count is where the moved block goes in the remaining list.
        let insertAt = order[..<gap].filter { !movingSet.contains($0) }.count
        var rest = order.filter { !movingSet.contains($0) }
        rest.insert(contentsOf: moved, at: insertAt)
        return rest == order ? nil : rest
    }
}
