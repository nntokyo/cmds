import CmdsCore
import Foundation
import Network

/// Where to connect. `id` is the Keychain account for the pairing token.
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
        if text.hasPrefix("ws://") { text.removeFirst(5) }
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
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._:%")
        guard !host.isEmpty, host.allSatisfy(allowed.contains), webSocketURL(host: host, port: port) != nil else { return nil }
        return MacTarget(kind: .manual(host: host, port: port), displayName: host)
    }

    /// `ws://host:port/` for a manual target. NWProtocolWebSocket needs a URL endpoint to build the
    /// HTTP upgrade request; a `.hostPort` endpoint fails with "unable to create url endpoint"
    /// (ECONNABORTED). IPv6 literals are bracketed and their zone separator percent-encoded.
    static func webSocketURL(host: String, port: UInt16) -> URL? {
        let authority = host.contains(":") ? "[" + host.replacingOccurrences(of: "%", with: "%25") + "]" : host
        guard let url = URL(string: "ws://\(authority):\(port)/"), url.host != nil, url.port == Int(port) else { return nil }
        return url
    }
}

enum TransportEvent {
    case connected
    case message(ServerMessage)
    /// Connection ended. `reason` is nil for a clean close.
    case disconnected(reason: String?)
}

/// A bidirectional message pipe to one Mac. Events are delivered on the main queue.
protocol SyncTransport: AnyObject {
    var onEvent: ((TransportEvent) -> Void)? { get set }
    func start()
    func send(_ message: ClientMessage)
    func close()
}

/// WebSocket over TCP via Network.framework (text frames, one JSON message per frame).
final class WebSocketTransport: SyncTransport {
    var onEvent: ((TransportEvent) -> Void)?

    private let connection: NWConnection
    private let codec = SyncCodec()
    private var finished = false

    init(target: MacTarget) {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = SyncCodec.maxFrameBytes
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        // Bonjour resolution alone can take several seconds.
        tcp.connectionTimeout = 15
        let params = NWParameters(tls: nil, tcp: tcp)
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

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onEvent?(.connected)
                self.receive()
            case .waiting(let error):
                // Unreachable for now; treat as a failure so the client's backoff decides when to retry.
                self.finish(reason: error.localizedDescription)
            case .failed(let error):
                self.finish(reason: error.localizedDescription)
            case .cancelled:
                self.finish(reason: nil)
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    func send(_ message: ClientMessage) {
        guard !finished, let data = try? codec.encode(message) else { return }
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

    private func finish(reason: String?) {
        guard !finished else { return }
        finished = true
        let handler = onEvent
        onEvent = nil
        connection.cancel()
        handler?(.disconnected(reason: reason))
    }
}
