import Foundation

/// What the menu bar item shows (#95): the workspaces where an agent ran, each with one state, in menu order, and how
/// many need the user and how many work (the status bar badges).
public struct MenuBarSummary: Equatable, Sendable {
    /// A workspace's state in the menu bar, in menu order.
    public enum State: Int, Comparable, Sendable, CaseIterable {
        /// Orange in the sidebar: the agent needs input, or a notification is unseen.
        case needsUser
        case working
        case done
        case idle
        case stopped

        public static func < (lhs: State, rhs: State) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One workspace as the menu bar sees it.
    public struct Entry: Equatable, Sendable {
        public var id: String
        /// nil: no agent ran here in this run (not listed).
        public var state: State?

        /// `needsUser` wins over what the agent is doing (`activity`, the sidebar badge).
        public init(id: String, needsUser: Bool, activity: State?) {
            self.id = id
            state = needsUser ? .needsUser : activity
        }
    }

    /// Workspaces with an agent, those that need the user first, then working, done, idle, stopped; sidebar order
    /// within each.
    public let entries: [Entry]

    public init(_ entries: [Entry]) {
        self.entries = entries.enumerated()
            .compactMap { index, entry in entry.state.map { (index, $0, entry) } }
            .sorted { ($0.1, $0.0) < ($1.1, $1.0) }
            .map(\.2)
    }

    public var needingUserCount: Int { entries.count { $0.state == .needsUser } }
    public var workingCount: Int { entries.count { $0.state == .working } }
}
