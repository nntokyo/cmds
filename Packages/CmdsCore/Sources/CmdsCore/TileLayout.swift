import Foundation

/// Grid of the tiled view (several workspaces side by side, docs/guide/workspaces-and-panes.md "Tiled view"):
/// rows of tiles, each row with its own column widths. Pure layout math, shared with the tests.
public enum TileLayout {
    /// At most this many workspaces are tiled; the rest are left out (the view says so).
    public static let maxTiles = 9
    /// Smallest share of a row or column a divider drag leaves.
    public static let minFraction = 0.12

    /// Tiles per row (top to bottom) for `count` tiles in an area of `aspect` = width / height.
    /// 2 → side by side (stacked when the area is portrait), 3 → three columns when wide (≥ 1.6), else 2 + 1,
    /// 4 → 2 × 2, 5 → 3 + 2, 6 → 3 × 2, 7–9 → three rows of up to three. Earlier rows get the extra tiles.
    public static func shape(count: Int, aspect: Double) -> [Int] {
        let count = min(max(count, 0), maxTiles)
        switch count {
        case 0: return []
        case 1: return [1]
        case 2: return aspect < 0.8 ? [1, 1] : [2]
        case 3: return aspect >= 1.6 ? [3] : [2, 1]
        default:
            let columns = Int(Double(count).squareRoot().rounded(.up))
            let rows = (count + columns - 1) / columns
            let base = count / rows
            let extra = count % rows
            return (0..<rows).map { $0 < extra ? base + 1 : base }
        }
    }

    /// Frames (origin top-left, y down) of the tiles in reading order, `gap` points apart. Ratios that do not fit
    /// `shape` are replaced by even ones.
    public static func frames(shape: [Int], ratios: TileRatios?, width: Double, height: Double,
                              gap: Double) -> [(x: Double, y: Double, width: Double, height: Double)] {
        let ratios = ratios.flatMap { $0.fits(shape) ? $0 : nil } ?? TileRatios.even(shape: shape)
        var frames: [(x: Double, y: Double, width: Double, height: Double)] = []
        let heights = lengths(ratios.rows, total: height, gap: gap)
        var y = 0.0
        for (row, columns) in shape.enumerated() {
            let widths = lengths(ratios.columns[row], total: width, gap: gap)
            var x = 0.0
            for column in 0..<columns {
                frames.append((x, y, widths[column], heights[row]))
                x += widths[column] + gap
            }
            y += heights[row] + gap
        }
        return frames
    }

    /// Splits `total` minus the gaps by `fractions`, in whole points; the last part takes the rounding rest.
    static func lengths(_ fractions: [Double], total: Double, gap: Double) -> [Double] {
        guard !fractions.isEmpty else { return [] }
        let available = max(total - gap * Double(fractions.count - 1), 0)
        let sum = fractions.reduce(0, +)
        var result: [Double] = []
        var used = 0.0
        for (index, fraction) in fractions.enumerated() {
            if index == fractions.count - 1 {
                result.append(max(available - used, 0))
            } else {
                let length = (available * fraction / (sum > 0 ? sum : 1)).rounded()
                result.append(length)
                used += length
            }
        }
        return result
    }
}

/// Divider positions of a tile grid: row heights and, per row, column widths, as fractions summing to 1.
public struct TileRatios: Codable, Equatable, Sendable {
    public var rows: [Double]
    public var columns: [[Double]]

    public init(rows: [Double], columns: [[Double]]) {
        self.rows = rows
        self.columns = columns
    }

    public static func even(shape: [Int]) -> TileRatios {
        TileRatios(rows: Array(repeating: 1 / Double(max(shape.count, 1)), count: shape.count),
                   columns: shape.map { Array(repeating: 1 / Double(max($0, 1)), count: $0) })
    }

    /// Same number of rows and columns per row as `shape`, all fractions positive.
    public func fits(_ shape: [Int]) -> Bool {
        rows.count == shape.count && columns.map(\.count) == shape
            && (rows + columns.flatMap { $0 }).allSatisfy { $0.isFinite && $0 > 0 }
    }

    /// Moves the divider after row `index` so that row `index` ends at `position` (0…1 of the whole height).
    public mutating func moveRowDivider(after index: Int, to position: Double) {
        Self.move(&rows, after: index, to: position)
    }

    /// Moves the divider after column `index` of `row` to `position` (0…1 of the row's width).
    public mutating func moveColumnDivider(row: Int, after index: Int, to position: Double) {
        guard columns.indices.contains(row) else { return }
        Self.move(&columns[row], after: index, to: position)
    }

    /// Only the two parts next to the divider change; each keeps at least `TileLayout.minFraction`.
    private static func move(_ parts: inout [Double], after index: Int, to position: Double) {
        guard index >= 0, index + 1 < parts.count, position.isFinite else { return }
        let start = parts[..<index].reduce(0, +)
        let pair = parts[index] + parts[index + 1]
        let minimum = min(TileLayout.minFraction, pair / 2)
        let first = min(max(position - start, minimum), pair - minimum)
        parts[index] = first
        parts[index + 1] = pair - first
    }
}

/// Result of the socket method `view.tile`: what the window shows after the call.
public struct TileStatus: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        /// One workspace (the normal view).
        case off
        /// Every workspace the sidebar shows (filter applied), up to `TileLayout.maxTiles`.
        case all
        /// A chosen set of workspaces.
        case selected
    }

    public var mode: Mode
    /// Tiled workspace ids in display order (empty when `mode` is off).
    public var workspaces: [String]
    /// The workspace with the keyboard (the selected one).
    public var active: String?
    /// The tile shown alone for now (⇧⌘↩), if any.
    public var zoomed: String?
    /// Workspaces of the set left out beyond `TileLayout.maxTiles`.
    public var hidden: Int

    public init(mode: Mode, workspaces: [String], active: String?, zoomed: String?, hidden: Int) {
        self.mode = mode
        self.workspaces = workspaces
        self.active = active
        self.zoomed = zoomed
        self.hidden = hidden
    }
}
