import Foundation

/// Which pane a `sendText` schedule types into (`PaneTarget`). Pure, unit-tested (ScheduleTargetTests); the app lists
/// its panes as `Candidate`s.
///
/// Never guesses: a target that matches no pane is `notFound`, one that matches several is `ambiguous`, and the run is
/// skipped. Only local terminal panes can be targets (an SSH pane's foreground process cannot be checked).
public enum ScheduleTarget {
    public struct Candidate: Equatable, Sendable {
        public var paneID: String
        public var workspaceTitle: String
        public var workspaceID: String
        /// `Pane.scheduleTag`.
        public var tag: String?
        /// A local terminal pane (not SSH, browser, preview or files).
        public var isLocalTerminal: Bool

        public init(paneID: String, workspaceID: String, workspaceTitle: String, tag: String? = nil,
                    isLocalTerminal: Bool = true) {
            self.paneID = paneID
            self.workspaceID = workspaceID
            self.workspaceTitle = workspaceTitle
            self.tag = tag
            self.isLocalTerminal = isLocalTerminal
        }
    }

    public enum Resolution: Equatable, Sendable {
        case pane(String)
        case notFound
        case ambiguous

        /// The run's reason when it cannot go on.
        public var problem: ScheduleReason? {
            switch self {
            case .pane: return nil
            case .notFound: return .paneNotFound
            case .ambiguous: return .ambiguousTarget
            }
        }
    }

    /// `tag`: the local terminal pane with that tag. `workspace`: the only workspace with that title (trimmed,
    /// case-insensitive), if it has exactly one local terminal pane. `pane`: that pane, if it is a local terminal.
    public static func resolve(_ target: PaneTarget, in panes: [Candidate]) -> Resolution {
        switch target {
        case .tag(let tag):
            return one(panes.filter { $0.isLocalTerminal && $0.tag == tag })
        case .pane(let id):
            return one(panes.filter { $0.isLocalTerminal && $0.paneID == id })
        case .workspace(let title):
            let wanted = normalized(title)
            let matching = panes.filter { normalized($0.workspaceTitle) == wanted }
            switch Set(matching.map(\.workspaceID)).count {
            case 0: return .notFound
            case 1: return one(matching.filter(\.isLocalTerminal))
            default: return .ambiguous
            }
        }
    }

    private static func one(_ panes: [Candidate]) -> Resolution {
        switch panes.count {
        case 0: return .notFound
        case 1: return .pane(panes[0].paneID)
        default: return .ambiguous
        }
    }

    private static func normalized(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Restoring saved tags (launch, `state.import`): a tag that is not valid or already in use (`taken`, or earlier
    /// in `tags`) is dropped, so a tag never names two panes. Same order as `tags`.
    public static func uniqueTags(_ tags: [String?], taken: Set<String> = []) -> [String?] {
        var seen = taken
        return tags.map { tag in
            guard let tag, ScheduleIDs.isValid(tag, prefix: ScheduleIDs.paneTagPrefix), seen.insert(tag).inserted else { return nil }
            return tag
        }
    }
}
