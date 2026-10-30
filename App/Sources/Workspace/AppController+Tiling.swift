import Foundation
import CmdsCore

/// Which workspaces the content area tiles (docs/guide/workspaces-and-panes.md "Tiled view").
enum TileMode: Equatable {
    case off
    /// Every workspace the sidebar shows (with its filter), in sidebar order.
    case all
    /// A chosen set (sidebar ⌘-click / ⇧-click, `view.tile` with workspaces).
    case selected([String])
}

/// Tiled view: several workspaces side by side, each a live tile with its own split tree. The selected workspace is
/// the tile with the keyboard; panes are re-parented into the tiles, never recreated.
extension AppController {
    /// Tile candidates in display order, before the `TileLayout.maxTiles` cap.
    var tileCandidates: [String] {
        let known = Set(workspaces.map(\.id))
        let visible = (visibleWorkspaceOrder?() ?? workspaces.map(\.id)).filter(known.contains)
        switch tileMode {
        case .off:
            return []
        case .all:
            return visible
        case .selected(let ids):
            // A dragged arrangement has its own order.
            if let tileArrangement { return tileArrangement.ids.filter(known.contains) }
            let chosen = Set(ids)
            // Sidebar order; members hidden by the filter keep their place after the visible ones.
            let order = visible + workspaces.map(\.id).filter { !visible.contains($0) }
            return order.filter(chosen.contains)
        }
    }

    /// Workspaces shown as tiles, in order; empty unless at least two are tiled.
    var tiledWorkspaceIDs: [String] {
        let candidates = tileCandidates
        guard candidates.count >= 2 else { return [] }
        var tiles = Array(candidates.prefix(TileLayout.maxTiles))
        // Beyond the cap the selected workspace still gets a tile (in place of the last one).
        if let selected = selectedWorkspaceID, candidates.contains(selected), !tiles.contains(selected) {
            tiles[tiles.count - 1] = selected
        }
        return tiles
    }

    var tiledWorkspaces: [Workspace] { tiledWorkspaceIDs.compactMap(workspace(id:)) }

    var isTiling: Bool { tiledWorkspaceIDs.count >= 2 }

    /// Tiling candidates left out by the cap.
    var hiddenTileCount: Int { isTiling ? max(tileCandidates.count - TileLayout.maxTiles, 0) : 0 }

    var tileStatus: TileStatus {
        let ids = tiledWorkspaceIDs
        let mode: TileStatus.Mode
        switch tileMode {
        case _ where ids.isEmpty: mode = .off
        case .all: mode = .all
        case .selected: mode = .selected
        case .off: mode = .off
        }
        return TileStatus(mode: mode, workspaces: ids, active: selectedWorkspaceID,
                          zoomed: ids.isEmpty ? nil : tileZoomedWorkspaceID, hidden: hiddenTileCount,
                          rows: ids.isEmpty ? nil : tileArrangement?.rows)
    }

    /// Switches the tiled view. `active` (else the selected workspace if tiled, else the first tile) gets the keyboard.
    /// A set of fewer than two workspaces turns tiling off. A dragged arrangement adapts to a changed set (kept rows,
    /// new tiles at the end) unless `keepArrangement` is false (`cmds tile` with workspaces: automatic grid again).
    func setTiling(_ mode: TileMode, active: String? = nil, keepArrangement: Bool = true) throws {
        if case .selected(let ids) = mode {
            for id in ids where workspace(id: id) == nil { throw RPCError.notFound("workspace not found: \(id)") }
        }
        var mode = mode
        if case .selected(let ids) = mode {
            var unique: [String] = []
            for id in ids where !unique.contains(id) { unique.append(id) }
            mode = unique.count >= 2 ? .selected(unique) : .off
            if unique.count >= 2 { lastTileSelection = unique }
        }
        let arrangement: TileArrangement? = {
            guard keepArrangement, case .selected(let ids) = mode, let tileArrangement else { return nil }
            return tileArrangement.reconciled(with: ids)
        }()
        tileMode = mode
        tileArrangement = arrangement
        if !isTiling { tileZoomedWorkspaceID = nil }
        let tiles = tiledWorkspaceIDs
        if let zoomed = tileZoomedWorkspaceID, !tiles.contains(zoomed) { tileZoomedWorkspaceID = nil }
        let target: String?
        if let active, tiles.contains(active) || !isTiling {
            target = active
        } else if let selected = selectedWorkspaceID, tiles.contains(selected) {
            target = selected
        } else {
            target = tiles.first ?? selectedWorkspaceID
        }
        if let target, target != selectedWorkspaceID { try? selectWorkspace(id: target) }
        emit(.workspaces)
        focusedPane?.focus()
    }

