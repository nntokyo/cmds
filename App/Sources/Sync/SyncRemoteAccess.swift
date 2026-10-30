import CmdsCore
import Darwin
import Foundation

extension Notification.Name {
    /// Posted on main when the remote-access settings or status change.
    static let syncRemoteAccessDidChange = Notification.Name("syncRemoteAccessDidChange")
}

/// Remote access via SSH (docs/internals/sync-protocol.md "Remote access via SSH"). While enabled and the sync listener runs,
/// keeps an outbound `ssh -N -R 127.0.0.1:<relay port>:127.0.0.1:<ingress port> <host>` to a relay host from
/// the user's ssh config, restarting it with backoff. Nothing is exposed publicly: the forward binds the
/// relay's loopback only, and the phone reaches it through its own SSH login to the relay.
///
/// The forward does not point at the sync listener directly: it ends at a loopback "ingress" listener of
/// this app, which relays each connection to the sync listener from a socket registered as peer
/// `ssh:<host>` (`SyncServer.relayedPeers`), exactly like the Bluetooth relay. So the sync server applies
/// every check as for any client, keeps SSH clients apart from other loopback clients for rate limits, and
/// refuses pairing codes from them (pairing stays on the local network).
///
/// Settings live in the support directory (`sync-remote.json`), so isolated test instances never start
/// the live instance's tunnel. `CMDS_SYNC_REMOTE_SSH_CONFIG` (isolated instances only) is passed as `ssh -F`.
@MainActor
final class SyncRemoteAccess {
    static let shared = SyncRemoteAccess()
    /// Relayed connections at most (the sync server has its own, lower per-peer limits).
    static let maxRelays = 16
    /// ssh that stays up this long counts as forwarding (ExitOnForwardFailure exits sooner otherwise).
    static let settleTime: TimeInterval = 4
    static let sshPath = "/usr/bin/ssh"

    private(set) var settings: SyncRemote.Settings
    private(set) var status = LocalizedStatus("Off")
    /// English, for the API and CLI; the UI shows `status.localized`.
    var statusText: String { status.english }
    /// The forward is believed to be up (ssh running past `settleTime`).
    private(set) var isForwarding = false

    private var ingress: SyncLoopback.Server?
    private var relays: [UUID: SyncStreamRelay] = [:]
    private var settingUp = 0
    private var process: Process?
    /// Settings and ports the running ssh was started for.
    private var running: (settings: SyncRemote.Settings, syncPort: UInt16)?
    private var failures = 0
    private var restartTimer: DispatchWorkItem?
    private var settleTimer: DispatchWorkItem?
    private var stderrTail = ""
    private var observer: NSObjectProtocol?

    private let settingsURL = CmdsEnv.supportDirectoryURL().appendingPathComponent(SyncRemote.settingsFileName)
    private let pidURL = CmdsEnv.supportDirectoryURL().appendingPathComponent("sync-remote-ssh.pid")

    private init() {
        settings = (try? Data(contentsOf: settingsURL)).flatMap { try? JSONDecoder().decode(SyncRemote.Settings.self, from: $0) }
            ?? SyncRemote.Settings()
    }

