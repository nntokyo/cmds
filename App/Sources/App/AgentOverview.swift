import AppKit
import CmdsCore

/// The agents at a glance, as the menu bar item (#95) and the widget (#96) show them: each workspace's state, what its
/// agent does or asks, how long it has waited, and why the red warning dot shows. One place, so the two never differ.
@MainActor
enum AgentOverview {
    /// Every workspace with its state (needs you first, then working, done, idle, stopped).
    static func summary(_ controller: AppController) -> MenuBarSummary {
        MenuBarSummary(controller.workspaces.map { workspace in
            MenuBarSummary.Entry(id: workspace.id, needsUser: AgentActivityStyle.needsUser(workspace),
                                 activity: state(AgentActivityStyle.badge(for: workspace)))
        })
    }

    static func state(_ badge: AgentActivityStyle.Badge?) -> MenuBarSummary.State? {
        switch badge {
        case .working: return .working
        case .needsInput: return .needsUser
        case .done: return .done
        case .idle: return .idle
        case .stopped: return .stopped
        case nil: return nil
        }
    }

    /// The state in words, as the sidebar badge says it (the menu bar's reply panel, #213).
    static func stateTitle(_ state: MenuBarSummary.State) -> String {
        let badge: AgentActivityStyle.Badge
        switch state {
        case .needsUser: badge = .needsInput
        case .working: badge = .working
        case .done: badge = .done
        case .idle: badge = .idle
        case .stopped: badge = .stopped
        }
        return badge.text
    }

    /// When a workspace that needs the user started to wait: its oldest unanswered call.
    static func waitingSince(_ workspace: Workspace) -> Date? {
        workspace.panes.values.filter(\.attention).compactMap(\.attentionDate).min()
    }

    /// The first of `panes` that waits for the user: an unanswered call or an agent asking (#213). The menu bar's
    /// reply panel passes a workspace's terminal panes, "Open in cmds" all of its panes.
    static func waitingPane(in panes: [Pane]) -> Pane? {
        panes.first { $0.attention || $0.agentActivity == .needsInput }
    }

    /// The agent, what it does (or, when it needs the user, what it asks) and its running subagents:
    /// `Claude · Add login validation · ⧉ 2`. `age` puts how long it has waited first.
    static func detail(_ workspace: Workspace, state: MenuBarSummary.State, age: Bool) -> String {
        var parts: [String] = []
        if age, state == .needsUser, let since = waitingSince(workspace) {
            parts.append(AgentFormat.age(since, strings: .localized))
        }
        if let agent = workspace.primaryAgent?.usage.agent { parts.append(agent.displayName) }
        let doing = state == .needsUser ? workspace.notificationText ?? workspace.agentTopic : workspace.agentTopic
        if let doing, !doing.isEmpty { parts.append(doing) }
        let subagents = workspace.runningSubagentCount
        if subagents > 0 { parts.append("⧉ \(subagents)") }
        return parts.joined(separator: " · ")
    }

    /// An account limit at 95 % or more, or critical memory pressure: what the red dot warns of; nil when nothing does.
    /// The agents' context windows for the menu's ctx rings: one per agent pane whose share is known, fullest first.
    static func contexts(_ controller: AppController) -> [MenuBarDashboardView.Context] {
        controller.workspaces.flatMap { workspace in
            workspace.agentPanes.compactMap { pane -> MenuBarDashboardView.Context? in
                guard let usage = pane.agentUsage, let percent = usage.contextUsedPercent else { return nil }
                return .init(workspace: workspace.displayTitle, agent: usage.agent.displayName, percent: percent,
                             stale: usage.stale == true)
            }
        }
        .sorted { $0.percent > $1.percent }
    }

    static func warning(_ controller: AppController) -> String? {
        var reasons: [String] = []
        for limits in controller.activeAgentLimits() {
            for limit in limits.ordered where UsageLevel(percent: limit.usedPercent) == .critical {
                reasons.append("\(limits.agent.displayName) \(AgentFormat.limitLabel(limit, strings: .localized)) \(AgentFormat.percent(limit.usedPercent))")
            }
        }
        if controller.systemSample?.stats.pressure == .critical {
            reasons.append(String(localized: "Memory pressure critical", comment: "menu bar item tooltip: why the red dot shows"))
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: ", ")
    }
}