    /// ⌃⌘T: tiles every visible workspace, or leaves the tiled view.
    func toggleTileAll() {
        try? setTiling(isTiling ? .off : .all)
    }

    /// View › Tile Selected Workspaces: the last chosen set again.
    var canRestoreTileSelection: Bool {
        !isTiling && lastTileSelection.filter { workspace(id: $0) != nil }.count >= 2
    }

    func restoreTileSelection() {
        try? setTiling(.selected(lastTileSelection.filter { workspace(id: $0) != nil }))
    }

    /// ⇧⌘↩ while tiled: shows the active tile alone, and back.
    func toggleTileZoom() {
        guard isTiling, let selected = selectedWorkspaceID else { return }
        tileZoomedWorkspaceID = tileZoomedWorkspaceID == nil ? selected : nil
        emit(.workspaces)
        focusedPane?.focus()
    }

    /// The sidebar's rows changed (filter, grouping): with "tile all" the set follows, and the keyboard stays in a tile.
    func tileSourceDidChange() {
        guard tileMode != .off else { return }
        let candidates = tileCandidates
        if candidates.count == 1, let only = candidates.first, only != selectedWorkspaceID {
            // The filter left one workspace: show it (tiling resumes when more match again).
            setSelectedWorkspace(only)
            emit(.workspaces)
            focusedPane?.focus()
        } else if isTiling, let selected = selectedWorkspaceID, !tiledWorkspaceIDs.contains(selected),
           let first = tiledWorkspaceIDs.first {
            setSelectedWorkspace(first)
            emit(.workspaces)
            focusedPane?.focus()
        } else {
            emit(.workspaces)
        }
    }

    /// A workspace was closed: drop it from the chosen set (fewer than two left ends tiling).
    func workspaceDidClose(_ id: String) {
        if tileZoomedWorkspaceID == id { tileZoomedWorkspaceID = nil }
        if case .selected(let ids) = tileMode {
            let remaining = ids.filter { $0 != id }
            let arrangement = tileArrangement?.removing([id])
            tileMode = remaining.count >= 2 ? .selected(remaining) : .off
            if remaining.count >= 2 { tileArrangement = arrangement }
        }
    }

    // MARK: - Arranging by drag and ⌃⇧⌘ + arrow

    /// What the content area shows as rows: the tiles (dragged arrangement, else the automatic grid on screen), or
    /// the selected workspace alone.
    var displayedTileArrangement: TileArrangement? {
        guard isTiling else { return selectedWorkspaceID.map { TileArrangement(rows: [[$0]]) } }
        if let tileArrangement { return tileArrangement }
        let ids = tiledWorkspaceIDs
        let shape = currentTileShape?() ?? []
        return TileArrangement.auto(ids: ids, shape: shape.reduce(0, +) == ids.count ? shape : TileLayout.shape(count: ids.count, aspect: 1.6))
    }

    /// Shows `arrangement` (from now on the grid keeps its rows); `active` gets the keyboard. One workspace left: the
    /// normal view of it.
    func applyTileArrangement(_ arrangement: TileArrangement, active: String?) {
        let ids = arrangement.ids.filter { workspace(id: $0) != nil }
        guard ids.count >= 2 else {
            try? setTiling(.off, active: ids.first ?? active)
            return
        }
        tileZoomedWorkspaceID = nil
        tileMode = .selected(ids)
        tileArrangement = arrangement.removing(arrangement.ids.filter { workspace(id: $0) == nil })
        lastTileSelection = ids
        let target = active.flatMap { ids.contains($0) ? $0 : nil }
            ?? selectedWorkspaceID.flatMap { ids.contains($0) ? $0 : nil } ?? ids[0]
        if target != selectedWorkspaceID { try? selectWorkspace(id: target) }
        emit(.workspaces)
        focusedPane?.focus()
    }

    /// Workspaces (sidebar rows or a tile header) dropped on `zone` of the tile `target` (or of the single workspace
    /// shown). false when the drop would change nothing.
    @discardableResult
    func dropOnTile(_ moving: [String], target: String, zone: TileDropZone) -> Bool {
        guard moving.allSatisfy({ workspace(id: $0) != nil }),
              let result = displayedTileArrangement?.dropping(moving, on: target, zone: zone) else { return false }
        applyTileArrangement(result, active: moving.first)
        return true
    }

