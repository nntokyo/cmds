import Foundation

/// What the assistant knows when it plans an answer (#243): the workspaces as the menu bar sees them
/// (`AgentOverview` in the app builds it), with the panes a reply could go to. A plain value, so the planner and the
/// status text are unit-tested without the app.
public struct AssistantWorld: Equatable, Sendable {
    public struct Pane: Equatable, Sendable {
        public var id: String
        public var title: String
        /// An SSH session: text typed there runs on a server.
        public var isSSH: Bool
        /// The agent running in it ("Claude"), if any.
        public var agent: String?
        /// It waits for the user (an unanswered call, or its agent asks).
        public var waiting: Bool
        /// The numbered choice the agent shows at the bottom of its screen.
        public var prompt: AgentPromptOptions?
        /// The last lines of its screen above the choice (what a permission prompt asks about), for the safety check.
        public var promptContext: [String]

        public init(id: String, title: String, isSSH: Bool = false, agent: String? = nil, waiting: Bool = false,
                    prompt: AgentPromptOptions? = nil, promptContext: [String] = []) {
            self.id = id
            self.title = title
            self.isSSH = isSSH
            self.agent = agent
            self.waiting = waiting
            self.prompt = prompt
            self.promptContext = promptContext
        }
    }

    public struct Workspace: Equatable, Sendable {
        public var id: String
        public var title: String
        /// nil: no agent ran here in this run.
        public var state: MenuBarSummary.State?
        public var agent: String?
        /// What the agent does (its terminal title).
        public var topic: String?
        /// The latest notification (what it asks when it needs the user).
        public var notification: String?
        /// Since when it waits for the user.
        public var waitingSince: Date?
        /// Its local folder.
        public var directory: String?
        /// Its terminal panes, in reading order.
        public var panes: [Pane]

        public init(id: String, title: String, state: MenuBarSummary.State? = nil, agent: String? = nil,
                    topic: String? = nil, notification: String? = nil, waitingSince: Date? = nil,
                    directory: String? = nil, panes: [Pane] = []) {
            self.id = id
            self.title = title
            self.state = state
            self.agent = agent
            self.topic = topic
            self.notification = notification
            self.waitingSince = waitingSince
            self.directory = directory
            self.panes = panes
        }
    }

    /// In sidebar order.
    public var workspaces: [Workspace]
    public var now: Date

    public init(workspaces: [Workspace], now: Date = Date()) {
        self.workspaces = workspaces
        self.now = now
    }

    /// Workspaces with an agent, those that need the user first (the menu bar's order).
    public var withAgents: [Workspace] {
        let summary = MenuBarSummary(workspaces.map {
            MenuBarSummary.Entry(id: $0.id, needsUser: $0.state == .needsUser, activity: $0.state)
        })
        return summary.entries.compactMap { entry in workspaces.first { $0.id == entry.id } }
    }

    public func workspace(id: String) -> Workspace? { workspaces.first { $0.id == id } }

    // MARK: Finding a workspace

    public enum Match: Equatable, Sendable {
        case found(Workspace)
        /// Several fit: ask which.
        case ambiguous([Workspace])
        case notFound
    }

    /// The workspace `name` means: its title (exact, then the start, then a part of it, case, width and kana folded),
    /// its number in the sidebar ("2", "workspace 2"), or the agent running in it when only one runs it ("Codex").
    /// No name: the one workspace that needs the user, if exactly one does.
    public func find(_ name: String?) -> Match {
        guard let name, !AssistantText.key(name).isEmpty else {
            let waiting = workspaces.filter { $0.state == .needsUser }
            switch waiting.count {
            case 1: return .found(waiting[0])
            case 0: return .notFound
            default: return .ambiguous(waiting)
            }
        }
        if let number = AssistantText.number(name), workspaces.indices.contains(number - 1),
           !workspaces.contains(where: { AssistantText.key($0.title) == AssistantText.key(name) }) {
            return .found(workspaces[number - 1])
        }
        let key = AssistantText.key(name)
        let titled = workspaces.map { (workspace: $0, key: AssistantText.key($0.title)) }
        for matches in [
            titled.filter { $0.key == key },
            titled.filter { $0.key.hasPrefix(key) },
            titled.filter { $0.key.contains(key) || (!$0.key.isEmpty && key.contains($0.key) && $0.key.count >= 3) },
            workspaces.filter { $0.agent.map(AssistantText.key) == key }.map { (workspace: $0, key: key) },
        ] where !matches.isEmpty {
            return matches.count == 1 ? .found(matches[0].workspace) : .ambiguous(matches.map(\.workspace))
        }
        return .notFound
    }

    public enum PaneMatch: Equatable, Sendable {
        case found(Pane)
        case ambiguous([Pane])
        case none
    }

    /// The pane an action on `workspace` goes to, only when it is clear: the one pane that waits; else the one pane
    /// with an agent; else the only terminal pane. Two waiting panes, or two agents and none waiting, are ambiguous.
    public static func targetPane(in workspace: Workspace) -> PaneMatch {
        for candidates in [workspace.panes.filter(\.waiting), workspace.panes.filter { $0.agent != nil }, workspace.panes]
        where !candidates.isEmpty {
            return candidates.count == 1 ? .found(candidates[0]) : .ambiguous(candidates)
        }
        return .none
    }
}
