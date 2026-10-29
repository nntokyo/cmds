import CmdsCore
import Darwin
import Foundation

/// `cmds hook claude-status`: Claude Code status-line JSON on stdin → `agent.report` for $CMDS_PANE_ID.
/// Prints nothing, never fails and never waits for the app: stdin is read with a deadline and the request is
/// written without waiting for the reply (the app still handles a request whose client has closed).
enum AgentHook {
    static let stdinDeadline: TimeInterval = 0.15
    static let maxInput = 1024 * 1024

    static func claudeStatus(_ ctx: Context) {
        guard let pane = ctx.envPane else { return } // not inside cmds
        let input = readStandardInput(deadline: Date().addingTimeInterval(stdinDeadline))
        guard let usage = ClaudeStatusLine.usage(fromJSON: input) else { return }
        var params: [String: JSONValue] = ["pane": .string(pane)]
        params["usage"] = try? JSONValue.from(usage)
        guard params["usage"] != nil else { return }
        if let pid = agentProcessID() { params["pid"] = .number(Double(pid)) }
        post(socketPath: ctx.socketPath, method: "agent.report", params: .object(params))
    }

    /// Writes one request and closes; errors (no app, old app) are ignored.
    static func post(socketPath: String, method: String, params: JSONValue) {
        guard let fd = try? UnixSocket.makeStreamSocket() else { return }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard (try? UnixSocket.connect(fd, path: socketPath)) != nil,
              let line = try? JSONLineBuffer.encodeLine(RPCRequest(id: 1, method: method, params: params)) else { return }
        try? UnixSocket.writeAll(fd, line)
        shutdown(fd, SHUT_WR)
    }

    /// Reads stdin until EOF, `maxInput` bytes or the deadline.
    static func readStandardInput(deadline: Date) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < maxInput {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            var poller = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(max(1, remaining * 1000)))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { break }
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    /// Claude Code's pid: the nearest ancestor recognised as Claude, else the nearest one that is not a shell
    /// (the status line runs as `claude → sh → bash statusline.sh → cmds`). The app drops the pane's usage once it exits.
    static func agentProcessID() -> pid_t? {
        var pid = getppid()
        var fallback: pid_t?
        for _ in 0..<8 {
            guard pid > 1, let info = processInfo(pid) else { break }
            if info.agent == .claude { return pid }
            if fallback == nil, !AgentProcessClassifier.shells.contains(info.name) { fallback = pid }
            pid = info.parent
        }
        return fallback
    }

    private static func processInfo(_ pid: pid_t) -> (name: String, parent: pid_t, agent: AgentKind?)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: &info.pbi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let executable = proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? String(cString: path) : ""
        let arguments = processArguments(pid)
        let agent = AgentProcessClassifier.agent(executablePath: executable, arguments: arguments)
        return (name, pid_t(bitPattern: info.pbi_ppid), agent)
    }

    private static func processArguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 256 * 1024
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return buffer.withUnsafeBytes { raw in
            ProcessArguments.parse(UnsafeRawBufferPointer(rebasing: raw[0..<size]))?.arguments ?? []
        }
    }
}
