import AppKit
import CmdsCore

/// Moving and swapping panes (#218; docs/guide/workspaces-and-panes.md "Moving panes"): by drag, Pane menu, `pane.move`
/// and `pane.swap`. A moved pane is the same `Pane`: its id, terminal (processes, scrollback), web view, agent state,
/// attention and opener stay; only its container is re-parented when the views are rebuilt. Zoom is cleared in the
/// workspaces involved. An emptied workspace closes as when its last pane is closed.
extension AppController {
    /// Moves `paneID` beside the pane `beside` (on `side`), or into `workspaceID` beside its focused pane. With `focus`
    /// the moved pane takes the keyboard and its workspace is shown; else the selection stays (the destination's
    /// focused pane too). Returns the destination workspace's id.
    @discardableResult
    func movePane(paneID: String, toWorkspace workspaceID: String? = nil, beside besideID: String? = nil,
                  side: PaneSide = .right, focus: Bool = true) throws -> String {
        let pane = try resolvePane(paneID)
        guard let source = workspace(id: pane.workspaceID) else { throw RPCError.notFound("pane not found: \(paneID)") }
        let destination: Workspace
        let target: Pane
        if let besideID {
            target = try resolvePane(besideID)
            guard let found = workspace(id: target.workspaceID) else { throw RPCError.notFound("pane not found: \(besideID)") }
            if let workspaceID, workspaceID != found.id {
                throw RPCError.invalidParams("pane \(target.id) is not in workspace \(workspaceID)")
            }
            destination = found
        } else {
            destination = try resolveWorkspace(workspaceID ?? source.id)
            guard destination !== source else {
                throw RPCError.invalidParams("pane \(pane.id) is already in workspace \(source.id) (give beside to move it there)")
            }
            guard let focused = destination.focusedPane ?? destination.orderedPanes.first else {
                throw RPCError.notFound("workspace \(destination.id) has no pane")
            }
            target = focused
        }
        guard target !== pane else { throw RPCError.invalidParams("a pane cannot be moved beside itself") }

        let sourceWasSelected = source.id == selectedWorkspaceID
        let wasFocused = source.focusedPaneID == pane.id
        detach(pane, from: source)
        guard let leaf = destination.root?.leaf(for: target.id) else { throw RPCError.notFound("pane not found: \(target.id)") }
        leaf.insert(pane.id, side: side)
        attach(pane, to: destination, from: source)
        if focus || destination === source && wasFocused {
            applyFocus(pane, in: destination)
        }
        finishMove(pane, from: source, to: destination, focus: focus, sourceWasSelected: sourceWasSelected)
        return destination.id
    }

    /// Moves `paneID` into a new workspace right after its own (Pane › Move to New Workspace, a pane dropped outside
    /// the window, `pane.move` with `newWorkspace`). The only pane of a workspace stays where it is. Returns the
    /// destination workspace's id.
    @discardableResult
    func movePaneToNewWorkspace(paneID: String, focus: Bool = true) throws -> String {
        let pane = try resolvePane(paneID)
        guard let source = workspace(id: pane.workspaceID), let index = workspaces.firstIndex(where: { $0 === source }) else {
            throw RPCError.notFound("pane not found: \(paneID)")
        }
        guard source.panes.count > 1 else { return source.id }
        let sourceWasSelected = source.id == selectedWorkspaceID
        let destination = makeWorkspace()
        detach(pane, from: source)
        destination.root = SplitNode(paneID: pane.id)
        attach(pane, to: destination, from: source)
        destination.focusedPaneID = pane.id
        if pane.kind == .terminal {
            updateLocation(of: destination, from: pane)
        } else {
            let local = pane.files?.isRemote == false ? pane.files?.folder : nil
            let directory = local ?? source.localWorkingDirectory ?? NSHomeDirectory()
            destination.workingDirectory = directory
            destination.gitBranch = GitInfo.branch(at: directory)
        }
        insertWorkspace(destination, at: index + 1)
        // A chosen tiling set takes the new workspace in, so the pane stays on screen.
        if case .selected(let ids) = tileMode {
            let arrangement = tileArrangement
            tileMode = .selected(ids + [destination.id])
            tileArrangement = arrangement?.reconciled(with: ids + [destination.id])
        }
        if focus { applyFocus(pane, in: destination) }
        finishMove(pane, from: source, to: destination, focus: focus, sourceWasSelected: sourceWasSelected)
        return destination.id
    }

