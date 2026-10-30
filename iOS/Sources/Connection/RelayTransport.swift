import CmdsCore
import Foundation

/// A path that relays a local loopback port to the Mac (`BluetoothTransport`, `SSHTransport`) and runs the
/// usual `WebSocketTransport` through it, pinned exactly as over the network: the relay is only a pipe,
/// and nothing is sent before the Mac's certificate matched the pin.
///
/// Conformers keep `finished` and `inner` for the shared parts below and release their own resources in
/// `teardown()`. Main thread only.
protocol RelayTransport: SyncTransport {
    /// Set once the transport closed or reported its end; no event is delivered after it.
    var finished: Bool { get set }
    /// The pinned WebSocket connection over the relay, once the relay is up.
    var inner: WebSocketTransport? { get set }
    /// Releases the inner connection and the relay without delivering events.
    func teardown()
}

extension RelayTransport {
    func send(_ message: ClientMessage) {
        inner?.send(message)
    }

    func close() {
        guard !finished else { return }
        finished = true
        onEvent = nil
        teardown()
    }

    /// Ends the transport with `.disconnected(reason)`.
    func fail(_ reason: String) {
        end(with: .disconnected(reason: reason))
    }

    /// Connects the inner WebSocket to the relay's loopback `port`, pinned with `policy`.
    func startInner(port: UInt16, displayName: String, policy: SyncTLS.PeerPolicy) {
        let target = MacTarget(kind: .manual(host: "127.0.0.1", port: port), displayName: displayName)
        let inner = WebSocketTransport(target: target, policy: policy)
        self.inner = inner
        inner.onEvent = { [weak self] event in self?.forward(event) }
        inner.start()
    }

    private func forward(_ event: TransportEvent) {
        guard !finished else { return }
        switch event {
        case .connected, .message:
            onEvent?(event)
        case .identityPresented, .identityMismatch, .disconnected:
            end(with: event)
        }
    }

    /// Ends the transport once: releases everything, then delivers `event`.
    private func end(with event: TransportEvent) {
        guard !finished else { return }
        finished = true
        let handler = onEvent
        onEvent = nil
        teardown()
        handler?(event)
    }
}
