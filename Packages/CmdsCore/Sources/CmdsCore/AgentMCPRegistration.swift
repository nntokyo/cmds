import Foundation

/// Registering `cmds mcp` (the MCP server, docs/guide/ai-agents.md "MCP server") with the agents on this Mac, so
/// agents in cmds terminals have its tools without a manual `claude mcp add`.
///
/// Targets: Claude Code's user config of plain `claude` (`~/.claude.json`) and of every account's config directory
/// (`<CLAUDE_CONFIG_DIR>/.claude.json`: each account has its own MCP servers), and Codex (`~/.codex/config.toml`).
/// Claude Code is changed only through its own CLI (`claude mcp add --scope user`); Codex's `codex mcp add` cannot set
/// `env_vars`, so a `[mcp_servers.cmds]` table is appended to its file (after a copy). A server named `cmds`, or any
/// server running `… mcp` of a `cmds`, counts as registered and is never replaced, unless it is cmds' own entry by a
/// full path that is gone (cmds.app moved). This file only decides; the app runs the commands.
public enum AgentMCPRegistration {
    public static let serverName = "cmds"

    public enum State: Equatable, Sendable {
        /// Registered; `command` is what it runs.
        case registered(command: String)
        /// cmds' own entry by a full path that no longer exists.
        case stale(command: String)
        case missing
        /// The file exists but cannot be read as the agent's config: left alone.
        case unreadable
    }

    /// The command runs cmds' MCP server: `cmds` or a path ending in `/cmds`.
    static func isCmds(_ command: String) -> Bool {
        command == "cmds" || command.hasSuffix("/cmds")
    }

    static func state(command: String, exists: (String) -> Bool) -> State {
        if command.hasPrefix("/"), command.hasSuffix("/Contents/Resources/bin/cmds"), !exists(command) {
            return .stale(command: command)
        }
        return .registered(command: command)
    }

    // MARK: Claude Code

    /// The user config file Claude Code reads for `configDir` (nil: plain `claude`, `~/.claude.json`).
    public static func claudeConfigFile(configDir: String?, home: String = NSHomeDirectory()) -> String {
        guard let configDir else { return home + "/.claude.json" }
        return ClaudeAccounts.expandedPath(configDir, home: home) + "/.claude.json"
    }

    /// `data`: the `.claude.json` (nil: none yet).
    public static func claudeState(_ data: Data?, exists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> State {
        guard let data else { return .missing }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unreadable }
        let servers = object["mcpServers"] as? [String: Any] ?? [:]
        if let own = servers[serverName] as? [String: Any] {
            return state(command: own["command"] as? String ?? "", exists: exists)
        }
        for case let server as [String: Any] in servers.values {
            if let command = server["command"] as? String, isCmds(command), (server["args"] as? [String])?.first == "mcp" {
                return state(command: command, exists: exists)
            }
        }
        return .missing
    }

    /// `claude mcp add --scope user cmds -- <cli> mcp` (run with `CLAUDE_CONFIG_DIR` for an account).
    public static func claudeAddArguments(cli: String) -> [String] {
        ["mcp", "add", "--scope", "user", serverName, "--", cli, "mcp"]
    }

    public static func claudeRemoveArguments() -> [String] {
        ["mcp", "remove", "--scope", "user", serverName]
    }

    // MARK: Codex

    public static func codexConfigFile(environment: [String: String] = ProcessInfo.processInfo.environment,
                                       home: String = NSHomeDirectory()) -> String {
        let codexHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.codex"
        return codexHome + "/config.toml"
    }

    /// `text`: `config.toml` (nil: none yet).
    public static func codexState(_ text: String?, exists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> State {
        guard let text else { return .missing }
        var table: String?
        var commands: [String: String] = [:]
        var firstArgs: [String: String] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                table = mcpServerName(header: line)
                continue
            }
            guard let table, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if key == "command" { commands[table] = unquoted(value) }
            if key == "args" { firstArgs[table] = firstArrayItem(value) }
        }
        if let command = commands[serverName] { return state(command: command, exists: exists) }
        if let (_, command) = commands.first(where: { isCmds($0.value) && firstArgs[$0.key] == "mcp" }) {
            return state(command: command, exists: exists)
        }
        return commands.isEmpty && text.contains("[mcp_servers.\(serverName)]") ? .registered(command: "") : .missing
    }

    /// `[mcp_servers.NAME]` → NAME (`"NAME"` unquoted). A sub-table (`[mcp_servers.NAME.env]`) gives `NAME.env`,
    /// which names no server; other tables give nil.
    static func mcpServerName(header: String) -> String? {
        guard header.hasPrefix("[mcp_servers."), header.hasSuffix("]") else { return nil }
        return unquoted(String(header.dropFirst("[mcp_servers.".count).dropLast()))
    }

    static func unquoted(_ value: String) -> String {
        var value = value
        if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
        value = value.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    static func firstArrayItem(_ value: String) -> String? {
        guard value.hasPrefix("[") else { return nil }
        let inner = value.dropFirst().split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
        let item = unquoted(inner.replacingOccurrences(of: "]", with: "").trimmingCharacters(in: .whitespaces))
        return item.isEmpty ? nil : item
    }

    static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The table appended to Codex's file. Codex starts MCP servers with a cleaned environment: `env_vars` passes on
    /// the variables that tell cmds which terminal it runs in.
    public static func codexTable(cli: String) -> String {
        """
        # Added by cmds: its MCP server (browser panes, previews, terminal panes) for Codex in cmds terminals.
        [mcp_servers.\(serverName)]
        command = \(tomlString(cli))
        args = ["mcp"]
        env_vars = ["CMDS_PANE_ID", "CMDS_WORKSPACE_ID", "CMDS_SOCKET_PATH"]

        """
    }

    /// `text` with the table appended (a blank line before it).
    public static func codexAppending(_ text: String?, cli: String) -> String {
        var text = text ?? ""
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        if !text.isEmpty, !text.hasSuffix("\n\n") { text += "\n" }
        return text + codexTable(cli: cli)
    }

    /// `text` with cmds' stale `command` replaced by `cli` in the `[mcp_servers.<name>]` table that has it.
    public static func codexReplacingCommand(_ text: String, stale: String, cli: String) -> String {
        text.replacingOccurrences(of: "command = \(tomlString(stale))", with: "command = \(tomlString(cli))")
    }
}
