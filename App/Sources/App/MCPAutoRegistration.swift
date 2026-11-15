import AppKit
import CmdsCore
import UserNotifications

/// Registers cmds' MCP server (`cmds mcp`) with the agents on this Mac by itself (`AgentMCPRegistration`): Claude
/// Code's plain config and every Claude account's config directory, and Codex. Runs at launch and when an account is
/// added; Settings › Agents › "Register the MCP server with agents" turns it off.
///
/// Each target is registered once: a registration the user removed later is not added again (the targets done are
/// remembered in `MCPRegisteredTargets`). cmds' own entry by a full path that is gone (cmds.app moved) is pointed at
/// this app again. One notification lists what was added.
@MainActor
enum MCPAutoRegistration {
    static let enabledKey = "RegisterMCPServer"
    static let doneKey = "MCPRegisteredTargets"
    private static var running = false

    struct Target: Sendable {
        enum Kind: Sendable { case claude(configDir: String?), codex }
        var kind: Kind
        var file: String
        /// Shown in the notification: "Claude Code", "Claude Code (work)", "Codex".
        var label: String
        /// Remembered once done.
        var key: String { file }
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue ? nil : false, forKey: enabledKey) }
    }

    /// The `cmds` the agents start: this app's CLI by its full path, so the server starts also in terminals outside
    /// cmds (where it offers no tools) and without Install Command Line Tool….
    static var cli: String? { BundledCLI.executablePath }

    /// The targets that exist: plain Claude Code when `~/.claude.json` does, each account whose folder exists (an
    /// account on `~/.claude` without `CLAUDE_CONFIG_DIR` is plain Claude Code), Codex when its folder exists.
    static func targets(accounts: [ClaudeAccount]) -> [Target] {
        let fileManager = FileManager.default
        var targets: [Target] = []
        let plain = AgentMCPRegistration.claudeConfigFile(configDir: nil)
        if fileManager.fileExists(atPath: plain) {
            targets.append(Target(kind: .claude(configDir: nil), file: plain, label: "Claude Code"))
        }
        for account in accounts where ClaudeAccounts.configDirExists(account) {
            let file = AgentMCPRegistration.claudeConfigFile(configDir: account.configDir)
            guard !targets.contains(where: { $0.file == file }) else { continue }
            targets.append(Target(kind: .claude(configDir: ClaudeAccounts.expandedPath(account.configDir)), file: file,
                                  label: "Claude Code (\(account.name))"))
        }
        let codex = AgentMCPRegistration.codexConfigFile()
        if fileManager.fileExists(atPath: (codex as NSString).deletingLastPathComponent) {
            targets.append(Target(kind: .codex, file: codex, label: "Codex"))
        }
        return targets
    }

    /// Registers where needed, off the main thread; `force` also adds to targets done before (Settings' button).
    static func run(accounts: [ClaudeAccount], force: Bool = false, done: (([String], [String]) -> Void)? = nil) {
        guard (isEnabled || force), !running, let cli else { return }
        running = true
        let targets = targets(accounts: accounts)
        let previously = Set(UserDefaults.standard.stringArray(forKey: doneKey) ?? [])
        DispatchQueue.global(qos: .utility).async {
            var added: [String] = []
            var failed: [String] = []
            var finished: [String] = []
            for target in targets {
                switch register(target, cli: cli, skipMissing: !force && previously.contains(target.key)) {
                case .added: added.append(target.label); finished.append(target.key)
                case .present: finished.append(target.key)
                case .skipped: break
                case .failed(let reason):
                    NSLog("cmds: could not register the MCP server with \(target.label): \(reason)")
                    failed.append(target.label)
                }
            }
            DispatchQueue.main.async {
                running = false
                UserDefaults.standard.set(Array(previously.union(finished)).sorted(), forKey: doneKey)
                if !added.isEmpty, done == nil { notify(added) }
                done?(added, failed)
            }
        }
    }

    enum Outcome { case added, present, skipped, failed(String) }

    nonisolated static func register(_ target: Target, cli: String, skipMissing: Bool) -> Outcome {
        let fileManager = FileManager.default
        switch target.kind {
        case .claude(let configDir):
            switch AgentMCPRegistration.claudeState(fileManager.contents(atPath: target.file)) {
            case .registered: return .present
            case .unreadable: return .failed("\(target.file) is not valid JSON")
            case .missing:
                if skipMissing { return .skipped }
                return runClaude(AgentMCPRegistration.claudeAddArguments(cli: cli), configDir: configDir)
            case .stale:
                // Its own entry by a gone path: replaced (a server named otherwise is left alone).
                _ = runClaude(AgentMCPRegistration.claudeRemoveArguments(), configDir: configDir)
                return runClaude(AgentMCPRegistration.claudeAddArguments(cli: cli), configDir: configDir)
            }
        case .codex:
            let text = fileManager.contents(atPath: target.file).flatMap { String(data: $0, encoding: .utf8) }
            if fileManager.fileExists(atPath: target.file), text == nil { return .failed("\(target.file) is not UTF-8") }
            let updated: String
            switch AgentMCPRegistration.codexState(text) {
            case .registered: return .present
            case .unreadable: return .failed("\(target.file) cannot be read")
            case .missing:
                if skipMissing { return .skipped }
                updated = AgentMCPRegistration.codexAppending(text, cli: cli)
            case .stale(let command):
                updated = AgentMCPRegistration.codexReplacingCommand(text ?? "", stale: command, cli: cli)
            }
            do {
                if fileManager.fileExists(atPath: target.file) {
                    let backup = target.file + ".cmds-backup-\(Int(Date().timeIntervalSince1970))"
                    try fileManager.copyItem(atPath: target.file, toPath: backup)
                }
                try updated.write(toFile: target.file, atomically: true, encoding: .utf8)
                return .added
            } catch {
                return .failed("\(error)")
            }
        }
    }

    /// Runs `claude` (the first one found) with `CLAUDE_CONFIG_DIR` set for an account.
    nonisolated static func runClaude(_ arguments: [String], configDir: String?) -> Outcome {
        guard let claude = ClaudeChromeHost.claudeCandidates().first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return .failed("claude was not found")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        if let configDir { environment["CLAUDE_CONFIG_DIR"] = configDir }
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return .failed("\(error)") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return .failed(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(process.terminationStatus)")
        }
        return .added
    }

    private static func notify(_ added: [String]) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "cmds’ MCP server is ready for your agents", comment: "notification: MCP server registered")
        content.body = String(localized: "Registered with \(added.joined(separator: ", ")). Agents started from now on in a cmds terminal have its tools (browser panes, previews, terminal panes).",
                              comment: "notification: MCP server registered; the agents listed")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "cmds.mcp.registered", content: content, trigger: nil))
    }
}
