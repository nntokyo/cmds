import AppKit
import CmdsCore
import os

private let assistantLog = Logger(subsystem: "tokyo.n-n.cmds", category: "assistant")

/// Actions (#243): what a confirmed card does, through the app's own paths.
@available(macOS 26.0, *)
extension AssistantController {
    /// Carries out a confirmed action through the app's own paths (as the menu bar's reply panel does). The target
    /// pane is checked again: it must still exist in the same workspace.
    func run(_ action: AssistantAction) {
        let strings = AssistantStrings.localized
        pendingShownAt = nil
        // One card for several sessions: each goes to its own pane, checked again one by one.
        let actions = action.all
        if actions.count > 1 {
            let failed = actions.filter { !send($0) }.map(\.workspaceTitle)
            var lines: [AssistantLine] = []
            if failed.count < actions.count { lines.append(.sentMany(count: actions.count - failed.count)) }
            if !failed.isEmpty { lines.append(.failedIn(failed)) }
            return say(strings.join(lines))
        }
        switch action.kind {
        case .reply, .choose:
            say(send(action) ? strings(.sent(workspace: action.workspaceTitle)) : strings(.failed))
        case .startAgent(let kind, let directory, let task):
            // A new workspace in the folder running the agent, its task as the first prompt (one quoted argument).
            // In a folder that is already a workspace's title, it is numbered (`api-2`): "api" still means the original.
            let path = (directory as NSString).expandingTildeInPath
            let base = path == NSHomeDirectory() ? "~" : (path as NSString).lastPathComponent
            let title = AssistantWorld.uniqueTitle(base, taken: controller.workspaces.map(\.displayTitle))
            let info = controller.createWorkspace(title: title, cwd: path, command: action.text, select: false)
            recent = (info.id, Date())
            if !queued.isEmpty { createdForQueue.insert(info.id) }
            if task != nil, let pane = controller.workspace(id: info.id)?.orderedPanes.first {
                taskWatch.watch(paneID: pane.id, workspaceID: info.id, agent: kind.displayName, current: .none, now: Date())
            }
            say(strings(.started(agent: kind.displayName, place: title ?? action.workspaceTitle)))
        }
    }

    /// Types a reply (then Return) or an option's digit into the action's pane, if it is still in the same workspace.
    private func send(_ action: AssistantAction) -> Bool {
        assistantLog.info("assistant runs a confirmed action in \(action.workspaceID ?? "new", privacy: .public)/\(action.paneID ?? "-", privacy: .public)")
        guard let paneID = action.paneID, let pane = controller.pane(id: paneID), pane.workspaceID == action.workspaceID,
              pane.terminal != nil else { return false }
        do {
            switch action.kind {
            case .choose:
                try controller.typeText(paneID: paneID, text: action.text)
            case .reply:
                try controller.sendText(paneID: paneID, text: action.text)
                DispatchQueue.main.asyncAfter(deadline: .now() + ScheduleRunTiming.enterDelay) { [controller] in
                    try? controller.typeText(paneID: paneID, text: "\r")
                }
                // An instruction to an agent: say when it is done with it.
                if let agent = pane.agentUsage?.agent.displayName {
                    taskWatch.watch(paneID: paneID, workspaceID: pane.workspaceID, agent: agent, current: pane.agentActivity, now: Date())
                }
            case .startAgent:
                return false
            }
            return true
        } catch {
            return false
        }
    }
}
