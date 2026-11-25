import Foundation

/// Panes whose agent has had no work in progress for some minutes (`cmds idle`, API `agent.idle`): a department that
/// stopped, for whoever hands out the work. An agent counts as idle when it waits for a prompt or asks for input, no
/// subagent runs and no schedule run is typing into its pane; panes without an agent are not listed.
public enum IdlePanes {
    public static let defaultMinutes = 30
    /// A minute to a week.
    public static let minutesRange = 1...7 * 24 * 60

    /// A pane as the app sees it now.
    public struct Candidate: Equatable, Sendable {
        public var pane: String
        public var workspace: String
        public var workspaceTitle: String
        public var agent: AgentKind?
        public var activity: AgentActivity
        public var subagentRunning: Bool
        /// A schedule run or a queued instruction is being typed into the pane.
        public var inputInProgress: Bool
        /// When the agent last showed it was working (`AgentSignals.lastBusyAt`); nil when cmds never saw it work.
        public var lastWorkAt: Date?
        /// Since when cmds has watched the pane (the app's start or the pane's): the idle time of an agent never
        /// seen working counts from here.
        public var watchedSince: Date
        /// Instructions waiting for the pane (`PaneQueue`).
        public var queued: Int

        public init(pane: String, workspace: String, workspaceTitle: String, agent: AgentKind?, activity: AgentActivity,
                    subagentRunning: Bool = false, inputInProgress: Bool = false, lastWorkAt: Date? = nil,
                    watchedSince: Date, queued: Int = 0) {
            self.pane = pane
            self.workspace = workspace
            self.workspaceTitle = workspaceTitle
            self.agent = agent
            self.activity = activity
            self.subagentRunning = subagentRunning
            self.inputInProgress = inputInProgress
            self.lastWorkAt = lastWorkAt
            self.watchedSince = watchedSince
            self.queued = queued
        }
    }

    /// The candidates idle for `minutes` or longer at `now`, longest first.
    public static func report(_ candidates: [Candidate], minutes: Int, now: Date) -> IdlePaneReport {
        let formatter = ISO8601DateFormatter()
        let panes = candidates.compactMap { c -> IdlePaneReport.Pane? in
            guard c.activity == .idle || c.activity == .needsInput, !c.subagentRunning, !c.inputInProgress else { return nil }
            let since = max(c.lastWorkAt ?? .distantPast, c.watchedSince)
            let idle = Int(now.timeIntervalSince(since))
            guard idle >= minutes * 60 else { return nil }
            return IdlePaneReport.Pane(pane: c.pane, workspace: c.workspace, workspaceTitle: c.workspaceTitle,
                                       agent: c.agent?.rawValue, state: c.activity.rawValue, idleSeconds: idle,
                                       since: formatter.string(from: since), sinceIsWatchStart: c.lastWorkAt == nil,
                                       queued: c.queued)
        }
        return IdlePaneReport(minutes: minutes, panes: panes.sorted { ($0.idleSeconds, $1.pane) > ($1.idleSeconds, $0.pane) })
    }
}

/// Result of `agent.idle`.
public struct IdlePaneReport: Codable, Equatable, Sendable {
    public struct Pane: Codable, Equatable, Sendable {
        public var pane: String
        public var workspace: String
        public var workspaceTitle: String
        /// "claude", "codex", …; nil when cmds cannot tell.
        public var agent: String?
        /// "idle" (waits for a prompt) or "needsInput" (asks for input or permission).
        public var state: String
        public var idleSeconds: Int
        /// ISO 8601: since when nothing has been in progress.
        public var since: String
        /// cmds never saw the agent work: `since` is when it started watching the pane, the agent may have been idle
        /// for longer.
        public var sinceIsWatchStart: Bool
        /// Instructions waiting for the pane.
        public var queued: Int

        public init(pane: String, workspace: String, workspaceTitle: String, agent: String?, state: String,
                    idleSeconds: Int, since: String, sinceIsWatchStart: Bool, queued: Int) {
            self.pane = pane
            self.workspace = workspace
            self.workspaceTitle = workspaceTitle
            self.agent = agent
            self.state = state
            self.idleSeconds = idleSeconds
            self.since = since
            self.sinceIsWatchStart = sinceIsWatchStart
            self.queued = queued
        }
    }

    /// The threshold asked for.
    public var minutes: Int
    public var panes: [Pane]

    public init(minutes: Int, panes: [Pane]) {
        self.minutes = minutes
        self.panes = panes
    }
}
