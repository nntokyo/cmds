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
        storage.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).map { sanitize(String($0)) }.filter(isUsable)
    }

    static func encode(_ replies: [String]) -> String {
        replies.map(sanitize).filter(isUsable).joined(separator: "\n")
    }

    /// One line of plain text. Control characters (CR, tab, ESC…) would reach the Mac as keys, and a
    /// line break also makes the Mac paste instead of type, so they become spaces. Invisible characters
    /// that only break a command (zero-width space, BOM, bidi overrides) are dropped; joiners used by
    /// emoji stay.
    static func sanitize(_ reply: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in reply.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: scalars.append(" ")
            default: if !invisible.contains(scalar.value) { scalars.append(scalar) }
            }
        }
        return String(scalars)
    }

    private static let invisible: Set<UInt32> = Set([0x200B, 0xFEFF] + Array(0x202A...0x202E) + Array(0x2066...0x2069))

    private static func isUsable(_ reply: String) -> Bool {
        !reply.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