    /// Exchanges the places of two panes, in one workspace or across two (Pane › Swap with Pane…, a pane dropped on
    /// another one's centre, `pane.swap`). Each workspace keeps the place of its focused pane focused; the pane with
    /// the keyboard keeps it when it lands in a workspace on screen.
    func swapPanes(a aID: String, b bID: String) throws {
        let a = try resolvePane(aID)
        let b = try resolvePane(bID)
        guard a !== b else { throw RPCError.invalidParams("cannot swap a pane with itself") }
        guard let first = workspace(id: a.workspaceID), let second = workspace(id: b.workspaceID),
              let firstRoot = first.root, let secondRoot = second.root,
              SplitNode.swapping(a.id, in: firstRoot, with: b.id, in: secondRoot) else {
            throw RPCError.notFound("pane not found")
        }
        first.zoomedPaneID = nil
        second.zoomedPaneID = nil
        guard first !== second else {
            emit(.workspace(id: first.id))
            if first.id == selectedWorkspaceID { focusSelectedPaneView() }
            return
        }
        let keyboard = focusedPane
        let firstFocused = first.focusedPaneID
        let secondFocused = second.focusedPaneID
        let firstNote = first.notificationPaneID == a.id ? note(of: first) : nil
        let secondNote = second.notificationPaneID == b.id ? note(of: second) : nil
        first.panes[a.id] = nil
        second.panes[b.id] = nil
        first.panes[b.id] = b
        second.panes[a.id] = a
        setWorkspace(of: a, to: second)
        setWorkspace(of: b, to: first)
        if firstFocused == a.id { first.focusedPaneID = b.id }
        if secondFocused == b.id { second.focusedPaneID = a.id }
        if let firstNote { first.clearNotificationText(); restore(firstNote, in: second) }
        if let secondNote { second.clearNotificationText(); restore(secondNote, in: first) }
        for workspace in [first, second] {
            if let focused = workspace.focusedPane, focused.kind == .terminal { updateLocation(of: workspace, from: focused) }
        }
        if let keyboard, keyboard === a || keyboard === b,
           let landed = workspace(id: keyboard.workspaceID), landed.id != selectedWorkspaceID,
           isTiling, tiledWorkspaceIDs.contains(landed.id) {
            setSelectedWorkspace(landed.id)
            applyFocus(keyboard, in: landed)
            emit(.workspaces)
            keyboard.focus()
            return
        }
        emit(.workspace(id: first.id))
        emit(.workspace(id: second.id))
        if first.id == selectedWorkspaceID || second.id == selectedWorkspaceID { focusSelectedPaneView() }
    }

    // MARK: - Steps

    /// Takes `pane` out of `source`'s tree; a source that keeps panes focuses the one that followed it in reading order.
    private func detach(_ pane: Pane, from source: Workspace) {
        let order = source.orderedPanes.map(\.id)
        source.panes[pane.id] = nil
        source.root = source.root.flatMap { SplitNode.removing(pane.id, from: $0) }
        source.zoomedPaneID = nil
        guard source.root != nil, source.focusedPaneID == pane.id else { return }
        let index = order.firstIndex(of: pane.id) ?? 0
        let remaining = source.orderedPanes
        if let next = remaining[safe: min(index, remaining.count - 1)] { applyFocus(next, in: source) }
    }

    /// Puts `pane` (already in `destination`'s tree) into `destination`; its sidebar notification text goes along.
    private func attach(_ pane: Pane, to destination: Workspace, from source: Workspace) {
        destination.panes[pane.id] = pane
        destination.zoomedPaneID = nil
        guard destination !== source else { return }
        setWorkspace(of: pane, to: destination)
        if source.notificationPaneID == pane.id, let note = note(of: source) {
            source.clearNotificationText()
            restore(note, in: destination)
        }
    }

    private func setWorkspace(of pane: Pane, to workspace: Workspace) {
        pane.workspaceID = workspace.id
        pane.ssh?.updateAPIScope(RemoteScope(paneID: pane.id, workspaceID: workspace.id))
    }

    private typealias Note = (text: String, paneID: String?, date: Date?)

    private func note(of workspace: Workspace) -> Note? {
        workspace.notificationText.map { ($0, workspace.notificationPaneID, workspace.notificationDate) }
    }

    private func restore(_ note: Note, in workspace: Workspace) {
        workspace.notificationText = note.text
        workspace.notificationPaneID = note.paneID
        workspace.notificationDate = note.date
    }

    /// Closes an emptied source (the same path as closing its last pane), then selects, emits and focuses.
    private func finishMove(_ pane: Pane, from source: Workspace, to destination: Workspace, focus: Bool,
                            sourceWasSelected: Bool) {
        if source.root == nil {
            try? closeWorkspace(id: source.id)
        }
        let selectionChanges = focus && destination.id != selectedWorkspaceID
        if selectionChanges { setSelectedWorkspace(destination.id) }
        if source.root != nil, source !== destination { emit(.workspace(id: source.id)) }
        emit(selectionChanges || destination !== source ? .workspaces : .workspace(id: destination.id))
        if source !== destination { emit(.workspace(id: destination.id)) }
        if focus {
            pane.focus()
        } else if sourceWasSelected {
            focusSelectedPaneView()
        }
    }
}