    /// A tile dragged back onto the sidebar (or out of the window with ⌥): leaves the tiled view.
    func removeFromTiles(_ id: String) {
        guard isTiling, let arrangement = displayedTileArrangement, arrangement.ids.contains(id) else { return }
        let rest = arrangement.removing([id])
        let active = selectedWorkspaceID == id ? rest.ids.first : selectedWorkspaceID
        applyTileArrangement(rest, active: active)
    }

    var canMoveActiveTile: Bool { isTiling && tileZoomedWorkspaceID == nil }

    /// View › Move Tile Left/Right/Up/Down (⌃⇧⌘ + arrow) for the active tile. Beeps when it cannot move that way.
    func moveActiveTile(_ direction: TileArrangement.Direction) -> Bool {
        guard canMoveActiveTile, let id = selectedWorkspaceID,
              let result = displayedTileArrangement?.moving(id, direction) else { return false }
        applyTileArrangement(result, active: id)
        return true
    }

    // MARK: - Divider positions

    static func tileRatiosKey(_ ids: [String], shape: [Int]) -> String {
        ids.sorted().joined(separator: ",") + "#" + shape.map(String.init).joined(separator: ",")
    }

    func tileRatios(for ids: [String], shape: [Int]) -> TileRatios? {
        tileRatios[Self.tileRatiosKey(ids, shape: shape)].flatMap { $0.fits(shape) ? $0 : nil }
    }

    /// A tile divider was dragged (saved with the session).
    func setTileRatios(_ ratios: TileRatios, for ids: [String], shape: [Int]) {
        tileRatios[Self.tileRatiosKey(ids, shape: shape)] = ratios
        scheduleSave()
    }

    // MARK: - Session

    func saveTiling(into state: inout SessionState, savedWorkspaces: [Workspace]) {
        var index: [String: Int] = [:]
        for (position, workspace) in savedWorkspaces.enumerated() { index[workspace.id] = position }
        switch tileMode {
        case .off:
            break
        case .all:
            state.tiling = .init(all: true, workspaceIndices: nil,
                                 zoomedIndex: tileZoomedWorkspaceID.flatMap { index[$0] })
        case .selected(let ids):
            let indices = ids.compactMap { index[$0] }
            if indices.count >= 2 {
                let rows = tileArrangement.map { $0.rows.map { $0.compactMap { index[$0] } }.filter { !$0.isEmpty } }
                state.tiling = .init(all: false, workspaceIndices: indices,
                                     zoomedIndex: tileZoomedWorkspaceID.flatMap { index[$0] }, rows: rows)
            }
        }
        let layouts = tileRatios.compactMap { key, ratios -> SessionState.TileLayoutState? in
            let parts = key.split(separator: "#", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let ids = parts[0].split(separator: ",").map(String.init)
            let indices = ids.compactMap { index[$0] }
            let shape = parts[1].split(separator: ",").compactMap { Int($0) }
            guard indices.count == ids.count, indices.count >= 2, ratios.fits(shape) else { return nil }
            return .init(workspaceIndices: indices.sorted(), shape: shape, ratios: ratios)
        }
        state.tileLayouts = layouts.isEmpty ? nil
            : Array(layouts.sorted { $0.workspaceIndices.lexicographicallyPrecedes($1.workspaceIndices) }.prefix(32))
    }

    /// `workspaces` are the restored workspaces in the order of `state.workspaces`.
    func restoreTiling(_ state: SessionState, workspaces restored: [Workspace]) {
        func ids(_ indices: [Int]) -> [String] { indices.compactMap { restored[safe: $0]?.id } }
        for layout in state.tileLayouts ?? [] {
            let members = ids(layout.workspaceIndices)
            guard members.count == layout.workspaceIndices.count, layout.ratios.fits(layout.shape) else { continue }
            tileRatios[Self.tileRatiosKey(members, shape: layout.shape)] = layout.ratios
        }
        guard let tiling = state.tiling else { return }
        if tiling.all {
            tileMode = .all
        } else {
            let members = ids(tiling.workspaceIndices ?? [])
            guard members.count >= 2 else { return }
            tileMode = .selected(members)
            lastTileSelection = members
            if let rows = tiling.rows {
                let arrangement = TileArrangement(rows: rows.map(ids))
                // Only when it still holds exactly the set (else the automatic grid).
                if Set(arrangement.ids) == Set(members) { tileArrangement = arrangement }
            }
        }
        let tiles = tiledWorkspaceIDs
        if let selected = selectedWorkspaceID, !tiles.contains(selected), let first = tiles.first {
            setSelectedWorkspace(first)
        }
        tileZoomedWorkspaceID = tiling.zoomedIndex.flatMap { restored[safe: $0]?.id }.flatMap { tiles.contains($0) ? $0 : nil }
    }
}
