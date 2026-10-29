import CmdsCore
import Foundation
import Network

/// Prefers the network (Bonjour/address over Wi‑Fi, Ethernet or peer-to-peer Wi‑Fi), then Bluetooth
/// (docs/SYNC.md "Bluetooth"), then remote access via SSH if it is set up for this Mac ("Remote access via
/// SSH"). The Bluetooth attempt starts when the network attempt has not connected after `fallbackDelay`,
/// when it fails, or at once when the phone has no Wi‑Fi. The SSH attempt starts after `sshDelay`, when
/// every nearby path has failed, or at once when the phone has no Wi‑Fi. The first attempt that completes
/// the pinned TLS handshake wins and the others are closed.
///
/// All attempts are pinned to the same certificate and nothing is sent on any before it is `.connected`,
/// so racing them is safe. A refused certificate (`.identityMismatch`) on any ends the whole connection:
/// it is never worked around by trying another path.
///
/// `mode` (debug builds, `TransportMode`) restricts the attempt to one path: `.bluetooth` and `.ssh` start
/// only that transport at once, `.network` never falls back. The pin check is the same in every mode.
final class FallbackTransport: SyncTransport {
    static let fallbackDelay: TimeInterval = 3
    static let sshDelay: TimeInterval = 6

    var onEvent: ((TransportEvent) -> Void)?
    private(set) var linkPath: SyncLinkPath = .network

    private let target: MacTarget
    private let policy: SyncTLS.PeerPolicy
    private let mode: TransportMode
    private let diagnostics = ConnectionDiagnostics.shared
    private var network: SyncTransport?
    private var bluetooth: SyncTransport?
    private var ssh: SyncTransport?
    private var winner: SyncTransport?
    private var bluetoothStarted = false
    private var sshStarted = false
    private var networkFailure: String?
    private var bluetoothFailure: String?
    private var sshFailure: String?
    private var fallbackTimer: DispatchWorkItem?
    private var sshTimer: DispatchWorkItem?
    private var finished = false

    init(target: MacTarget, policy: SyncTLS.PeerPolicy, mode: TransportMode = .auto) {
        self.target = target
        self.policy = policy
        self.mode = mode
    }

    /// Bluetooth carries only pinned connections (the manual-pairing probe needs the Mac's address).
    private var canUseBluetooth: Bool {
        guard mode == .auto || mode == .bluetooth, case .pinned = policy else { return false }
        return true
    }

    /// SSH: pinned connections to a Mac with remote access set up on this phone.
    private lazy var canUseSSH: Bool = {
        guard mode == .auto || mode == .ssh, case .pinned = policy else { return false }
        return SSHTransport.isAvailable(targetID: target.id)
    }()

