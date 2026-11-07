import Foundation

/// Lenient readers for agents' status-line JSON (Claude Code, Antigravity): numbers may come as strings, blank
/// strings count as missing.
enum StatusLineJSON {
    static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let number)?: return number.isFinite ? number : nil
        case .string(let string)?: return Double(string.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        default: return nil
        }
    }

    static func int(_ value: JSONValue?) -> Int? {
        guard let number = number(value), abs(number) < 9e15 else { return nil }
        return Int(number.rounded(.down))
    }

    static func bool(_ value: JSONValue?) -> Bool? {
        switch value {
        case .bool(let bool)?: return bool
        case .string(let string)?: return string == "true" ? true : string == "false" ? false : nil
        default: return nil
        }
    }
}
