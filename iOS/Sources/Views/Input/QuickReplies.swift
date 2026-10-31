import Foundation

/// Shortcut buttons above the key bar: each sends its text to the pane, then Return
/// (canned replies to an agent, or a command such as `claude`). Edited in ⋯ › Settings….
enum QuickReplies {
    static let key = "quickReplies"

    /// Stored as one shortcut per line; an empty string means the user removed them all.
    static var defaultStorage: String { defaults.joined(separator: "\n") }

    static var defaults: [String] {
        [
            String(localized: "Approved", comment: "quick reply sent to a coding agent"),
            String(localized: "Consider", comment: "quick reply sent to a coding agent"),
            String(localized: "Suggest an alternative", comment: "quick reply sent to a coding agent"),
            String(localized: "Double-check it", comment: "quick reply sent to a coding agent"),
            "claude",
            "codex",
        ]
    }

    static func decode(_ storage: String) -> [String] {
        storage.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    static func encode(_ replies: [String]) -> String {
        replies.map { $0.replacingOccurrences(of: "\n", with: " ") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
    }
}
