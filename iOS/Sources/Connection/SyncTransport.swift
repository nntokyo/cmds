import CmdsCore
import Foundation
import Network

/// Where to connect. `id` is the Keychain account for the pairing (pinned fingerprint + token).
struct MacTarget: Codable, Hashable, Identifiable {
    enum Kind: Codable, Hashable {
        case bonjour(name: String, type: String, domain: String)
        case manual(host: String, port: UInt16)
        case mock
    }

    var kind: Kind
    var displayName: String

    var id: String {
        switch kind {
        case .bonjour(let name, let type, let domain): return "bonjour:\(name).\(type).\(domain)"
        case .manual(let host, let port): return "manual:\(host):\(port)"
        case .mock: return "mock"
        }
    }

    var subtitle: String {
        switch kind {
        case .bonjour: return "Local network"
        case .manual(let host, let port): return "\(host):\(port)"
        case .mock: return "Demo data"
        }
    }

    static let mock = MacTarget(kind: .mock, displayName: "Demo Mac")

    /// Parses "host", "host:port" or "[v6]:port".
    static func manual(_ input: String) -> MacTarget? {
        var text = input.trimmingCharacters(in: .whitespaces)
        for scheme in ["wss://", "ws://"] where text.hasPrefix(scheme) { text.removeFirst(scheme.count) }
        if text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        var host = text
        var port = SyncProtocol.defaultPort
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.hasPrefix(":") {
                guard let p = UInt16(rest.dropFirst()) else { return nil }
                port = p
            }
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.lastIndex(of: ":") {
            host = String(text[..<colon])
            guard let p = UInt16(text[text.index(after: colon)...]) else { return nil }
            port = p
        }
        // Hostname, IPv4 or IPv6 literal (optionally with a %zone); anything else would end up in the URL path.
        guard SyncPairingPayload.isValidHost(host), webSocketURL(host: host, port: port) != nil else { return nil }
        return MacTarget(kind: .manual(host: host, port: port), displayName: host)
    }

    /// Target for a scanned pairing code: the Bonjour service of that name if this phone sees it (keeps
    /// working when the Mac's address changes), else the address in the code. Either way the connection
    /// is pinned to the code's fingerprint, so a wrong match can only fail, never pair with another Mac.
    static func pairingTarget(for payload: SyncPairingPayload, discovered: [MacTarget]) -> MacTarget {
        if let name = payload.name, let match = discovered.first(where: {
            if case .bonjour(let serviceName, _, _) = $0.kind { return serviceName == name }
            return false
        }) {
            return match
        }
        return MacTarget(kind: .manual(host: payload.host, port: payload.port), displayName: payload.name ?? payload.host)
    }

    /// `wss://host:port/` for a manual target. NWProtocolWebSocket needs a URL endpoint to build the
    /// HTTP upgrade request; a `.hostPort` endpoint fails with "unable to create url endpoint"
    /// (ECONNABORTED). IPv6 literals are bracketed and their zone separator percent-encoded.
    static func webSocketURL(host: String, port: UInt16) -> URL? {
        let authority = host.contains(":") ? "[" + host.replacingOccurrences(of: "%", with: "%25") + "]" : host
        guard let url = URL(string: "wss://\(authority):\(port)/"), url.host != nil, url.port == Int(port) else { return nil }
        return url
    }
}

enum TransportEvent {
    /// TLS is up with the pinned certificate and the WebSocket is open. Only now may anything be sent.
    case connected
    case message(ServerMessage)
    /// Probe (manual pairing): the certificate the Mac presented. The handshake was refused; nothing was sent.
    case identityPresented(SyncFingerprint)
    /// The Mac presented a certificate other than the pinned one. The handshake was refused; nothing was sent.
    case identityMismatch(presented: SyncFingerprint?)
    /// Connection ended. `reason` is nil for a clean close.
    case disconnected(reason: String?)
}

/// How a connection reaches the Mac (shown in the connection status).
enum SyncLinkPath: Equatable {
    /// Wi‑Fi, Ethernet or peer-to-peer Wi‑Fi (Bonjour or an address).
    case network
    /// The Bluetooth fallback (`BluetoothTransport`): same pinned TLS session, relayed over L2CAP.
    case bluetooth

    var label: String {
        switch self {
        case .network: return String(localized: "Wi‑Fi")
        case .bluetooth: return String(localized: "Bluetooth")
        }
    }
}

