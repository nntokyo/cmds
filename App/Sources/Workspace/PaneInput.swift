import AppKit
import CmdsCore
import Darwin

/// Looking at a terminal pane before cmds types into it by itself (a resume command, an account switch's Ctrl-C, a
/// schedule run): the `PaneObservation` the rules in CmdsCore `PaneReadiness` decide on.
extension Pane {
    /// What runs in the foreground of a local pane's terminal, read once its shell has had
    /// `PaneReadiness.localStartDelay` to start. `group` is the process group it was read from; nil when it was not
    /// read (an SSH pane, a terminal still starting or without a process group): the foreground is then `.unknown`.
    func inputForeground(_ terminal: TerminalSurface, now: Date) -> (foreground: PaneForeground, group: pid_t?) {
        guard ssh == nil, now.timeIntervalSince(terminalStartedAt) >= PaneReadiness.localStartDelay,
              let group = terminal.foregroundProcessGroupID else { return (.unknown, nil) }
        return (PaneProcessProbe.foreground(of: group), group)
    }

    /// A Claude Code subagent of the agent here is running.
    var hasRunningSubagent: Bool { subagents.contains { $0.info.state == .running } }

    /// The pane as the typing rules see it: `foreground`, the agent's activity and subagents, and `screen` (its
    /// visible text), tracked in `stability` (how long it has looked like this) and checked for an empty shell prompt.
    /// `agentOnTerminal` is left to the caller (it lists every process).
    func inputObservation(_ terminal: TerminalSurface, screen: String, foreground: PaneForeground,
                          stability: inout ScreenStability, now: Date) -> PaneObservation {
        PaneObservation(foreground: foreground, activity: agentActivity, subagentRunning: hasRunningSubagent,
                        screenUnchangedFor: stability.update(screen, at: now),
                        atEmptyPrompt: PaneReadiness.isAtEmptyPrompt(screen: screen, cursor: terminal.cursorPosition))
    }
}

/// What runs in the foreground of a local pane's terminal.
enum PaneProcessProbe {
    enum Kind { case shell, agent, other }

    /// The process group leader `pid`: a shell, a coding agent (Claude Code / Codex) or something else.
    static func classify(pid: pid_t) -> Kind? {
        guard let info = bsdInfo(pid) else { return nil }
        if isAgent(pid) { return .agent }
        let name = withUnsafeBytes(of: info.pbi_comm) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        let shells = AgentProcessClassifier.shells.subtracting(["env", "timeout", "nice", "nohup"])
        let base = name.hasPrefix("-") ? String(name.dropFirst()) : name // login shells: `-zsh`
        return shells.contains(base) ? .shell : .other
    }

    /// The process's short name as Activity Monitor shows it ("vim", "node"); nil when it cannot be read. Never its
    /// arguments (they may hold secrets; the assistant says this name aloud).
    static func name(of pid: pid_t) -> String? {
        guard let info = bsdInfo(pid) else { return nil }
        func string<T>(_ value: T) -> String {
            withUnsafeBytes(of: value) { raw in String(cString: raw.bindMemory(to: CChar.self).baseAddress!) }
        }
        let name = string(info.pbi_name).isEmpty ? string(info.pbi_comm) : string(info.pbi_name)
        let base = name.hasPrefix("-") ? String(name.dropFirst()) : name
        return base.isEmpty ? nil : base
    }

    /// `classify` for the typing rules: `.unknown` when the process cannot be read.
    static func foreground(of pid: pid_t) -> PaneForeground {
        switch classify(pid: pid) {
        case .shell?: return .shell
        case .agent?: return .agent
        case .other?: return .other
        case nil: return .unknown
        }
    }

    /// Any Claude Code / Codex process on the same terminal as `pid` (also backgrounded ones).
    static func agentOnTerminal(of pid: pid_t) -> Bool {
        guard let info = kinfo(pid), info.kp_eproc.e_tdev != -1 else { return false }
        let tty = info.kp_eproc.e_tdev
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        for candidate in pids.prefix(Int(max(0, count))) where candidate > 0 {
            guard let other = kinfo(candidate), other.kp_eproc.e_tdev == tty else { continue }
            if isAgent(candidate) { return true }
        }
        return false
    }

    /// A Claude Code process: when it started and the `CLAUDE_CONFIG_DIR` it was started with (nil: not set).
    struct ClaudeProcess: Equatable {
        var pid: pid_t
        var startedAt: Date
        var configDir: String?
    }

    /// The Claude Code process on the same terminal as `pid`: `pid` itself when it is one (a plain `claude` leads its
    /// process group), else the oldest one on that terminal unless `foregroundOnly`.
    static func claudeProcess(onTerminalOf pid: pid_t, foregroundOnly: Bool = false) -> ClaudeProcess? {
        if agentKind(of: pid) == .claude { return claudeProcess(pid) }
        guard !foregroundOnly, let info = kinfo(pid), info.kp_eproc.e_tdev != -1 else { return nil }
        let tty = info.kp_eproc.e_tdev
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var found: ClaudeProcess?
        for candidate in pids.prefix(Int(max(0, count))) where candidate > 0 {
            guard let other = kinfo(candidate), other.kp_eproc.e_tdev == tty, agentKind(of: candidate) == .claude,
                  let process = claudeProcess(candidate) else { continue }
            if found == nil || process.startedAt < found!.startedAt { found = process }
        }
        return found
    }

    private static func claudeProcess(_ pid: pid_t) -> ClaudeProcess? {
        guard let info = kinfo(pid) else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let startedAt = Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
        let variable = ClaudeAccounts.configDirVariable
        let configDir = environment(pid, names: [variable])[variable].flatMap { $0.isEmpty ? nil : $0 }
        return ClaudeProcess(pid: pid, startedAt: startedAt, configDir: configDir)
    }

    private static func isAgent(_ pid: pid_t) -> Bool { agentKind(of: pid) != nil }

    /// The coding agent `pid` is: Claude Code, a Codex session (not one of its helper commands), Antigravity, or nil.
    static func agentKind(of pid: pid_t) -> AgentKind? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let executable = proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? String(cString: path) : ""
        let arguments = arguments(pid)
        switch AgentProcessClassifier.agent(executablePath: executable, arguments: arguments) {
        case .claude?: return .claude
        case .codex?: return AgentProcessClassifier.codexRole(arguments: arguments) == .session ? .codex : nil
        case .antigravity?: return .antigravity
        default: return nil
        }
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// When the process started (the foreground group's leader: the agent its shell started).
    static func startDate(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.startMicroseconds) / 1_000_000)
    }

    private static func kinfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    /// The variables `names` of the process's environment (its own processes only, as for `arguments`).
    private static func environment(_ pid: pid_t, names: [String]) -> [String: String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 256 * 1024
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [:] }
        return buffer.withUnsafeBytes { raw in
            ProcessArguments.parse(UnsafeRawBufferPointer(rebasing: raw[0..<size]), maxArguments: 0,
                                   environmentNames: names)?.environment ?? [:]
        }
    }

    private static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return buffer.withUnsafeBytes { raw in
            ProcessArguments.parse(UnsafeRawBufferPointer(rebasing: raw[0..<size]))?.arguments ?? []
        }
    }
}
