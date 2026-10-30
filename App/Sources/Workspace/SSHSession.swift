import Foundation
import CmdsCore
import os

private let sshLog = Logger(subsystem: "tokyo.n-n.cmds", category: "ssh")

extension SSHLaunch {
    /// `SSHLaunch(host:remoteCwd:)` with validation errors as `invalidParams`.
    static func checked(host: String, remoteCwd: String?) throws -> SSHLaunch {
        do {
            return try SSHLaunch(host: host, remoteCwd: remoteCwd)
        } catch let error as SSHLaunch.InvalidInput {
            throw RPCError.invalidParams(error.description)
        }
    }
}

/// State of an SSH pane (docs/internals/ssh.md): what to run, its own restricted API socket, connection state and what the
/// remote shell reported (branch). The pane's terminal surface is replaced on every (re)connect; this object and
/// the local socket live as long as the pane.
@MainActor
final class SSHSession {
    let launch: SSHLaunch
    /// Per-pane socket that `ssh -R` forwards to the server. Served by a scoped `APIServer`.
    let localSocketPath: String
    /// The remote socket of the current connection (fresh per connection).
    private(set) var remoteSocketPath: String?
    private(set) var connected = false
    /// Branch of the remote cwd from `cmds-remote.sh prompt`; cleared when the cwd changes without one.
    var remoteBranch: String?
    private var api: APIServer?

    init(launch: SSHLaunch, paneID: String) {
        self.launch = launch
        localSocketPath = Self.localSocketPath(paneID: paneID)
    }

    /// Longest local socket path used (bytes); `sockaddr_un.sun_path` holds 104 including the terminator.
    static let maxSocketPathBytes = 100

    /// `<support dir>/ssh/<pane>.sock` (directory 0700), or under the per-user temporary directory when that path
    /// is too long for a Unix socket. The path must not contain `:` (it is part of the `-R` argument).
    static func localSocketPath(paneID: String) -> String {
        let name = "\(paneID).sock"
        let preferred = CmdsEnv.supportDirectoryURL().appendingPathComponent("ssh", isDirectory: true).path
        let fallback = (NSTemporaryDirectory() as NSString).appendingPathComponent("cmds-ssh")
        for directory in [preferred, fallback] {
            let path = (directory as NSString).appendingPathComponent(name)
            if path.utf8.count < maxSocketPathBytes, !path.contains(":") { return path }

        }
        return "/tmp/cmds-ssh-\(getuid())-\(name)"
    }

    /// Starts the scoped API server (once). Returns false if the socket could not be created.
    @discardableResult
    func startAPI(controller: AppController, scope: RemoteScope) -> Bool {
        if api != nil { return true }
        let directory = (localSocketPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            chmod(directory, 0o700)
        } catch {
            sshLog.error("cannot create \(directory, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        let server = APIServer(controller: controller, path: localSocketPath, scope: scope)
        guard server.start() else { return false }
        api = server
        return true
    }

    func stopAPI() {
        api?.stop()
        api = nil
    }

    /// Launch configuration for a new connection (a fresh remote socket path each time).
    func makeLaunchConfig(paneID: String, workspaceID: String, environment: [String: String]) -> TerminalLaunchConfig {
        let remote = SSHLaunch.makeRemoteSocketPath()
        remoteSocketPath = remote
        let command = launch.localCommand(paneID: paneID, workspaceID: workspaceID, localSocket: localSocketPath,
                                          remoteSocket: remote)
        return TerminalLaunchConfig(workingDirectory: NSHomeDirectory(), command: command, environment: environment,
                                    waitAfterCommand: true)
    }

    func didConnect() { connected = true }

    func didDisconnect() {
        connected = false
        remoteSocketPath = nil
    }
}