    func start() {
        switch mode {
        case .auto, .network:
            break
        case .bluetooth:
            return startOnly(.bluetooth, possible: canUseBluetooth, unavailable: "forced transport bluetooth: "
                + "not possible for this connection (pairing without a QR code needs the network)")
        case .ssh:
            return startOnly(.ssh, possible: canUseSSH, unavailable: "forced transport ssh: "
                + "remote access via SSH is not set up for this Mac on this phone")
        }
        diagnostics.stage(.network, "connecting")
        let network = WebSocketTransport(target: target, policy: policy)
        self.network = network
        wire(network)
        network.start()
        guard mode == .auto, canUseBluetooth else { return }
        let nearby = NetworkPathMonitor.shared.hasLocalNetwork
        let timer = DispatchWorkItem { [weak self] in self?.startBluetooth() }
        fallbackTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + (nearby ? Self.fallbackDelay : 0), execute: timer)
        guard canUseSSH else { return }
        let sshTimer = DispatchWorkItem { [weak self] in self?.startSSH() }
        self.sshTimer = sshTimer
        DispatchQueue.main.asyncAfter(deadline: .now() + (nearby ? Self.sshDelay : 0), execute: sshTimer)
    }

    func send(_ message: ClientMessage) {
        winner?.send(message)
    }

    /// Forced mode: start that one transport now, or report why it cannot run (asynchronously, like any
    /// other failure).
    private func startOnly(_ path: SyncLinkPath, possible: Bool, unavailable: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.finished else { return }
            guard possible else {
                self.diagnostics.failed(path, unavailable)
                return self.finish(with: .disconnected(reason: unavailable))
            }
            path == .ssh ? self.startSSH() : self.startBluetooth()
            // Could not even start (the reason is recorded); a transport that failed while starting has
            // already finished this one through `handle`.
            if !self.finished, self.network == nil, self.bluetooth == nil, self.ssh == nil {
                self.finish(with: .disconnected(reason: self.bluetoothFailure ?? self.sshFailure ?? unavailable))
            }
        }
    }

    func close() {
        guard !finished else { return }
        finished = true
        onEvent = nil
        closeAll()
    }

    private func wire(_ transport: SyncTransport) {
        transport.onEvent = { [weak self, weak transport] event in
            guard let self, let transport else { return }
            self.handle(event, from: transport)
        }
    }

    private func startBluetooth() {
        guard !finished, winner == nil, !bluetoothStarted, canUseBluetooth else { return }
        bluetoothStarted = true
        guard let bluetooth = BluetoothTransport(policy: policy) else {
            bluetoothFailure = "Bluetooth needs a pinned connection"
            diagnostics.failed(.bluetooth, bluetoothFailure ?? "")
            return
        }
        self.bluetooth = bluetooth
        wire(bluetooth)
        bluetooth.start()
    }

    private func startSSH() {
        guard !finished, winner == nil, !sshStarted, canUseSSH else { return }
        sshStarted = true
        guard let ssh = SSHTransport(targetID: target.id, policy: policy) else {
            sshFailure = "remote access is not set up completely (relay host key or phone key missing)"
            diagnostics.failed(.ssh, sshFailure ?? "")
            return
        }
        self.ssh = ssh
        wire(ssh)
        ssh.start()
    }

    private func handle(_ event: TransportEvent, from transport: SyncTransport) {
        guard !finished else { return }
        switch event {
        case .connected:
            guard winner == nil else { return }
            winner = transport
            linkPath = transport.linkPath
            diagnostics.stage(transport.linkPath, "TLS ok")
            fallbackTimer?.cancel()
            sshTimer?.cancel()
            for other in [network, bluetooth, ssh] where other !== transport {
                other?.onEvent = nil
                other?.close()
            }
            if transport !== network { network = nil }
            if transport !== bluetooth { bluetooth = nil }
            if transport !== ssh { ssh = nil }
            onEvent?(.connected)
        case .message:
            if transport === winner { onEvent?(event) }
        case .identityPresented:
            finish(with: event)
        case .identityMismatch:
            diagnostics.failed(transport.linkPath, "TLS: the Mac's certificate does not match the pin")
            finish(with: event)
        case .disconnected(let reason):
            if let reason { diagnostics.failed(transport.linkPath, reason) }
            if transport === winner { return finish(with: event) }
            if transport === network {
                network = nil
                networkFailure = reason
                // The network path failed outright: no reason to wait for the timer.
                if mode == .auto, !bluetoothStarted, canUseBluetooth {
                    fallbackTimer?.cancel()
                    startBluetooth()
                }
            } else if transport === bluetooth {
                bluetooth = nil
                bluetoothFailure = reason
            } else if transport === ssh {
                ssh = nil
                sshFailure = reason
            }
            // Nothing nearby is left: no reason to wait for the SSH timer.
            if mode == .auto, network == nil, bluetooth == nil, !sshStarted, canUseSSH {
                sshTimer?.cancel()
                startSSH()
            }
            if network == nil, bluetooth == nil, ssh == nil {
                let reasons = [networkFailure,
                               bluetoothFailure.map { String(localized: "Bluetooth: \($0)") },
                               sshFailure.map { String(localized: "SSH: \($0)") }].compactMap { $0 }
                finish(with: .disconnected(reason: reasons.isEmpty ? nil : reasons.joined(separator: "\n")))
            }
        }
    }

    private func finish(with event: TransportEvent) {
        guard !finished else { return }
        finished = true
        let handler = onEvent
        onEvent = nil
        closeAll()
        handler?(event)
    }

    private func closeAll() {
        fallbackTimer?.cancel()
        fallbackTimer = nil
        sshTimer?.cancel()
        sshTimer = nil
        for transport in [network, bluetooth, ssh, winner] {
            transport?.onEvent = nil
            transport?.close()
        }
        network = nil
        bluetooth = nil
        ssh = nil
        winner = nil
    }
}

/// Whether the phone currently has Wi‑Fi or Ethernet (unknown counts as yes).
final class NetworkPathMonitor: @unchecked Sendable {
    static let shared = NetworkPathMonitor()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var path: NWPath?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.path = path
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "tokyo.n-n.cmds.companion.path"))
    }

    var hasLocalNetwork: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let path else { return true }
        return path.availableInterfaces.contains { $0.type == .wifi || $0.type == .wiredEthernet }
    }
}
