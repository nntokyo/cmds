import Foundation

/// Follow-through on the tasks the assistant gave (#243): for a session it started or sent an instruction to, it says
/// in one sentence when the agent has finished its turn (「api の Claude が完了しました」) or starts waiting for the user
/// (「api の Claude が確認を求めています: …」). Fed with the pane's agent state as the app already tracks it (hooks,
/// title); nothing reads the screen. Other sessions are never announced (general announcements stay off).
public struct AssistantTaskWatch: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var paneID: String
        public var workspaceID: String
        /// The agent's name ("Claude").
        public var agent: String
        public var since: Date
        /// The agent was seen working on it (only then does idle mean done).
        public var sawWork = false
        /// The state last seen.
        public var last: AgentActivity
    }

    /// What to say about a watched session.
    public enum Event: Equatable, Sendable {
        /// It finished its turn; no longer watched.
        case finished(agent: String, workspaceID: String)
        /// It waits for the user (`question`: what it asks, if known).
        case needsInput(agent: String, workspaceID: String, question: String?)
    }

    /// A task not finished after this is no longer followed.
    public static let lifetime: TimeInterval = 4 * 3600
    /// An agent that was never seen after this is taken as not started.
    public static let startGrace: TimeInterval = 120
    /// The most sessions followed at once (the oldest is dropped).
    public static let maxEntries = 12

    public private(set) var entries: [Entry] = []

    public init() {}

    public func isWatching(paneID: String) -> Bool { entries.contains { $0.paneID == paneID } }

    /// Follow the pane from now (again, if it was already followed). `current`: its state now, so a working agent that
    /// was just told something only counts as done once it has worked on it.
    public mutating func watch(paneID: String, workspaceID: String, agent: String, current: AgentActivity, now: Date) {
        entries.removeAll { $0.paneID == paneID }
        entries.append(Entry(paneID: paneID, workspaceID: workspaceID, agent: agent, since: now, sawWork: false,
                             last: current == .busy ? .idle : current))
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
    }

    /// The pane's agent state changed (or may have): what to say, if anything.
    public mutating func update(paneID: String, activity: AgentActivity, question: String?, now: Date) -> Event? {
        guard let index = entries.firstIndex(where: { $0.paneID == paneID }) else { return nil }
        let entry = entries[index]
        guard activity != entry.last else { return nil }
        let previous = entry.last
        entries[index].last = activity
        switch activity {
        case .busy:
            entries[index].sawWork = true
            return nil
        case .needsInput:
            entries[index].sawWork = true
            return .needsInput(agent: entry.agent, workspaceID: entry.workspaceID,
                               question: question.map(AssistantReport.clip).flatMap { $0.isEmpty ? nil : $0 })
        case .idle:
            guard entry.sawWork, previous == .busy || previous == .needsInput else { return nil }
            entries.remove(at: index)
            return .finished(agent: entry.agent, workspaceID: entry.workspaceID)
        case .none:
            // The agent exited after working: nothing more to follow.
            if entry.sawWork || previous != .none { entries.remove(at: index) }
            return nil
        }
    }

    /// Drops what is too old, and sessions whose agent never showed up.
    public mutating func expire(now: Date) {
        entries.removeAll { entry in
            now.timeIntervalSince(entry.since) > Self.lifetime
                || (!entry.sawWork && entry.last == .none && now.timeIntervalSince(entry.since) > Self.startGrace)
        }
    }

    /// Stops following a pane (closed).
    public mutating func forget(paneID: String) { entries.removeAll { $0.paneID == paneID } }
}
