import Foundation

/// How a notification reads (#174 G21): the sidebar's notification text gets its colour and symbol, and an error
/// lights the pane's ring red instead of orange. `cmds notify --level`, `cmds status --level`, MCP set_status; cmds
/// itself marks a long command that failed as an error and one that succeeded as a success.
public enum NotificationLevel: String, CaseIterable, Codable, Equatable, Sendable {
    case info, success, warning, error

    /// Before the sidebar text, so the level does not rest on colour alone. None for `info`.
    public var symbol: String? {
        switch self {
        case .info: return nil
        case .success: return "✓"
        case .warning: return "⚠︎"
        case .error: return "✗"
        }
    }

    /// `text` as the sidebar shows it: with the symbol first.
    public func decorate(_ text: String) -> String {
        symbol.map { "\($0) \(text)" } ?? text
    }

    /// A level named in a request; nil (absent) is `info`.
    public static func parse(_ name: String?) throws -> NotificationLevel {
        guard let name, !name.isEmpty else { return .info }
        guard let level = NotificationLevel(rawValue: name.lowercased()) else {
            throw Invalid(description: "level must be info, success, warning or error")
        }
        return level
    }

    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// A level a newer Mac adds reads as `info` (an unknown one must not fail the whole workspace list on a phone).
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = NotificationLevel(rawValue: raw) ?? .info
    }
}
