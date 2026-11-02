import Foundation
import CmdsCore

/// Schedule tags of panes (`Pane.scheduleTag`): how a `sendText` schedule (and a `continueSession` one,
/// `ContinueSession.paneTag`) finds its pane again after a relaunch, when pane ids are reassigned. Saved in
/// `session.json` (`paneTags`), given only when a schedule names a pane.
extension AppController {
    /// Every pane as a `sendText` target could match it (`ScheduleTarget.resolve`).
    func scheduleTargetCandidates() -> [ScheduleTarget.Candidate] {
        workspaces.flatMap { workspace in
            workspace.orderedPanes.map { pane in
                ScheduleTarget.Candidate(paneID: pane.id, workspaceID: workspace.id, workspaceTitle: workspace.title,
                                         tag: pane.scheduleTag, isLocalTerminal: Self.isScheduleTarget(pane))
            }
        }
    }

    /// The pane `target` names now, if exactly one does.
    func resolveScheduleTarget(_ target: PaneTarget) -> ScheduleTarget.Resolution {
        ScheduleTarget.resolve(target, in: scheduleTargetCandidates())
    }

    /// A local terminal pane that is not closing: the only kind a schedule types into by target.
    static func isScheduleTarget(_ pane: Pane) -> Bool {
        pane.kind == .terminal && pane.ssh == nil && !pane.isClosing
    }

    /// The pane's tag, given now if it has none (unique among all panes); saved with the session.
    func scheduleTag(for pane: Pane) -> String {
        if let tag = pane.scheduleTag { return tag }
        let taken = Set(workspaces.flatMap(\.orderedPanes).compactMap(\.scheduleTag))
        let tag = ScheduleIDs.make(prefix: ScheduleIDs.paneTagPrefix, taken: taken)
        pane.scheduleTag = tag
        scheduleSave()
        return tag
    }

    /// Restoring a workspace (launch, `state.import`): its panes get their saved tags, unless another pane already has
    /// one (a tag never names two panes) or the pane is not a local terminal.
    func restoreScheduleTags(_ saved: [SessionState.PaneTag]?, in workspace: Workspace) {
        guard let saved, !saved.isEmpty, let root = workspace.root else { return }
        let ids = root.paneIDs
        let entries = saved.compactMap { entry -> (Pane, String)? in
            guard let pane = ids[safe: entry.paneIndex].flatMap({ workspace.panes[$0] }), Self.isScheduleTarget(pane) else {
                return nil
            }
            return (pane, entry.tag)
        }
        let taken = Set(workspaces.filter { $0 !== workspace }.flatMap(\.orderedPanes).compactMap(\.scheduleTag))
        let kept = ScheduleTarget.uniqueTags(entries.map(\.1), taken: taken)
        for ((pane, _), tag) in zip(entries, kept) { pane.scheduleTag = tag }
    }
}
