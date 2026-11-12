import AppKit
import CmdsCore
import os

private let assistantLog = Logger(subsystem: "tokyo.n-n.cmds", category: "assistant")

/// Follow-through (#243): sessions the assistant gave a task to, announced when their agent is done or needs the
/// user (Settings › Assistant › Report on tasks I gave).
@available(macOS 26.0, *)
extension AssistantController {
    /// A workspace or pane changed: the recognition vocabulary follows the titles, and the sessions given a task are
    /// checked for their agent's state (the state the app already tracks; no screen is read).
    func stateChanged(_ change: StateChange) {
        // The waiting orb turns orange when a workspace needs the user.
        schedulePresenceUpdate()
        switch change {
        case .workspaces, .workspace: updateVocabulary()
        case .pane, .notification: break
        }
        guard !taskWatch.entries.isEmpty else { return }
        for entry in taskWatch.entries {
            guard let pane = controller.pane(id: entry.paneID), pane.workspaceID == entry.workspaceID,
                  let workspace = controller.workspace(id: entry.workspaceID) else {
                taskWatch.forget(paneID: entry.paneID)
                continue
            }
            let question = workspace.notificationPaneID == pane.id ? workspace.notificationText : nil
            if let event = taskWatch.update(paneID: pane.id, activity: pane.agentActivity, question: question, now: Date()) {
                announce(event)
            }
        }
    }

    /// One sentence about a session given a task, when the setting is on: now if the assistant is free, else after.
    private func announce(_ event: AssistantTaskWatch.Event) {
        guard settings.assistantReportTasks, isOn else { return }
        let strings = AssistantStrings.localized
        let text: String
        switch event {
        case .finished(let agent, let id):
            text = strings(.taskDone(agent: agent, workspace: controller.workspace(id: id)?.displayTitle ?? agent))
        case .needsInput(let agent, let id, let question):
            let title = controller.workspace(id: id)?.displayTitle ?? agent
            text = strings(question.map { .taskAsks(agent: agent, workspace: title, question: $0) } ?? .taskNeedsYou(agent: agent, workspace: title))
        }
        assistantLog.info("assistant follow-through on a task it gave")
        announcements.append(text)
        tick()
    }
}
