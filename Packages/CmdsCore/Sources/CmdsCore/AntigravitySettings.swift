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
        /// Its status line runs `cmds hook agy-status` by a full path that exists.
        case setUp
        /// Its status line runs the hook, but through `cmds` on the PATH (agy outside cmds may find an old or broken
        /// `cmds` there) or a path that is gone (the app moved): setting up again writes this app's CLI (#305).
        case needsUpdate(String)
        /// Another status-line command (setting up replaces it).
        case otherCommand(String)
        /// Not a JSON object: left alone.
        case unreadable
    }

    /// The hook's subcommand, found in a status-line command whatever the path to `cmds`.
    static let hookArguments = "hook agy-status"

    /// `exists`: whether a file is at a path (the app passes the file system; tests pass a set).
    public static func state(of data: Data?, exists: (String) -> Bool = { _ in true }) -> State {
        guard let data else { return .noFile }
        if isBlank(data) { return .notSetUp }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unreadable }
        guard let line = object["statusLine"] as? [String: Any], let command = line["command"] as? String,
              !command.trimmingCharacters(in: .whitespaces).isEmpty else { return .notSetUp }
        guard command.contains(hookArguments) else { return .otherCommand(command) }
        guard let program = program(of: command), program.hasPrefix("/"), exists(program) else { return .needsUpdate(command) }
        return .setUp
    }

    /// The first word of a command, a single-quoted one unquoted (as `shellQuoted` writes it); nil when unclear.
    static func program(of command: String) -> String? {
        let text = command.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("'") else { return text.split(separator: " ").first.map(String.init) }
        var result = ""
        var rest = Substring(text)
        // 'a'\''b' → a'b: quoted runs joined by an escaped quote.
        while rest.hasPrefix("'") {
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(of: "'") else { return nil }
            result += rest[..<end]
            rest = rest[rest.index(after: end)...]
            guard rest.hasPrefix("\\'") else { break }
            result += "'"
            rest = rest.dropFirst(2)
        }
        return rest.isEmpty || rest.hasPrefix(" ") ? result : nil
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
