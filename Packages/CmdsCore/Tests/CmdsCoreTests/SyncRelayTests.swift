import CryptoKit
import Foundation
import Network
import XCTest
@testable import CmdsCore

/// Bluetooth fallback relay (docs/internals/sync-protocol.md "Bluetooth"). The L2CAP channel is simulated by two bound
/// stream pairs; everything else is the real path: phone WebSocket client → loopback listener → relay →
/// "L2CAP" → relay → loopback TCP → TLS WebSocket server.
final class SyncRelayTests: XCTestCase {

    // MARK: - Info characteristic

    func testInfoRoundTripAndHint() throws {
        let fp = SyncFingerprint(certificate: Data("cert".utf8))
        let other = SyncFingerprint(certificate: Data("other".utf8))
        let info = SyncBluetooth.Info(psm: 0x00C5, fingerprint: fp, name: "Ryo’s MacBook Pro")
        let decoded = try XCTUnwrap(SyncBluetooth.Info(encoded: info.encoded))
        XCTAssertEqual(decoded, info)
        XCTAssertEqual(decoded.psm, 0x00C5)
        XCTAssertTrue(decoded.matches(fp))
        XCTAssertFalse(decoded.matches(other))

        let long = SyncBluetooth.Info(psm: 200, fingerprint: fp, name: String(repeating: "é", count: 100))
        XCTAssertLessThanOrEqual(long.name.utf8.count, SyncBluetooth.Info.maxNameBytes)
        XCTAssertNotNil(SyncBluetooth.Info(encoded: long.encoded))

        var wrongVersion = info.encoded
        wrongVersion[0] = 9
        XCTAssertNil(SyncBluetooth.Info(encoded: wrongVersion))
        XCTAssertNil(SyncBluetooth.Info(encoded: Data([1, 0, 0])))
        XCTAssertNil(SyncBluetooth.Info(encoded: Data([1, 0, 0] + [UInt8](repeating: 0, count: 8)))) // PSM 0
        XCTAssertNil(SyncBluetooth.Info(encoded: info.encoded + Data(repeating: 0x41, count: 80)))
    }

    // MARK: - Per-peer tagging

