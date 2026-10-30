import Foundation

/// Remote access via SSH (docs/internals/sync-protocol.md "Remote access via SSH"). The Mac keeps an outbound
/// `ssh -N -R 127.0.0.1:<relayPort>:127.0.0.1:<ingress port>` to a relay host the user already uses; the phone
/// reaches `127.0.0.1:<relayPort>` on that host through its own SSH connection (`direct-tcpip`). The bytes are
/// the same pinned TLS session as on the LAN: SSH is only a pipe and the relay host sees ciphertext.
public enum SyncRemote {
    /// Port on the relay host's loopback that the Mac forwards (the phone's default too).
    public static let defaultRelayPort: UInt16 = 47_824
    /// Host label prefix for connections that came through the SSH forward (rate limits, display).
    public static let peerHostPrefix = "ssh:"
    /// Settings file in the support directory (per instance, so test instances never share the live tunnel).
    public static let settingsFileName = "sync-remote.json"

    /// What the user configured on the Mac.
    public struct Settings: Codable, Equatable, Sendable {
        public var enabled: Bool
        /// A host name or alias from ~/.ssh/config (user, port, key and known host come from there).
        public var host: String
        public var relayPort: UInt16

        public init(enabled: Bool = false, host: String = "", relayPort: UInt16 = SyncRemote.defaultRelayPort) {
            self.enabled = enabled
            self.host = host
            self.relayPort = relayPort
        }

        /// Enabled with a usable host.
        public var isActive: Bool { enabled && SyncRemote.isValidHost(host) && relayPort != 0 }
    }

    /// What remote access shows while no ssh runs: off, no usable host yet, or waiting for the sync listener.
    public enum IdleState: Equatable, Sendable {
        case off, chooseHost, waitingForSync
    }

    public static func idleState(_ settings: Settings) -> IdleState {
        guard settings.enabled else { return .off }
        return settings.isActive ? .waitingForSync : .chooseHost
    }

    /// The ssh a running instance started, kept in the support directory so the next launch can end one left
    /// over from a crash. The process start time is recorded with the pid, so a pid reused by an unrelated ssh
    /// never matches.
    public struct SSHRecord: Equatable, Sendable {
        public var pid: Int32
        public var startSeconds: UInt64
        public var startMicroseconds: UInt64

        public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) {
            self.pid = pid
            self.startSeconds = startSeconds
            self.startMicroseconds = startMicroseconds
        }

        /// `<pid> <start seconds> <start microseconds>`; anything else (including the older pid-only file) is nil.
        public init?(fileText: String) {
            let fields = fileText.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = Int32(fields[0]), pid > 1,
                  let seconds = UInt64(fields[1]), let microseconds = UInt64(fields[2]) else { return nil }
            self.init(pid: pid, startSeconds: seconds, startMicroseconds: microseconds)
        }

        public var fileText: String { "\(pid) \(startSeconds) \(startMicroseconds)\n" }
    }

    /// An ssh destination: `[user@]host` with only host-name characters, never an option (`-…`).
    public static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 255, !host.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_@:[]%")
        return host.unicodeScalars.allSatisfy { allowed.contains($0) } && host.filter({ $0 == "@" }).count <= 1
    }

    /// Arguments for `/usr/bin/ssh`: no shell, no tty, no prompts, keepalives, and exit when the forward cannot
    /// be set up (e.g. the relay port is still held by a previous session), so the caller restarts it.
    public static func sshArguments(settings: Settings, ingressPort: UInt16, configFile: String? = nil) -> [String] {
        var args: [String] = []
        if let configFile { args += ["-F", configFile] }
        args += [
            "-N", "-T",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=15",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "PermitLocalCommand=no",
            "-R", "127.0.0.1:\(settings.relayPort):127.0.0.1:\(ingressPort)",
            "--", settings.host,
        ]
        return args
    }

    /// Delay before restarting ssh after `failures` consecutive failures (2 s doubling to 60 s).
    public static func restartDelay(failures: Int) -> TimeInterval {
        min(60, 2 * pow(2, Double(max(0, min(failures, 10)))))
    }
}