/// A bidirectional message pipe to one Mac. Events are delivered on the main queue.
protocol SyncTransport: AnyObject {
    var onEvent: ((TransportEvent) -> Void)? { get set }
    /// Path of the connection; meaningful once `.connected` was delivered.
    var linkPath: SyncLinkPath { get }
    func start()
    func send(_ message: ClientMessage)
    func close()
}

extension SyncTransport {
    var linkPath: SyncLinkPath { .network }
}

/// WebSocket over TLS 1.3 via Network.framework (text frames, one JSON message per frame). The Mac's
/// certificate is checked by `SyncTLS` against `policy` during the handshake, before `.connected`.
final class WebSocketTransport: SyncTransport {
    var onEvent: ((TransportEvent) -> Void)?

    /// Written by the verify block, read by the state handler; both run on the main queue.
    private final class PeerCheckBox: @unchecked Sendable {
        var value: SyncTLS.PeerCheck?
    }

    private let connection: NWConnection
    private let policy: SyncTLS.PeerPolicy
    private let peer: PeerCheckBox
    private let codec = SyncCodec()
    private var finished = false

    init(target: MacTarget, policy: SyncTLS.PeerPolicy) {
        self.policy = policy
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = SyncCodec.maxFrameBytes
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        // Bonjour resolution alone can take several seconds.
        tcp.connectionTimeout = 15
        let peer = PeerCheckBox()
        self.peer = peer
        let tls = SyncTLS.clientOptions(policy: policy, queue: .main) { peer.value = $0 }
        let params = NWParameters(tls: tls, tcp: tcp)
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.includePeerToPeer = true

        let endpoint: NWEndpoint
        switch target.kind {
        case .bonjour(let name, let type, let domain):
            endpoint = .service(name: name, type: type, domain: domain, interface: nil)
        case .manual(let host, let port):
            if let url = MacTarget.webSocketURL(host: host, port: port) {
                endpoint = .url(url)
            } else {
                // Unreachable for targets built by `MacTarget.manual`; connecting fails and is reported.
                endpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 47_823)
            }
        case .mock:
            preconditionFailure("mock target uses MockTransport")
        }
        connection = NWConnection(to: endpoint, using: params)
    }

    /// Whether this connection's handshake passed the pin check.
    private var verified: Bool {
        guard case .pinned = policy else { return false }
        return peer.value?.accepted == true
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // Network.framework only gets here after the verify block accepted, and resumption is off,
                // so this very handshake was checked against the pin. Checked again before anything is sent.
                guard self.verified else { return self.finishRefused() }
                self.onEvent?(.connected)
                self.receive()
            case .waiting(let error), .failed(let error):
                // A refused certificate surfaces as .waiting (-9808) or .failed.
                if self.peer.value?.accepted == false {
                    self.finishRefused()
                } else {
                    self.finish(reason: error.localizedDescription)
                }
            case .cancelled:
                self.finish(reason: nil)
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    func send(_ message: ClientMessage) {
        guard !finished, verified, let data = try? codec.encode(message) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: message.typeName, metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(reason: error.localizedDescription) }
        })
    }

    func close() {
        guard !finished else { return }
        finished = true
        onEvent = nil
        connection.cancel()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, !self.finished else { return }
            if let error {
                self.finish(reason: error.localizedDescription)
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close {
                self.finish(reason: nil)
                return
            }
            if let data, !data.isEmpty {
                do {
                    self.onEvent?(.message(try self.codec.decodeServerMessage(data)))
                } catch is UnknownSyncMessageType {
                    // Newer Mac; ignore messages we don't understand.
                } catch {
                    self.finish(reason: "bad message from Mac: \(error)")
                    return
                }
            }
            self.receive()
        }
    }

    /// The certificate check refused the handshake (or a connection became ready without one).
    private func finishRefused() {
        guard !finished else { return }
        finished = true
        let handler = onEvent
        onEvent = nil
        connection.cancel()
        switch policy {
        case .probe:
            if let presented = peer.value?.presented {
                handler?(.identityPresented(presented))
            } else {
                handler?(.disconnected(reason: String(localized: "The Mac did not present a certificate.")))
            }
        case .pinned:
            handler?(.identityMismatch(presented: peer.value?.presented))
        }
    }

    private func finish(reason: String?) {
        guard !finished else { return }
        finished = true
        let handler = onEvent
        onEvent = nil
        connection.cancel()
        handler?(.disconnected(reason: reason))
    }
}
