import Foundation

/// What the menu bar item shows (#95): the workspace that needs the user, else how many work.
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

    /// Longest workspace title in the menu bar; longer ones end in "…".
    public static let maxTitleLength = 20

    /// Workspaces that need the user, in sidebar order.
    public let needingUser: [Entry]
    /// Workspaces whose agent works, in sidebar order.
    public let working: [Entry]

    public init(_ entries: [Entry]) {
        needingUser = entries.filter(\.needsUser)
        working = entries.filter { $0.working && !$0.needsUser }
    }

    /// The text after the icon: `● api-server +1`, `◐3`, or "" when nothing needs the user or works.
    public var title: String {
        if let first = needingUser.first {
            let more = needingUser.count > 1 ? " +\(needingUser.count - 1)" : ""
            return "● \(Self.shortened(first.title))\(more)"
        }
        return working.isEmpty ? "" : "◐\(working.count)"
    }

    static func shortened(_ title: String) -> String {
        title.count > maxTitleLength ? String(title.prefix(maxTitleLength - 1)) + "…" : title
    }
}
