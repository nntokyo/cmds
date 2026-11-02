import Foundation

/// How cmds reaches a server's files (docs/internals/files-sftp.md): the user's own `ssh` with the `sftp` subsystem,
/// never prompting, host keys checked strictly, never becoming a `ControlMaster`.
public enum SSHFileCommand {
    public static let sshPath = "/usr/bin/ssh"

    /// Arguments for `ssh` (`configFile` only for isolated test instances: `-F`). The host comes after `--`, so it can
    /// never be read as an option (it is also validated by `SSHLaunch.validateHost`).
    public static func arguments(host: String, configFile: String? = nil) -> [String] {
        var args: [String] = []
        if let configFile { args += ["-F", configFile] }
        args += [
            "-T",
            // Never prompt: no password, no passphrase, no host key question. Password-only hosts are refused.
            "-o", "BatchMode=yes",
            // Unknown hosts are refused and never added to known_hosts; a changed key is refused.
            "-o", "StrictHostKeyChecking=yes",
            // Reuse the user's master connection if one is up, but never become one (closing a files pane must not
            // cut terminals multiplexed through it).
            "-o", "ControlMaster=no",
            // Settings meant for interactive logins do not apply to a file connection.
            "-o", "RemoteCommand=none",
            "-o", "ClearAllForwardings=yes",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "PermitLocalCommand=no",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=15",
            "-s", "--", host, "sftp",
        ]
        return args
    }
}

/// Why `ssh` could not connect, from its stderr, so the pane can say what to do.
public enum SSHFailure: Equatable, Sendable {
    /// The server wants a password (or a key passphrase that is not in the agent): cmds only uses keys and the agent.
    case authentication
    /// The host is not in known_hosts; cmds does not add it.
    case unknownHostKey
    /// The host key differs from known_hosts.
    case changedHostKey
    case unresolvedHost
    case refused
    case timedOut
    /// The server has no sftp subsystem.
    case noSFTP
    /// Anything else: ssh's last line of stderr (or the exit status).
    case other(String)

    public static func classify(stderr: String, status: Int32?) -> SSHFailure {
        let text = stderr.lowercased()
        if text.contains("remote host identification has changed") || text.contains("host key for")
            && text.contains("has changed") {
            return .changedHostKey
        }
        if text.contains("host key is known for") || text.contains("host key verification failed")
            || text.contains("no ed25519 host key") || text.contains("no rsa host key") || text.contains("no ecdsa host key") {
            return .unknownHostKey
        }
        if text.contains("permission denied") || text.contains("too many authentication failures") {
            return .authentication
        }
        if text.contains("could not resolve hostname") || text.contains("name or service not known")
            || text.contains("nodename nor servname") {
            return .unresolvedHost
        }
        if text.contains("connection refused") { return .refused }
        if text.contains("timed out") { return .timedOut }
        if text.contains("subsystem request failed") { return .noSFTP }
        let last = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        if let last { return .other(last) }
        return .other(status.map { "ssh exited with status \($0)" } ?? "ssh exited")
    }

    /// The classified failure whose `description` this is (a dropped connection's reason, `SFTPError.disconnected`),
    /// so the app can show its own text; nil for anything else (ssh's own last line).
    public init?(description: String) {
        let known: [SSHFailure] = [.authentication, .unknownHostKey, .changedHostKey, .unresolvedHost, .refused,
                                   .timedOut, .noSFTP]
        guard let failure = known.first(where: { $0.description == description }) else { return nil }
        self = failure
    }

    /// English text (API, CLI, logs); the app shows its own localized text for each case.
    public var description: String {
        switch self {
        case .authentication:
            return "The server did not accept a key from your ssh keys or agent. cmds never asks for passwords: add a key "
                + "for this host (e.g. ssh-copy-id), or add a passphrase-protected key to the agent (ssh-add)."
        case .unknownHostKey:
            return "The host key of this server is not known. Connect to it once in an SSH workspace (or a terminal) to "
                + "check and accept its key; cmds never adds host keys by itself."
        case .changedHostKey:
            return "The host key of this server has changed since it was saved in known_hosts. Someone may be "
                + "intercepting the connection; check the key before connecting again."
        case .unresolvedHost: return "The host name could not be resolved."
        case .refused: return "The server refused the connection."
        case .timedOut: return "The connection timed out."
        case .noSFTP: return "The server does not offer SFTP (no sftp subsystem)."
        case .other(let message): return message
        }
    }
}

