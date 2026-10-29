import Foundation

/// Remote access via SSH (docs/SYNC.md "Remote access via SSH"). The Mac keeps an outbound
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
