import AppKit
import CmdsCore
import UserNotifications

/// Registers cmds' MCP server (`cmds mcp`) with the agents on this Mac by itself (`AgentMCPRegistration`): Claude
/// Code's plain config and every Claude account's config directory, Codex, and the Antigravity CLI. Runs at launch,
/// when the accounts change, and when a pane's Claude Code reports its config directory (at most once a minute: an
/// account signed in while cmds runs); Settings › Agents › "Register cmds' MCP server with your agents" turns it off.
///
/// Each target is registered once: a registration the user removed later is not added again (the targets done are
/// remembered in `MCPRegisteredTargets` with the creation time of their config folder, so a folder made again is
/// registered again). cmds' own entry by a full path that is gone (cmds.app moved) is pointed at this app again. One
/// notification lists what was added. A run asked for while one runs follows it.
@MainActor
enum MCPAutoRegistration {
    static let enabledKey = "RegisterMCPServer"
    static let doneKey = "MCPRegisteredTargets"
    private static var running = false
    private static var again = false
    private static var lastCheck: Date = .distantPast

    struct Target: Sendable {
        enum Kind: Sendable { case claude(configDir: String?), codex, agy }
        var kind: Kind
        var file: String
        /// The folder whose creation time tells a config made again (`AgentMCPRegistration.doneKey`).
        var folder: String
        /// Shown in the notification: "Claude Code", "Claude Code (work)", "Codex", "Antigravity CLI".
        var label: String
        /// Remembered once done.
        var key: String { AgentMCPRegistration.doneKey(file: file, folder: folder) }
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
            targets.append(Target(kind: .claude(configDir: nil), file: plain, folder: NSHomeDirectory(), label: "Claude Code"))
        }
        for account in accounts where ClaudeAccounts.configDirExists(account) {
            let file = AgentMCPRegistration.claudeConfigFile(configDir: account.configDir)
            guard !targets.contains(where: { $0.file == file }) else { continue }
            let dir = ClaudeAccounts.expandedPath(account.configDir)
            targets.append(Target(kind: .claude(configDir: dir), file: file, folder: dir, label: "Claude Code (\(account.name))"))
        }
        let codex = AgentMCPRegistration.codexConfigFile()
        let codexDir = (codex as NSString).deletingLastPathComponent
        if fileManager.fileExists(atPath: codexDir) {
            targets.append(Target(kind: .codex, file: codex, folder: codexDir, label: "Codex"))
        }
        // agy keeps its own settings in antigravity-cli; its MCP servers in config/ (made by `agy mcp add`).
        let agy = AgentMCPRegistration.agyConfigFile()
        if fileManager.fileExists(atPath: NSHomeDirectory() + "/.gemini/antigravity-cli") {
            targets.append(Target(kind: .agy, file: agy, folder: NSHomeDirectory() + "/.gemini", label: "Antigravity CLI"))
        }
        return targets
    }

    /// Registers where needed, off the main thread; `force` also adds to targets done before (Settings' button).
    /// From a pane's status line report: at most once a minute (the run itself only reads files when nothing is missing).
    static func runSoon() {
        guard Date().timeIntervalSince(lastCheck) >= 60 else { return }
        run(accounts: AppController.shared.claudeAccounts.accounts)
    }

    static func run(accounts: [ClaudeAccount], force: Bool = false, done: (([String], [String]) -> Void)? = nil) {
        // Not in an isolated test instance (CMDS_SUPPORT_DIR): the agents' configs are the user's.
        guard isEnabled || force, force || CmdsEnv.supportDirectoryOverride() == nil, let cli else { return }
        guard !running else {
            // Once this run ends (a forced run with its answer is not queued: the user can click again).
            if done == nil { again = true }
            return
        }
        running = true
        lastCheck = Date()
        let targets = targets(accounts: accounts)
        var previously = Set(UserDefaults.standard.stringArray(forKey: doneKey) ?? [])
        // 0.27.0 kept bare paths: they stand for the folder as it is now.
        for target in targets where previously.contains(target.file) {
            previously.remove(target.file)
            previously.insert(target.key)
        }
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
                if again {
                    again = false
                    DispatchQueue.main.async { run(accounts: AppController.shared.claudeAccounts.accounts) }
                }
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
        case .claude, .agy:
            let agy = { if case .agy = target.kind { return true } else { return false } }()
            let configDir: String? = { if case .claude(let dir) = target.kind { return dir } else { return nil } }()
            let add = agy ? AgentMCPRegistration.agyAddArguments(cli: cli) : AgentMCPRegistration.claudeAddArguments(cli: cli)
            let remove = agy ? AgentMCPRegistration.agyRemoveArguments() : AgentMCPRegistration.claudeRemoveArguments()
            let tool = agy ? agyCandidates : ClaudeChromeHost.claudeCandidates()
            switch AgentMCPRegistration.claudeState(fileManager.contents(atPath: target.file)) {
            case .registered: return .present
            case .unreadable: return .failed("\(target.file) is not valid JSON")
            case .missing:
                if skipMissing { return .skipped }
                return runTool(tool, add, configDir: configDir)
            case .stale:
                // Its own entry by a gone path: replaced (a server named otherwise is left alone).
                _ = runTool(tool, remove, configDir: configDir)
                return runTool(tool, add, configDir: configDir)
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

    /// Where `agy` is: its installer's folder, Homebrew.
    nonisolated static var agyCandidates: [String] {
        [NSHomeDirectory() + "/.gemini/bin/agy", NSHomeDirectory() + "/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
    }

    /// Runs the first of `candidates` found (`claude` with `CLAUDE_CONFIG_DIR` set for an account, or `agy`).
    nonisolated static func runTool(_ candidates: [String], _ arguments: [String], configDir: String?) -> Outcome {
        guard let tool = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return .failed("\(((candidates.first ?? "") as NSString).lastPathComponent) was not found")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
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
