import Foundation

/// Antigravity CLI's `settings.json` (`~/.gemini/antigravity-cli/settings.json`) and the status line cmds reads its
/// usage and quota from (#290, Settings › Agents › Antigravity limits): whether it is set up, and the file with it
/// added. Every other key is kept. Pure; the app reads and writes the file.
public enum AntigravitySettings {
    /// `~/.gemini/antigravity-cli/settings.json` under `home`.
    public static func path(home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".gemini/antigravity-cli/settings.json")
    }

    public enum State: Equatable, Sendable {
        /// No settings file yet.
        case noFile
        /// The file has no status line.
        case notSetUp
        /// Its status line runs `cmds hook agy-status`.
        case setUp
        /// Another status-line command (setting up replaces it).
        case otherCommand(String)
        /// Not a JSON object: left alone.
        case unreadable
    }

    /// The hook's subcommand, found in a status-line command whatever the path to `cmds`.
    static let hookArguments = "hook agy-status"

    public static func state(of data: Data?) -> State {
        guard let data else { return .noFile }
        if isBlank(data) { return .notSetUp }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unreadable }
        guard let line = object["statusLine"] as? [String: Any], let command = line["command"] as? String,
              !command.trimmingCharacters(in: .whitespaces).isEmpty else { return .notSetUp }
        return command.contains(hookArguments) ? .setUp : .otherCommand(command)
    }

    /// The file with cmds' status line (`cli`: the `cmds` to run), agy's own status line kept under it
    /// (`stack_with_default`). Nil when the file is not a JSON object.
    public static func settingUp(_ data: Data?, cli: String) -> Data? {
        var object: [String: Any] = [:]
        if let data, !isBlank(data) {
            guard let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            object = existing
        }
        object["statusLine"] = ["type": "command", "command": "\(shellQuoted(cli)) \(hookArguments)", "stack_with_default": true]
        return try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// An empty file, or only spaces and newlines: no settings yet.
    private static func isBlank(_ data: Data) -> Bool {
        data.allSatisfy { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
    }

    /// `cli` as one shell word (single quotes only when needed: `cmds` and plain paths stay as they are).
    static func shellQuoted(_ cli: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+")
        if !cli.isEmpty, cli.unicodeScalars.allSatisfy(plain.contains) { return cli }
        return "'" + cli.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
