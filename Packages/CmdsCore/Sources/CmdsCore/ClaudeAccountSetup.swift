import Foundation

/// What cmds needs in an account's Claude Code settings (`<configDir>/settings.json`, docs/guide/ai-agents.md
/// "Several Claude accounts"): the status line that reports the session (`cmds hook claude-status`: usage, session id
/// and the account; without it the pane has no account button, no limit is seen and nothing can be switched) and the
/// hooks that report the agent's state (`cmds hook claude`). `apply` adds what is missing and nothing else: other
/// settings stay, a status line of the user's own is never replaced, and the file is copied aside first.
public enum ClaudeAccountSetup {
    public static let statusCommand = "cmds hook claude-status"
    public static let hookCommand = "command -v cmds >/dev/null && cmds hook claude || true"
    /// The events of docs/guide/ai-agents.md "Notifications (hooks)".
    public static let hookEvents = ["Notification", "Stop", "UserPromptSubmit", "SubagentStart", "SubagentStop"]
    static let maxScriptSize = 256 * 1024

    public enum StatusLine: String, Equatable, Sendable {
        /// Calls `cmds hook claude-status` (itself, or the script it runs does).
        case reports
        /// No status line is set.
        case missing
        /// A status line of the user's own that does not call cmds: left alone (the guide has the line to add).
        case own
    }

    public struct State: Equatable, Sendable {
        public var statusLine: StatusLine
        /// `hookEvents` without a `cmds hook claude` hook.
        public var missingHooks: [String]
        /// `settings.json` exists and is not a JSON object: nothing is changed.
        public var unreadable = false

        public init(statusLine: StatusLine, missingHooks: [String], unreadable: Bool = false) {
            self.statusLine = statusLine
            self.missingHooks = missingHooks
            self.unreadable = unreadable
        }

        public var isComplete: Bool { !unreadable && statusLine == .reports && missingHooks.isEmpty }
        /// `apply` would change the file.
        public var canAdd: Bool { !unreadable && (statusLine == .missing || !missingHooks.isEmpty) }
    }

    /// What `apply` did.
    public struct Result: Equatable, Sendable {
        public var statusLine: StatusLine
        public var statusLineAdded: Bool
        public var hooksAdded: [String]
        /// The copy of the previous `settings.json` (nil: there was none, or nothing changed).
        public var backup: String?
    }

    public enum SetupError: Error, Equatable, CustomStringConvertible {
        case noConfigDir
        case unreadable

        public var description: String {
            switch self {
            case .noConfigDir: return "the config directory does not exist yet (sign in first: cmds accounts login NAME)"
            case .unreadable: return "settings.json is not a JSON object; nothing was changed"
            }
        }
    }

    public static func settingsPath(of account: ClaudeAccount, home: String = NSHomeDirectory()) -> String {
        ClaudeAccounts.expandedPath(account.configDir, home: home) + "/settings.json"
    }

    /// The state of the account's settings; nil when its config directory does not exist.
    public static func state(of account: ClaudeAccount, home: String = NSHomeDirectory()) -> State? {
        guard ClaudeAccounts.configDirExists(account, home: home) else { return nil }
        return state(settings: FileManager.default.contents(atPath: settingsPath(of: account, home: home))) {
            script(at: $0, home: home)
        }
    }

    /// `settings`: the file's content (nil: no file). `readScript`: the text of the status line's script, by its path
    /// as written in the command.
    public static func state(settings: Data?, readScript: (String) -> String? = { _ in nil }) -> State {
        guard let settings else { return State(statusLine: .missing, missingHooks: hookEvents) }
        guard let object = try? JSONSerialization.jsonObject(with: settings) as? [String: Any] else {
            return State(statusLine: .missing, missingHooks: hookEvents, unreadable: true)
        }
        return State(statusLine: statusLine(object["statusLine"], readScript: readScript), missingHooks: missingHooks(object["hooks"]))
    }

