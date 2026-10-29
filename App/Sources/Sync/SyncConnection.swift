import Foundation
import os
import Network

/// One WebSocket connection from a phone. Network I/O runs on the server's queue; received
/// frames and the close event are delivered on the main actor. Thread-safe.
final class SyncConnection: @unchecked Sendable {
    /// Disconnect a client whose unsent output exceeds this (slow or stalled reader).
    static let maxPendingBytes = 8 * 1024 * 1024

    let id = UUID()
    /// Remote IP (no port), used for rate limiting and display.
    let remoteHost: String

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let onFrame: @MainActor (SyncConnection, Data) -> Void
    private let onClose: @MainActor (SyncConnection) -> Void

    private let lock = NSLock()
    private var pendingBytes = 0
    private var cancelled = false
    private var notifiedClose = false

    init(connection: NWConnection, queue: DispatchQueue,
         onFrame: @escaping @MainActor (SyncConnection, Data) -> Void,
         onClose: @escaping @MainActor (SyncConnection) -> Void) {
        self.connection = connection
        self.queue = queue
        self.onFrame = onFrame
        self.onClose = onClose
        remoteHost = Self.host(of: connection.endpoint)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.receive()
            case .failed, .cancelled: self.notifyClosed()
            case .waiting: self.close()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    /// Sends one text frame. When `thenClose` is set, the connection is closed once it is written.
    func send(_ data: Data, thenClose: Bool = false) {
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        pendingBytes += data.count
        let overflow = pendingBytes > Self.maxPendingBytes
        lock.unlock()
        if overflow {
            syncLog.notice("closing \(self.remoteHost, privacy: .public): client is not reading")
            close()
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.lock()
            self.pendingBytes -= data.count
            self.lock.unlock()
            if error != nil || thenClose { self.close() }
        })
    }

    func close() {
        lock.lock()
        let wasCancelled = cancelled
        cancelled = true
        lock.unlock()
        guard !wasCancelled else { return }
        connection.cancel()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil {
                self.close()
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close {
                self.close()
                return
            }
            if let data, !data.isEmpty, metadata?.opcode != .pong, metadata?.opcode != .ping {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.onFrame(self, data) }
                }
            }
            self.lock.lock()
            let stop = self.cancelled
            self.lock.unlock()
            if !stop { self.receive() }
        }
    }

    private func notifyClosed() {
        lock.lock()
        cancelled = true
        let first = !notifiedClose
        notifiedClose = true
        lock.unlock()
        guard first else { return }
        connection.cancel()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onClose(self) }
        }
    }

    private static func host(of endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "\(endpoint)" }
        switch host {
        case .ipv4(let address):
            return "\(address)"
        case .ipv6(let address):
            // Treat IPv4-mapped addresses like their IPv4 form; drop the interface scope.
            if let v4 = address.asIPv4 { return "\(v4)" }
            return "\(address)".components(separatedBy: "%").first ?? "\(address)"
        case .name(let name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }
}
