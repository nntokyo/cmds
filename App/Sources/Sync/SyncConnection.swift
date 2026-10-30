import CmdsCore
import Foundation
import os
import Network

/// One WebSocket connection from a phone. Network I/O runs on the server's queue; received
/// frames and the close event are delivered on the main actor. Thread-safe.
final class SyncConnection: @unchecked Sendable {
    /// Disconnect a client whose unsent output exceeds this (slow or stalled reader).
    static let maxPendingBytes = 8 * 1024 * 1024

    let id = UUID()
    /// Remote IP (no port), `bluetooth:<peer>` for a connection relayed from Bluetooth, or `ssh:<relay host>`
    /// for one that came through remote access via SSH; used for rate limiting and display.
    let remoteHost: String
    /// Relayed from the Bluetooth fallback (slow link: screens are throttled).
    let viaBluetooth: Bool
    /// Came through the SSH remote-access forward (pairing codes are refused).
    let viaSSH: Bool

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let onFrame: @MainActor (SyncConnection, Data) -> Void
    private let onClose: @MainActor (SyncConnection) -> Void

    private let lock = NSLock()
    private var pendingBytes = 0
    private var sentBytes = 0
    private var receivedBytes = 0
    private var cancelled = false
    private var notifiedClose = false

    init(connection: NWConnection, queue: DispatchQueue, relayedPeer: String? = nil,
         onFrame: @escaping @MainActor (SyncConnection, Data) -> Void,
         onClose: @escaping @MainActor (SyncConnection) -> Void) {
        self.connection = connection
        self.queue = queue
        self.onFrame = onFrame
        self.onClose = onClose
        remoteHost = relayedPeer ?? Self.host(of: connection.endpoint)
        viaBluetooth = relayedPeer?.hasPrefix(SyncBluetooth.peerHostPrefix) ?? false
        viaSSH = relayedPeer?.hasPrefix(SyncRemote.peerHostPrefix) ?? false
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

    /// Bytes handed to `send` whose write has not completed yet (pacing of large transfers such as `file`).
    var queuedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingBytes
    }

    /// Sends one text frame. When `thenClose` is set, the connection is closed once it is written.
    func send(
_ data: Data, thenClose: Bool = false) {
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
            if error == nil { self.sentBytes += data.count }
            self.lock.unlock()
            if error != nil || thenClose { self.close() }
        })
    }

    /// WebSocket payload bytes written to and read from this connection so far (`sync.status`).
    var byteCounts: (sent: Int, received: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (sentBytes, receivedBytes)
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
            if let data, !data.isEmpty {
                self.lock.lock()
                self.receivedBytes += data.count
                self.lock.unlock()
            }
            if let data, !data.isEmpty, metadata?.opcode != .pong, metadata?.opcode != .ping {
                // Backpressure: the next frame is read only after this one was handled on the main actor,
                // so a fast sender fills its TCP window instead of the main queue.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.onFrame(self, data) }
                    self.receiveIfOpen()
                }
                return
            }
            self.receiveIfOpen()
        }
    }

    private func receiveIfOpen() {
        lock.lock()
        let stop = cancelled
        lock.unlock()
        if !stop { receive() }
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