    /// Starts following the sync server (call once at launch).
    func activate() {
        guard observer == nil else { return }
        killStaleSSH()
        observer = NotificationCenter.default.addObserver(forName: .syncServerDidChange, object: SyncServer.shared,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        reconcile()
    }

    func update(_ new: SyncRemote.Settings) {
        guard new != settings else { return }
        settings = new
        save()
        failures = 0
        reconcile()
        didChange()
    }

    /// Host aliases from the ssh config ssh will read (for the host picker).
    var configuredHosts: [String] {
        guard let path = CmdsEnv.remoteSSHConfig() else { return SSHConfigHosts.load() }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return SSHConfigHosts.parse(text).hosts
    }

    /// Stops ssh and every relay (app quit).
    func shutdown() {
        stop(status: LocalizedStatus("Off"))
    }

    // MARK: - Lifecycle

    private var wanted: (settings: SyncRemote.Settings, syncPort: UInt16)? {
        guard settings.isActive, !CmdsEnv.isSyncDisabled(), SyncServer.shared.isEnabled,
              let port = SyncServer.shared.port else { return nil }
        return (settings, port)
    }

    private func reconcile() {
        guard let wanted else {
            if process != nil || ingress != nil || restartTimer != nil {
                stop(status: settings.enabled ? LocalizedStatus("Waiting for iOS Sync") : LocalizedStatus("Off"))
            } else {
                status = settings.enabled ? (settings.isActive ? LocalizedStatus("Waiting for iOS Sync") : LocalizedStatus("Choose a relay host")) : LocalizedStatus("Off")
                didChange()
            }
            return
        }
        if let running, running.settings == wanted.settings, running.syncPort == wanted.syncPort,
           process != nil || restartTimer != nil {
            return
        }
        stop(status: LocalizedStatus("Starting…"))
        start(wanted.settings, syncPort: wanted.syncPort)
    }

    private func start(_ settings: SyncRemote.Settings, syncPort: UInt16) {
        running = (settings, syncPort)
        if ingress == nil {
            do {
                let server = try SyncLoopback.Server()
                let peer = SyncRemote.peerHostPrefix + settings.host
                server.start { [weak self] fd in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self else { Darwin.close(fd); return }
                            self.relay(fd, peer: peer)
                        }
                    }
                }
                ingress = server
            } catch {
                return fail("cannot listen on loopback: \(error)")
            }
        }
        launchSSH()
    }

    private func launchSSH() {
        guard let running, let ingress else { return }
        restartTimer = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sshPath)
        process.arguments = SyncRemote.sshArguments(settings: running.settings, ingressPort: ingress.port,
                                                    configFile: CmdsEnv.remoteSSHConfig())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        stderrTail = ""
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.stderrTail = String((self.stderrTail + text).suffix(600))
                }
            }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.process === finished else { return }
                    self.sshExited(status: status)
                }
            }
        }
        do {
            try process.run()
        } catch {
            return fail("cannot run ssh: \(error.localizedDescription)")
        }
        self.process = process
        try? "\(process.processIdentifier)\n".write(to: pidURL, atomically: true, encoding: .utf8)
        status = LocalizedStatus("Connecting to \(running.settings.host)…")
        isForwarding = false
        syncLog.notice("remote: ssh started for \(running.settings.host, privacy: .public), relay port \(running.settings.relayPort, privacy: .public)")
        let settle = DispatchWorkItem { [weak self] in
            guard let self, self.process === process, process.isRunning else { return }
            self.isForwarding = true
            self.status = LocalizedStatus("Forwarding via \(running.settings.host) (relay 127.0.0.1:\(running.settings.relayPort))")
            self.didChange()
        }
        settleTimer = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleTime, execute: settle)
        didChange()
    }

    private func sshExited(status: Int32) {
        let wasUp = isForwarding
        process = nil
        isForwarding = false
        settleTimer?.cancel()
        settleTimer = nil
        try? FileManager.default.removeItem(at: pidURL)
        failures = wasUp ? 0 : failures + 1
        let detail = stderrTail.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(status)"
        syncLog.notice("remote: ssh exited (\(status, privacy: .public)): \(detail, privacy: .public)")
        guard wanted != nil else { return stop(status: LocalizedStatus("Off")) }
        let delay = SyncRemote.restartDelay(failures: wasUp ? 0 : failures - 1)
        self.status = LocalizedStatus("Disconnected (\(detail)); retrying in \(Int(delay)) s")
        let timer = DispatchWorkItem { [weak self] in self?.launchSSH() }
        restartTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: timer)
        didChange()
    }

    private func stop(status: LocalizedStatus) {
        restartTimer?.cancel()
        restartTimer = nil
        settleTimer?.cancel()
        settleTimer = nil
        if let process {
            self.process = nil
            process.terminationHandler = nil
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: pidURL)
        }
        running = nil
        isForwarding = false
        ingress?.close()
        ingress = nil
        for relay in relays.values { relay.close() }
        relays.removeAll()
        self.status = status
        didChange()
    }

    private func fail(_ reason: String) {
        syncLog.error("remote: \(reason, privacy: .public)")
        stop(status: LocalizedStatus("Failed: \(reason)"))
    }

    // MARK: - Relays

    /// Relays one connection from the forward to the sync listener, from a socket registered as `peer`.
    private func relay(_ fd: Int32, peer: String) {
        guard ingress != nil, let syncPort = running?.syncPort, relays.count + settingUp < Self.maxRelays else {
            syncLog.notice("remote: refusing connection (\(self.relays.count, privacy: .public) open)")
            Darwin.close(fd)
            return
        }
        let id = UUID()
        settingUp += 1
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let socket: Int32
            let release: @Sendable () -> Void
            do {
                (socket, release) = try SyncServer.connectRelay(port: syncPort, peer: peer)
            } catch {
                Darwin.close(fd)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.settingUp -= 1 } }
                return
            }
            let relay = SyncStreamRelay(SyncLoopback.streams(socket: fd), SyncLoopback.streams(socket: socket)) {
                release()

                DispatchQueue.main.async {
                    MainActor.assumeIsolated { _ = self?.relays.removeValue(forKey: id) }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.settingUp -= 1
                    relay.start()
                    guard let self, self.ingress != nil else { return relay.close() }
                    self.relays[id] = relay
                }
            }
        }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: settingsURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    }

    /// An ssh left over from a crash would hold the relay port; end it if it is still our ssh.
    private func killStaleSSH() {
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        try? FileManager.default.removeItem(at: pidURL)
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
              String(cString: buffer) == Self.sshPath, getppid_of(pid) == 1 else { return }
        kill(pid, SIGTERM)
    }

    private func didChange() {
        NotificationCenter.default.post(name: .syncRemoteAccessDidChange, object: self)
    }
}

/// Parent pid of `pid` (1 once its parent died), or -1.
private func getppid_of(_ pid: pid_t) -> pid_t {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return -1 }
    return pid_t(info.pbi_ppid)
}
