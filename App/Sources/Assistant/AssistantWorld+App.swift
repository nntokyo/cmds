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
                let agent = pane.agentUsage?.agent.displayName
                return AssistantWorld.Pane(
                    id: pane.id, title: pane.title, isSSH: pane.ssh != nil, agent: agent,
                    waiting: pane.attention || pane.agentActivity == .needsInput, prompt: prompt,
                    promptContext: prompt == nil ? [] : Array(lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(AssistantTuning.promptContextLines)),
                    shell: agent == nil ? shell(of: pane, now: now) : nil)
            }
            return AssistantWorld.Workspace(
                id: workspace.id, title: workspace.displayTitle, state: state,
                agent: workspace.primaryAgent?.usage.agent.displayName, topic: workspace.agentTopic,
                notification: workspace.notificationText, waitingSince: waitingSince(workspace),
                directory: workspace.localWorkingDirectory, panes: panes)
        }, now: now)
    }

    /// What a local pane's shell runs, from its foreground process (as the typing rules read it): idle at the shell,
    /// or the program's name; nil for an SSH pane, an agent or a process that cannot be read.
    private static func shell(of pane: Pane, now: Date) -> AssistantWorld.Shell? {
        guard let terminal = pane.terminal else { return nil }
        let (foreground, group) = pane.inputForeground(terminal, now: now)
        switch foreground {
        case .shell: return .idle
        case .other: return group.flatMap(PaneProcessProbe.name(of:)).map { .running($0) }
        case .agent, .unknown: return nil
        }
    }
}
