import AppKit
import CmdsCore

extension AgentOverview {
    /// What the assistant knows (#243): every workspace as the menu bar shows it, with its terminal panes, which of
    /// them waits, and the numbered choice its agent shows (read from the screen, as the reply panel does).
    static func assistantWorld(_ controller: AppController, now: Date = Date()) -> AssistantWorld {
        let states = Dictionary(summary(controller).entries.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        return AssistantWorld(workspaces: controller.workspaces.map { workspace in
            let state = states[workspace.id] ?? nil
            let panes = workspace.orderedPanes.filter { $0.terminal != nil }.map { pane -> AssistantWorld.Pane in
                let screen = (try? controller.readText(paneID: pane.id)) ?? ""
                let lines = screen.components(separatedBy: "\n")
                let prompt = AgentPromptOptions.parse(lines: lines)
                return AssistantWorld.Pane(
                    id: pane.id, title: pane.title, isSSH: pane.ssh != nil, agent: pane.agentUsage?.agent.displayName,
                    waiting: pane.attention || pane.agentActivity == .needsInput, prompt: prompt,
                    promptContext: prompt == nil ? [] : Array(lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(16)))
            }
            return AssistantWorld.Workspace(
                id: workspace.id, title: workspace.displayTitle, state: state,
                agent: workspace.primaryAgent?.usage.agent.displayName, topic: workspace.agentTopic,
                notification: workspace.notificationText, waitingSince: waitingSince(workspace),
                directory: workspace.localWorkingDirectory, panes: panes)
        }, now: now)
    }
}