    private static func statusLine(_ value: Any?, readScript: (String) -> String?) -> StatusLine {
        guard let command = (value as? [String: Any])?["command"] as? String,
              !command.trimmingCharacters(in: .whitespaces).isEmpty else { return .missing }
        if command.contains(statusCommand) { return .reports }
        // A script: its first word is the file.
        let path = command.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        if let text = readScript(path), text.contains(statusCommand) { return .reports }
        return .own
    }

    private static func missingHooks(_ value: Any?) -> [String] {
        let hooks = value as? [String: Any] ?? [:]
        return hookEvents.filter { event in
            let entries = hooks[event] as? [[String: Any]] ?? []
            return !entries.contains { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains("cmds hook claude") == true }
            }
        }
    }

    private static func script(at path: String, home: String) -> String? {
        let expanded = ClaudeAccounts.expandedPath(path, home: home)
        guard expanded.hasPrefix("/"),
              let size = (try? FileManager.default.attributesOfItem(atPath: expanded))?[.size] as? Int, size <= maxScriptSize,
              let data = FileManager.default.contents(atPath: expanded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The status line to give an account without one: the one of the first account whose status line reports (the
    /// same line everywhere), else the bare command (an empty status line).
    public static func statusLineTemplate(from accounts: [ClaudeAccount], home: String = NSHomeDirectory()) -> [String: Any] {
        for account in accounts where state(of: account, home: home)?.statusLine == .reports {
            if let data = FileManager.default.contents(atPath: settingsPath(of: account, home: home)),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let line = object["statusLine"] as? [String: Any] { return line }
        }
        return ["type": "command", "command": statusCommand]
    }

    /// `settings` with what is missing added (a status line only when there is none); nil when nothing is.
    public static func updated(settings: Data?, statusLine template: [String: Any]) throws -> Data? {
        var object: [String: Any] = [:]
        if let settings {
            guard let parsed = try? JSONSerialization.jsonObject(with: settings) as? [String: Any] else { throw SetupError.unreadable }
            object = parsed
        }
        let before = state(settings: settings)
        guard before.canAdd else { return nil }
        if before.statusLine == .missing { object["statusLine"] = template }
        var hooks = object["hooks"] as? [String: Any] ?? [:]
        for event in before.missingHooks {
            var entries = hooks[event] as? [Any] ?? []
            entries.append(["hooks": [["type": "command", "command": hookCommand]]])
            hooks[event] = entries
        }
        if !before.missingHooks.isEmpty { object["hooks"] = hooks }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Adds what is missing to the account's `settings.json` (through a symlink, to the file it points to), after
    /// copying the previous file to `settings.json.cmds-backup-<time>` next to it.
    public static func apply(to account: ClaudeAccount, in accounts: [ClaudeAccount], home: String = NSHomeDirectory(),
                             now: Date = Date()) throws -> Result {
        guard ClaudeAccounts.configDirExists(account, home: home) else { throw SetupError.noConfigDir }
        let fileManager = FileManager.default
        let path = (settingsPath(of: account, home: home) as NSString).resolvingSymlinksInPath
        let old = fileManager.contents(atPath: path)
        let before = state(settings: old) { script(at: $0, home: home) }
        guard !before.unreadable else { throw SetupError.unreadable }
        let template = statusLineTemplate(from: accounts.filter { !$0.hasName(account.name) }, home: home)
        guard before.canAdd, let data = try updated(settings: old, statusLine: template) else {
            return Result(statusLine: before.statusLine, statusLineAdded: false, hooksAdded: [], backup: nil)
        }
        var backup: String?
        if old != nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMddHHmmss"
            var candidate = path + ".cmds-backup-" + formatter.string(from: now)
            var number = 2
            while fileManager.fileExists(atPath: candidate) {
                candidate = path + ".cmds-backup-" + formatter.string(from: now) + "-\(number)"
                number += 1
            }
            try fileManager.copyItem(atPath: path, toPath: candidate)
            backup = candidate
        }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        let after = state(settings: data) { script(at: $0, home: home) }
        return Result(statusLine: after.statusLine, statusLineAdded: before.statusLine == .missing,
                      hooksAdded: before.missingHooks, backup: backup)
    }
}