    /// The relay's local port is registered before `connect`, so the server can always map it.
    func testLoopbackConnectRegistersPortBeforeConnecting() throws {
        let listener = try SyncLoopback.Listener()
        let peers = SyncLoopbackPeers()
        let accepted = expectation(description: "accepted")
        let peerPort = LockedBox<UInt16?>(nil)
        listener.acceptOne { fd in
            guard let fd else { return }
            var addr = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &length) }
            }
            let port = UInt16(bigEndian: addr.sin_port)
            // Looked up at accept time, like SyncServer does.
            XCTAssertEqual(peers.peer(forPort: port), "bluetooth:test")
            peerPort.value = port
            close(fd)
            accepted.fulfill()
        }
        var registered: UInt16 = 0
        let fd = try SyncLoopback.connect(port: listener.port) { port in
            registered = port
            peers.register(port: port, peer: "bluetooth:test")
        }
        wait(for: [accepted], timeout: 5)
        close(fd)
        XCTAssertEqual(peerPort.value, registered)
        XCTAssertNil(peers.peer(forPort: registered &+ 1))
        peers.unregister(port: registered)
        XCTAssertNil(peers.peer(forPort: registered))
    }

    // MARK: - Relay

    /// Relays a TLS WebSocket session (PSK, so no keychain identity is needed) both ways through a small
    /// buffer, including a frame much larger than the buffer (backpressure), and tears down both relays
    /// when the client closes.
    func testRelaysTLSWebSocketSessionWithBackpressure() throws {
        let server = try EchoServer()
        defer { server.stop() }
        let chain = try RelayChain(serverPort: server.port, bufferSize: 2048)
        defer { chain.close() }

        let client = WSClient(port: chain.phonePort, tls: EchoServer.pskOptions())
        client.start()
        XCTAssertEqual(client.waitReady(), true)

        client.send(Data("hello".utf8))
        XCTAssertEqual(client.receive().map { String(decoding: $0, as: UTF8.self) }, "echo:hello")

        let big = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        client.send(big, binary: true)
        XCTAssertEqual(client.receive(timeout: 30), Data("echo:".utf8) + big)

        // The server saw the connection under the registered Bluetooth peer, not as plain 127.0.0.1.
        XCTAssertEqual(server.remotePorts.compactMap { chain.peers.peer(forPort: $0) }, ["bluetooth:peer-1"])

        client.cancel()
        chain.waitClosed(self)
        XCTAssertGreaterThan(chain.macRelay.bytesForward, 1024 * 1024)
        XCTAssertGreaterThan(chain.macRelay.bytesBackward, 1024 * 1024)
    }

    /// The server going away closes both relays (and so the "L2CAP channel" and the phone's socket).
    func testServerCloseTearsDownRelays() throws {
        let server = try EchoServer()
        let chain = try RelayChain(serverPort: server.port, bufferSize: 4096)
        defer { chain.close() }
        let client = WSClient(port: chain.phonePort, tls: EchoServer.pskOptions())
        client.start()
        XCTAssertEqual(client.waitReady(), true)
        client.send(Data("x".utf8))
        XCTAssertNotNil(client.receive())
        server.stop()
        chain.waitClosed(self)
        client.cancel()
    }

    /// End to end against an isolated cmds instance (docs/internals/testing.md "Sync against an isolated instance"):
    /// set `CMDS_RELAY_E2E_PAIRING` to its `sync-test-pairing.txt`. Pins the instance's real certificate,
    /// pairs with the code through the relay and expects `welcome` and `state`.
    func testRelayToIsolatedInstance() throws {
        guard let path = ProcessInfo.processInfo.environment["CMDS_RELAY_E2E_PAIRING"] else {
            throw XCTSkip("set CMDS_RELAY_E2E_PAIRING to an isolated instance's sync-test-pairing.txt")
        }
        let payload = try SyncPairingPayload.parse(String(contentsOfFile: path, encoding: .utf8))
        XCTAssertEqual(payload.host, "127.0.0.1", "only ever test against a loopback-only test instance")
        let chain = try RelayChain(serverPort: payload.port, bufferSize: 4096)
        defer { chain.close() }

        let checks = LockedBox<[SyncTLS.PeerCheck]>([])
        let tls = SyncTLS.clientOptions(policy: .pinned(payload.fingerprint), queue: .global()) { check in
            checks.value.append(check)
        }
        let client = WSClient(port: chain.phonePort, tls: tls)
        client.start()
        XCTAssertEqual(client.waitReady(), true)
        XCTAssertEqual(checks.value.map(\.accepted), [true])

        let codec = SyncCodec()
        client.send(try codec.encode(.hello(.init(deviceName: "relay test", deviceID: "relay-test", pairingCode: payload.code))))
        let welcome = try codec.decodeServerMessage(XCTUnwrap(client.receive()))
        guard case .welcome = welcome else { return XCTFail("expected welcome, got \(welcome)") }
        let state = try codec.decodeServerMessage(XCTUnwrap(client.receive()))
        guard case .state = state else { return XCTFail("expected state, got \(state)") }
        client.cancel()
        chain.waitClosed(self)
    }

    /// A wrong pin through the relay is refused in the handshake, exactly as over the network.
    func testRelayKeepsPinning() throws {
        guard let path = ProcessInfo.processInfo.environment["CMDS_RELAY_E2E_PAIRING"] else {
            throw XCTSkip("set CMDS_RELAY_E2E_PAIRING to an isolated instance's sync-test-pairing.txt")
        }
        let payload = try SyncPairingPayload.parse(String(contentsOfFile: path, encoding: .utf8))
        let chain = try RelayChain(serverPort: payload.port, bufferSize: 4096)
        defer { chain.close() }
        let wrong = SyncFingerprint(certificate: Data("not the mac".utf8))
        let tls = SyncTLS.clientOptions(policy: .pinned(wrong), queue: .global()) { _ in }
        let client = WSClient(port: chain.phonePort, tls: tls)
        client.start()
        XCTAssertEqual(client.waitReady(), false)
        client.cancel()
    }
}

// MARK: - Fixtures

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// Phone side (loopback listener ↔ "L2CAP") and Mac side ("L2CAP" ↔ loopback TCP to the server).
private final class RelayChain {
    let peers = SyncLoopbackPeers()
    let phonePort: UInt16
    private(set) var macRelay: SyncStreamRelay!
    private var phoneRelay: SyncStreamRelay?
    private let listener: SyncLoopback.Listener
    private let phoneClosed = DispatchSemaphore(value: 0)
    private let macClosed = DispatchSemaphore(value: 0)
    private let phoneReady = DispatchSemaphore(value: 0)

