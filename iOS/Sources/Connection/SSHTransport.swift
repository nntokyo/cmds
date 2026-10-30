import CmdsCore
import CmdsSSH
import CryptoKit
import Foundation

/// Remote access via SSH (docs/internals/sync-protocol.md "Remote access via SSH"): logs in to the relay host with the phone's
/// Ed25519 key (host key pinned), opens a `direct-tcpip` channel to the port the Mac forwards there and
/// connects the usual `WebSocketTransport` through a loopback listener, pinned to the same Mac certificate.
/// SSH is only the pipe: the relay host sees the TLS session's ciphertext, and nothing is sent to the Mac
/// before its certificate matched the pin.
///
/// Only for pinned connections with a usable `RemoteAccessConfig`. Main thread only (`@unchecked Sendable`
/// so the tunnel's close callback can hop back to main).
final class SSHTransport: SyncTransport, @unchecked Sendable {
    var onEvent: ((TransportEvent) -> Void)?
    var linkPath: SyncLinkPath { .ssh }

    private let config: RemoteAccessConfig
    private let hostKey: String
    private let key: Curve25519.Signing.PrivateKey
    private let policy: SyncTLS.PeerPolicy
    private var task: Task<Void, Never>?
    private var tunnel: SSHTunnel?
    private var inner: WebSocketTransport?
    private var finished = false

    /// Nil unless `policy` pins a certificate and remote access is set up for `targetID`.
    init?(targetID: String, policy: SyncTLS.PeerPolicy) {
        guard case .pinned = policy, let config = RemoteAccessStore.config(for: targetID), config.isUsable,
              let hostKey = config.pinnedHostKey, let key = PhoneSSHKey.load() else { return nil }
        self.config = config
        self.hostKey = hostKey
        self.key = key
        self.policy = policy
    }

    static func isAvailable(targetID: String) -> Bool {
        RemoteAccessStore.config(for: targetID)?.isUsable == true
    }

    func start() {
        let endpoint = config.endpoint
        let hostKey = hostKey
        let key = key
        ConnectionDiagnostics.shared.stage(.ssh, "connecting to the relay host")
        task = Task { @MainActor [weak self] in
            do {
                let tunnel = try await SSHTunnel.connect(to: endpoint, key: key, hostKeyPin: hostKey)
                guard let self, !self.finished else { return tunnel.close() }
                self.tunnel = tunnel
                ConnectionDiagnostics.shared.stage(.ssh, "relay login ok, opening the forward")
                let port = try await tunnel.openForward()
                guard !self.finished else { return }
                ConnectionDiagnostics.shared.stage(.ssh, "forward open, TLS handshake")
                tunnel.closeFuture.whenComplete { _ in
                    DispatchQueue.main.async { [weak self] in
                        self?.fail(String(localized: "The SSH connection to the relay host closed."))
                    }
                }
                let inner = WebSocketTransport(target: MacTarget(kind: .manual(host: "127.0.0.1", port: port),
                                                                 displayName: "SSH"),
                                               policy: self.policy)
                self.inner = inner
                inner.onEvent = { [weak self] event in self?.forward(event) }
                inner.start()
            } catch {
                self?.fail((error as? SSHTunnelError)?.localizedText ?? error.localizedDescription)
            }
        }
    }

    func send(_ message: ClientMessage) {
        inner?.send(message)
    }

    func close() {
        guard !finished else { return }
        finished = true
        onEvent = nil
        teardown()
    }

    private func teardown() {
        task?.cancel()
        task = nil
        inner?.onEvent = nil
        inner?.close()
        inner = nil
        tunnel?.close()
        tunnel = nil
    }

    private func fail(_ reason: String) {
        guard !finished else { return }
        finished = true
        let handler = onEvent
        onEvent = nil
        teardown()
        handler?(.disconnected(reason: reason))
    }

    private func forward(_ event: TransportEvent) {
        guard !finished else { return }
        switch event {
        case .connected, .message:
            onEvent?(event)
        case .identityPresented, .identityMismatch, .disconnected:
            finished = true
            let handler = onEvent
            onEvent = nil
            teardown()
            handler?(event)
        }
    }
}
