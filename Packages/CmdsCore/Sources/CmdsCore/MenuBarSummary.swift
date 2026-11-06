import Foundation

/// What the menu bar item shows (#95): how many workspaces need the user and how many work, as coloured badges.
public struct MenuBarSummary: Equatable, Sendable {
    /// One workspace as the menu bar sees it.
    public struct Entry: Equatable, Sendable {
        public var id: String
        public var title: String
        /// Orange in the sidebar: the agent needs input, or a notification is unseen.
        public var needsUser: Bool
        /// The agent works and nothing waits for the user.
        public var working: Bool

        public init(id: String, title: String, needsUser: Bool, working: Bool) {
            self.id = id
            self.title = title
            self.needsUser = needsUser
            self.working = working
        }
    }

    /// Workspaces that need the user, in sidebar order.
    public let needingUser: [Entry]
    /// Workspaces whose agent works, in sidebar order.
    public let working: [Entry]

    public init(_ entries: [Entry]) {
        needingUser = entries.filter(\.needsUser)
        working = entries.filter { $0.working && !$0.needsUser }
    }

    /// Nothing needs the user and nothing works: the item shows only its icon.
    public var isQuiet: Bool { needingUser.isEmpty && working.isEmpty }
}
