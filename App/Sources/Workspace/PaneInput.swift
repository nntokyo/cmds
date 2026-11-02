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

    private static func isAgent(_ pid: pid_t) -> Bool { agentKind(of: pid) != nil }

    /// The coding agent `pid` is: Claude Code, a Codex session (not one of its helper commands), or nil.
    static func agentKind(of pid: pid_t) -> AgentKind? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let executable = proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? String(cString: path) : ""
        let arguments = arguments(pid)
        switch AgentProcessClassifier.agent(executablePath: executable, arguments: arguments) {
        case .claude?: return .claude
        case .codex?: return AgentProcessClassifier.codexRole(arguments: arguments) == .session ? .codex : nil
        default: return nil
        }
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    private static func kinfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
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