/// ssh could not connect (`failure` says why).
public struct SSHConnectError: Error, CustomStringConvertible, Equatable {
    public var failure: SSHFailure
    public init(failure: SSHFailure) { self.failure = failure }
    public var description: String { failure.description }
}

/// Characters of `ssh`'s stderr kept to explain a failure.
private let stderrLimit = 4000

#if os(macOS)
/// One `ssh -s HOST sftp` process and the SFTP client talking over its stdin/stdout.
public final class SSHFileConnection: @unchecked Sendable {
    public let host: String
    public let client: SFTPClient
    /// The login folder (the home folder on OpenSSH), absolute.
    public let home: String
    private let process: Process
    private let errors: ErrorBuffer

    /// Starts ssh and the SFTP handshake (blocks the calling thread; never call it on the main thread). Throws
    /// `SSHConnectError` when ssh cannot connect.
    public init(host: String, configFile: String? = nil, executable: String = SSHFileCommand.sshPath) throws {
        self.host = host
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = SSHFileCommand.arguments(host: host, configFile: configFile)
        let input = Pipe()
        let output = Pipe()
        let errorPipe = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe
        let errors = ErrorBuffer()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                errors.finishStderr()
            } else {
                errors.append(chunk)
            }
        }
        process.terminationHandler = { finished in errors.exited(finished.terminationStatus) }
        try process.run()
        let transport = FileDescriptorTransport(readFD: dup(output.fileHandleForReading.fileDescriptor),
                                                writeFD: dup(input.fileHandleForWriting.fileDescriptor))
        try? output.fileHandleForReading.close()
        try? input.fileHandleForWriting.close()
        transport.reasonProvider = { errors.reason() }
        self.process = process
        self.errors = errors
        client = SFTPClient(transport: transport)
        do {
            try client.start()
            home = try client.realpath(".")
        } catch SFTPError.disconnected {
            if process.isRunning { process.terminate() }
            throw SSHConnectError(failure: errors.failure())
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
    }

    /// The process is still running and the client connected.
    public var isConnected: Bool { process.isRunning && client.isConnected }

    /// Ends the connection (terminates ssh; requests in flight fail).
    public func close() {
        if process.isRunning { process.terminate() }
        client.disconnect()
    }

    /// ssh's stderr and exit status, collected off the main thread.
    private final class ErrorBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        private var status: Int32?
        private let done = DispatchSemaphore(value: 0)
        private var stderrDone = false

        func append(_ chunk: Data) {
            lock.lock()
            text = String((text + String(decoding: chunk, as: UTF8.self)).suffix(stderrLimit))
            lock.unlock()
        }

        func finishStderr() {
            lock.lock()
            stderrDone = true
            lock.unlock()
        }

        func exited(_ code: Int32) {
            lock.lock()
            status = code
            lock.unlock()
            done.signal()
        }

        /// How long to wait for ssh to exit once its stdout has closed.
        static let exitWait: TimeInterval = 3
        /// Then up to `stderrPolls` × `stderrPollMicroseconds` (0.5 s) for the rest of its stderr.
        static let stderrPolls = 20
        static let stderrPollMicroseconds: useconds_t = 25_000

        func reason() -> String { failure().description }

        /// Waits briefly for ssh to exit (its stdout closes first), then classifies what it printed.
        func failure() -> SSHFailure {
            _ = done.wait(timeout: .now() + Self.exitWait)
            done.signal()
            // stderr may still be draining right after the exit.
            for _ in 0..<Self.stderrPolls {
                lock.lock()
                let finished = stderrDone
                lock.unlock()
                if finished { break }
                usleep(Self.stderrPollMicroseconds)
            }
            lock.lock()
            defer { lock.unlock() }
            return SSHFailure.classify(stderr: text, status: status)
        }
    }
}
#endif
