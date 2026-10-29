import CmdsCore
import Foundation
import Network

/// Prefers the network (Bonjour/address over Wi‑Fi, Ethernet or peer-to-peer Wi‑Fi) and falls back to
/// Bluetooth (docs/SYNC.md "Bluetooth"): the Bluetooth attempt starts when the network attempt has not
/// connected after `fallbackDelay`, when it fails, or at once when the phone has no Wi‑Fi. The first
/// attempt that completes the pinned TLS handshake wins and the other is closed.
///
/// Both attempts are pinned to the same certificate and nothing is sent on either before it is
/// `.connected`, so racing them is safe. A refused certificate (`.identityMismatch`) on either ends the
/// whole connection: it is never worked around by trying the other path.
final class FallbackTransport: SyncTransport {
    static let fallbackDelay: TimeInterval = 3

    var onEvent: ((TransportEvent) -> Void)?
    private(set) var linkPath: SyncLinkPath = .network

    private let target: MacTarget
    private let policy: SyncTLS.PeerPolicy
    private var network: SyncTransport?
    private var bluetooth: SyncTransport?
    private var winner: SyncTransport?
    private var bluetoothStarted = false
    private var networkFailure: String?
    private var bluetoothFailure: String?
    private var fallbackTimer: DispatchWorkItem?
    private var finished = false

    init(target: MacTarget, policy: SyncTLS.PeerPolicy) {
        self.target = target
        self.policy = policy
    }

    /// Bluetooth carries only pinned connections (the manual-pairing probe needs the Mac's address).
    private var canUseBluetooth: Bool {
        guard case .pinned = policy else { return false }
        return true
    }

    func start() {
        let network = WebSocketTransport(target: target, policy: policy)
        self.network = network
        wire(network)
        network.start()
        guard canUseBluetooth else { return }
        let delay = NetworkPathMonitor.shared.hasLocalNetwork ? Self.fallbackDelay : 0
        let timer = DispatchWorkItem { [weak self] in self?.startBluetooth() }
        fallbackTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: timer)
    }

    func send(_ message: ClientMessage) {
        winner?.send(message)
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
        guard let bluetooth = BluetoothTransport(policy: policy) else { return }
        self.bluetooth = bluetooth
        wire(bluetooth)
        bluetooth.start()
    }

    private func handle(_ event: TransportEvent, from transport: SyncTransport) {
        guard !finished else { return }
        switch event {
        case .connected:
            guard winner == nil else { return }
            winner = transport
            linkPath = transport.linkPath
            fallbackTimer?.cancel()
            for other in [network, bluetooth] where other !== transport {
                other?.onEvent = nil
                other?.close()
            }
            if transport === network { bluetooth = nil } else { network = nil }
            onEvent?(.connected)
        case .message:
            if transport === winner { onEvent?(event) }
        case .identityPresented, .identityMismatch:
            finish(with: event)
        case .disconnected(let reason):
            if transport === winner { return finish(with: event) }
            if transport === network {
                network = nil
                networkFailure = reason
                // The network path failed outright: no reason to wait for the timer.
                if !bluetoothStarted, canUseBluetooth {
                    fallbackTimer?.cancel()
                    startBluetooth()
                }
            } else if transport === bluetooth {
                bluetooth = nil
                bluetoothFailure = reason
            }
            if network == nil, bluetooth == nil {
                let reasons = [networkFailure, bluetoothFailure.map { String(localized: "Bluetooth: \($0)") }].compactMap { $0 }
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
        for transport in [network, bluetooth, winner] {
            transport?.onEvent = nil
            transport?.close()
        }
        network = nil
        bluetooth = nil
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