    init(serverPort: UInt16, bufferSize: Int) throws {
        // The L2CAP channel: one bound pair per direction.
        var phoneToMacIn: InputStream?, phoneToMacOut: OutputStream?
        var macToPhoneIn: InputStream?, macToPhoneOut: OutputStream?
        Stream.getBoundStreams(withBufferSize: 1024, inputStream: &phoneToMacIn, outputStream: &phoneToMacOut)
        Stream.getBoundStreams(withBufferSize: 1024, inputStream: &macToPhoneIn, outputStream: &macToPhoneOut)

        // Mac: channel opened → connect to the sync server, registering the peer first.
        let peers = peers
        var localPort: UInt16 = 0
        let fd = try SyncLoopback.connect(port: serverPort) { port in
            localPort = port
            peers.register(port: port, peer: "bluetooth:peer-1")
        }
        let macClosed = macClosed
        macRelay = SyncStreamRelay((phoneToMacIn!, macToPhoneOut!), SyncLoopback.streams(socket: fd),
                                   bufferSize: bufferSize) {
            peers.unregister(port: localPort)
            macClosed.signal()
        }
        macRelay.start()

        // Phone: loopback listener; the first accepted connection is relayed to the channel.
        listener = try SyncLoopback.Listener()
        phonePort = listener.port
        let phoneClosed = phoneClosed
        let channel = (input: macToPhoneIn!, output: phoneToMacOut!)
        let phoneReady = phoneReady
        listener.acceptOne { [weak self] fd in
            guard let fd else { return }
            let relay = SyncStreamRelay(channel, SyncLoopback.streams(socket: fd), bufferSize: bufferSize) {
                phoneClosed.signal()
            }
            relay.start()
            self?.phoneRelay = relay
            phoneReady.signal()
        }
    }

    func waitClosed(_ test: XCTestCase) {
        XCTAssertEqual(macClosed.wait(timeout: .now() + 10), .success, "Mac relay did not close")
        XCTAssertEqual(phoneReady.wait(timeout: .now() + 1), .success)
        phoneReady.signal()
        XCTAssertEqual(phoneClosed.wait(timeout: .now() + 10), .success, "phone relay did not close")
    }

    func close() {
        listener.close()
        macRelay.close()
        phoneRelay?.close()
    }
}

/// TLS (pre-shared key) WebSocket echo server on 127.0.0.1.
private final class EchoServer {
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "echo")
    private let ports = LockedBox<[UInt16]>([])
    private var connections: [NWConnection] = []
    var remotePorts: [UInt16] { ports.value }

    static func pskOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let key = HMAC<SHA256>.authenticationCode(for: Data("cmds-relay-test".utf8), using: SymmetricKey(data: Data("k".utf8)))
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("cmds-relay-test".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options.securityProtocolOptions, keyData as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(options.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        return options
    }

    init() throws {
        let params = NWParameters(tls: Self.pskOptions(), tcp: NWProtocolTCP.Options())
        let ws = NWProtocolWebSocket.Options()
        ws.maximumMessageSize = 4 * 1024 * 1024
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            if case .hostPort(_, let port) = connection.endpoint { self.ports.value.append(port.rawValue) }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.echo(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            throw XCTSkip("echo listener did not start")
        }
        self.port = port
    }

    private func echo(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard error == nil, let data else { return connection.cancel() }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
            let context = NWConnection.ContentContext(identifier: "echo", metadata: [metadata])
            connection.send(content: Data("echo:".utf8) + data, contentContext: context, isComplete: true,
                            completion: .contentProcessed { _ in })
            self?.echo(connection)
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}

/// Minimal synchronous WebSocket client (what `WebSocketTransport` does on the phone).
private final class WSClient {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ws-client")
    private let readyResult = LockedBox<Bool?>(nil)
    private let readySignal = DispatchSemaphore(value: 0)

    init(port: UInt16, tls: NWProtocolTLS.Options) {
        let ws = NWProtocolWebSocket.Options()
        ws.maximumMessageSize = 4 * 1024 * 1024
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        connection = NWConnection(to: .url(URL(string: "wss://127.0.0.1:\(port)/")!), using: params)
    }

    func start() {
        connection.stateUpdateHandler = { [readyResult, readySignal] state in
            switch state {
            case .ready:
                if readyResult.value == nil { readyResult.value = true; readySignal.signal() }
            case .failed, .waiting, .cancelled:
                if readyResult.value == nil { readyResult.value = false; readySignal.signal() }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func waitReady() -> Bool? {
        _ = readySignal.wait(timeout: .now() + 15)
        return readyResult.value
    }

    func send(_ data: Data, binary: Bool = false) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: binary ? .binary : .text)
        let context = NWConnection.ContentContext(identifier: "msg", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    func receive(timeout: TimeInterval = 10) -> Data? {
        let box = LockedBox<Data?>(nil)
        let done = DispatchSemaphore(value: 0)
        connection.receiveMessage { data, _, _, _ in
            box.value = data
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        return box.value
    }

    func cancel() { connection.cancel() }
}
