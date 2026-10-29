import CmdsCore
import Crypto
import Foundation
import Network
import NIOSSH
import XCTest
@testable import CmdsSSH

/// Remote access via SSH (docs/SYNC.md). Unit tests always run; the end-to-end tests need a throwaway sshd
/// (`Scripts/test-relay-sshd.sh start <dir> <port>`) and, for the Mac tests, an isolated cmds instance with
/// remote access to that sshd:
///
///   CMDS_SSH_E2E_DIR=<dir> CMDS_SSH_E2E_PORT=<port>                       SSH only
///   + CMDS_SSH_E2E_PAIRING=$CMDS_SUPPORT_DIR/sync-test-pairing.txt
///     CMDS_SSH_E2E_RELAY_PORT=<relay port of the instance>                Mac through SSH
final class SSHTunnelTests: XCTestCase {

    // MARK: - Keys

    func testAuthorizedKeysLineMatchesSSHKeygen() throws {
        let key = Curve25519.Signing.PrivateKey()
        let line = SSHKeys.authorizedKeysLine(for: key.publicKey, comment: "cmds iPhone")
        XCTAssertTrue(line.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI"))
        XCTAssertTrue(line.hasSuffix(" cmds iPhone"))
        // Same text as NIOSSH's own encoding of the key.
        let nio = String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)
        XCTAssertEqual(line, nio + " cmds iPhone")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmds-ssh-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("key.pub")
        try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
        let output = try runTool("/usr/bin/ssh-keygen", ["-l", "-E", "sha256", "-f", file.path])
        let fields = output.split(separator: " ")
        XCTAssertEqual(fields.count >= 2 ? String(fields[1]) : nil, SSHKeys.fingerprint(openSSHPublicKey: line))
    }

    func testHostKeyPinMatching() throws {
        let a = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
        let b = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
        let pin = SSHKeys.openSSH(a)
        XCTAssertTrue(SSHKeys.matches(pin: pin, presented: a))
        XCTAssertTrue(SSHKeys.matches(pin: pin + " some comment", presented: a))
        XCTAssertFalse(SSHKeys.matches(pin: pin, presented: b))
        XCTAssertFalse(SSHKeys.matches(pin: "", presented: a))
        XCTAssertFalse(SSHKeys.matches(pin: "ssh-ed25519 notbase64!", presented: a))
        XCTAssertNil(SSHKeys.fingerprint(openSSHPublicKey: "garbage"))
    }

    func testEndpointCompleteness() {
        XCTAssertTrue(SSHRelayEndpoint(host: "relay.example", user: "me").isComplete)
        XCTAssertFalse(SSHRelayEndpoint(host: " ", user: "me").isComplete)
        XCTAssertFalse(SSHRelayEndpoint(host: "relay.example", user: "").isComplete)
        XCTAssertFalse(SSHRelayEndpoint(host: "relay.example", port: 0, user: "me").isComplete)
    }

    // MARK: - SSH end to end (throwaway sshd)

    func testUnknownHostKeyIsReportedNotTrusted() async throws {
        let relay = try Relay.fromEnvironment()
        let key = try relay.authorizedPhoneKey()
        do {
            _ = try await SSHTunnel.connect(to: relay.endpoint(relayPort: 1), key: key, hostKeyPin: nil)
            XCTFail("connected without a pinned host key")
        } catch SSHTunnelError.unknownHostKey(let presented) {
            XCTAssertTrue(SSHKeys.matches(pin: presented, presented: try NIOSSHPublicKey(openSSHPublicKey: relay.hostKey)))
            XCTAssertEqual(SSHKeys.fingerprint(openSSHPublicKey: presented), SSHKeys.fingerprint(openSSHPublicKey: relay.hostKey))
        }
    }

    func testWrongHostKeyIsRefused() async throws {
        let relay = try Relay.fromEnvironment()
        let key = try relay.authorizedPhoneKey()
        do {
            _ = try await SSHTunnel.connect(to: relay.endpoint(relayPort: 1), key: key, hostKeyPin: relay.otherHostKey)
            XCTFail("connected to a host key other than the pinned one")
        } catch SSHTunnelError.hostKeyMismatch(let presented) {
            XCTAssertTrue(SSHKeys.matches(pin: relay.hostKey, presented: try NIOSSHPublicKey(openSSHPublicKey: presented)))
        }
    }

    func testUnauthorizedKeyIsRefused() async throws {
        let relay = try Relay.fromEnvironment()
        do {
            _ = try await SSHTunnel.connect(to: relay.endpoint(relayPort: 1), key: .init(), hostKeyPin: relay.hostKey)
            XCTFail("a key that is not in authorized_keys was accepted")
        } catch let error as SSHTunnelError {
            XCTAssertEqual(error, .authenticationFailed)
        }
    }

    func testForwardsBytesAndReportsMissingForward() async throws {
        let relay = try Relay.fromEnvironment()
        let key = try relay.authorizedPhoneKey()
        let echo = try TCPEcho()
        defer { echo.stop() }

        let tunnel = try await SSHTunnel.connect(to: relay.endpoint(relayPort: echo.port), key: key, hostKeyPin: relay.hostKey)
        defer { tunnel.close() }
        let port = try await tunnel.openForward()
        let fd = try SyncLoopback.connect(port: port) { _ in }
        defer { close(fd) }
        let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        XCTAssertEqual(try exchange(fd, payload), payload)

        // Nothing listens on this relay port: the channel is refused.
        let closedPort = try unusedPort()
        let other = try await SSHTunnel.connect(to: relay.endpoint(relayPort: closedPort), key: key, hostKeyPin: relay.hostKey)
        defer { other.close() }
        do {
            _ = try await other.openForward()
            XCTFail("forward to a closed port succeeded")
        } catch SSHTunnelError.forwardRefused {}
    }

    // MARK: - Mac end to end (isolated instance with remote access to the throwaway sshd)

    /// Pairs on loopback (as on the LAN), then connects through SSH → direct-tcpip → the Mac's relay port →
    /// pinned TLS with the token and expects welcome and state. A pairing code through SSH is refused, a wrong
    /// certificate pin is refused, and a dropped tunnel reconnects.
    func testMacThroughSSH() async throws {
        let relay = try Relay.fromEnvironment()
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMDS_SSH_E2E_PAIRING"], let relayPort = env["CMDS_SSH_E2E_RELAY_PORT"].flatMap(UInt16.init) else {
            throw XCTSkip("set CMDS_SSH_E2E_PAIRING and CMDS_SSH_E2E_RELAY_PORT")
        }
        let payload = try SyncPairingPayload.parse(String(contentsOfFile: path, encoding: .utf8))
        XCTAssertEqual(payload.host, "127.0.0.1", "only ever test against a loopback-only test instance")
        let codec = SyncCodec()
        // Restricted key line as shown by the app: forwarding to the relay port only.
        let key = try relay.authorizedPhoneKey(permitOpen: relayPort)
        let endpoint = relay.endpoint(relayPort: relayPort)

        // That key cannot open any other port on the relay.
        do {
            let echo = try TCPEcho()
            defer { echo.stop() }
            let tunnel = try await SSHTunnel.connect(to: relay.endpoint(relayPort: echo.port), key: key, hostKeyPin: relay.hostKey)
            defer { tunnel.close() }
            do {
                _ = try await tunnel.openForward()
                XCTFail("restricted key opened a port other than the relay port")
            } catch SSHTunnelError.forwardRefused {}
        }

        // Pairing over SSH is refused: pairing happens on the local network only.
        do {
            let tunnel = try await SSHTunnel.connect(to: endpoint, key: key, hostKeyPin: relay.hostKey)
            defer { tunnel.close() }
            let client = WSClient(port: try await tunnel.openForward(), tls: pinned(payload.fingerprint))
            XCTAssertEqual(client.waitReady(), true)
            client.send(try codec.encode(.hello(.init(deviceName: "ssh test", deviceID: "ssh-test", pairingCode: payload.code))))
            let reply = try codec.decodeServerMessage(XCTUnwrap(client.receive()))
            guard case .error(let info) = reply else { return XCTFail("pairing over SSH: expected error, got \(reply)") }
            XCTAssertEqual(info.code, .pairingRequired)
            client.cancel()
        }

        // Pair directly (stands in for the LAN).
        let token: String
        do {
            let client = WSClient(port: payload.port, tls: pinned(payload.fingerprint))
            XCTAssertEqual(client.waitReady(), true)
            client.send(try codec.encode(.hello(.init(deviceName: "ssh test", deviceID: "ssh-test", pairingCode: payload.code))))
            let welcome = try codec.decodeServerMessage(XCTUnwrap(client.receive()))
            guard case .welcome(let w) = welcome else { return XCTFail("expected welcome, got \(welcome)") }
            token = w.token
            client.cancel()
        }

        // Token through SSH: welcome + state.
        try await connectWithToken(endpoint: endpoint, key: key, relay: relay, fingerprint: payload.fingerprint, token: token)

        // Wrong Mac certificate through SSH: refused in the handshake.
        do {
            let tunnel = try await SSHTunnel.connect(to: endpoint, key: key, hostKeyPin: relay.hostKey)
            defer { tunnel.close() }
            let client = WSClient(port: try await tunnel.openForward(),
                                  tls: pinned(SyncFingerprint(certificate: Data("not the mac".utf8))))
            XCTAssertEqual(client.waitReady(), false)
            client.cancel()
        }

        // Phone side drop: the live session ends when the tunnel closes; a new tunnel works.
        do {
            let tunnel = try await SSHTunnel.connect(to: endpoint, key: key, hostKeyPin: relay.hostKey)
            let client = WSClient(port: try await tunnel.openForward(), tls: pinned(payload.fingerprint))
            XCTAssertEqual(client.waitReady(), true)
            client.send(try codec.encode(.hello(.init(deviceName: "ssh test", deviceID: "ssh-test", token: token))))
            XCTAssertNotNil(client.receive())
            tunnel.close()
            XCTAssertTrue(client.waitEnded(), "session survived the tunnel")
            client.cancel()
        }
        try await connectWithToken(endpoint: endpoint, key: key, relay: relay, fingerprint: payload.fingerprint, token: token)

        // Mac side drop: kill the instance's ssh (only the one using this test's config); it comes back.
        if let config = env["CMDS_SSH_E2E_DIR"].map({ $0 + "/ssh_config" }) {
            _ = try? runTool("/usr/bin/pkill", ["-f", config])
            var connected = false
            for _ in 0..<40 where !connected {
                try await Task.sleep(for: .milliseconds(750))
                connected = (try? await connectWithToken(endpoint: endpoint, key: key, relay: relay,
                                                         fingerprint: payload.fingerprint, token: token, quiet: true)) != nil
            }
            XCTAssertTrue(connected, "the Mac did not restore its forward")
        }
    }

    private func connectWithToken(endpoint: SSHRelayEndpoint, key: Curve25519.Signing.PrivateKey, relay: Relay,
                                  fingerprint: SyncFingerprint, token: String, quiet: Bool = false) async throws {
        let codec = SyncCodec()
        let tunnel = try await SSHTunnel.connect(to: endpoint, key: key, hostKeyPin: relay.hostKey)
        defer { tunnel.close() }
        let client = WSClient(port: try await tunnel.openForward(), tls: pinned(fingerprint))
        defer { client.cancel() }
        guard client.waitReady() == true else {
            if !quiet { XCTFail("TLS through SSH did not come up") }
            throw SSHTunnelError.closed
        }
        client.send(try codec.encode(.hello(.init(deviceName: "ssh test", deviceID: "ssh-test", token: token))))
        let welcome = try codec.decodeServerMessage(XCTUnwrap(client.receive()))
        guard case .welcome = welcome else {
            if !quiet { XCTFail("expected welcome, got \(welcome)") }
            throw SSHTunnelError.closed
        }
        let state = try codec.decodeServerMessage(XCTUnwrap(client.receive()))
        guard case .state = state else {
            if !quiet { XCTFail("expected state, got \(state)") }
            throw SSHTunnelError.closed
        }
    }

    private func pinned(_ fingerprint: SyncFingerprint) -> NWProtocolTLS.Options {
        SyncTLS.clientOptions(policy: .pinned(fingerprint), queue: .global()) { _ in }
    }
}

// MARK: - Fixtures

/// The throwaway sshd from `Scripts/test-relay-sshd.sh`.
private struct Relay {
    var dir: URL
    var port: UInt16
    var hostKey: String
    var otherHostKey: String

    static func fromEnvironment() throws -> Relay {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["CMDS_SSH_E2E_DIR"], let port = env["CMDS_SSH_E2E_PORT"].flatMap(UInt16.init) else {
            throw XCTSkip("start Scripts/test-relay-sshd.sh and set CMDS_SSH_E2E_DIR and CMDS_SSH_E2E_PORT")
        }
        let url = URL(fileURLWithPath: dir)
        func key(_ name: String) throws -> String {
            try String(contentsOf: url.appendingPathComponent(name), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Relay(dir: url, port: port, hostKey: try key("host_ed25519.pub"), otherHostKey: try key("other_host_ed25519.pub"))
    }

    func endpoint(relayPort: UInt16) -> SSHRelayEndpoint {
        SSHRelayEndpoint(host: "127.0.0.1", port: port, user: NSUserName(), relayPort: relayPort)
    }

    /// A new phone key, added to the sshd's authorized_keys (read on every login); with `permitOpen` in the
    /// restricted form the app shows.
    func authorizedPhoneKey(permitOpen: UInt16? = nil) throws -> Curve25519.Signing.PrivateKey {
        let key = Curve25519.Signing.PrivateKey()
        let line = permitOpen.map { SSHKeys.restrictedAuthorizedKeysLine(for: key.publicKey, relayPort: $0, comment: "cmds-test-phone") }
            ?? SSHKeys.authorizedKeysLine(for: key.publicKey, comment: "cmds-test-phone")
        let file = dir.appendingPathComponent("authorized_keys")
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        return key
    }
}

private func runTool(_ tool: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

private func unusedPort() throws -> UInt16 {
    let listener = try SyncLoopback.Listener()
    defer { listener.close() }
    return listener.port
}

/// Writes `payload` and reads the same amount back (blocking socket).
private func exchange(_ fd: Int32, _ payload: Data) throws -> Data {
    var tv = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let writer = Thread {
        payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < payload.count {
                let n = write(fd, raw.baseAddress! + offset, payload.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }
    writer.start()
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while received.count < payload.count {
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { break }
        received.append(contentsOf: buffer[0..<n])
    }
    return received
}

/// Plain TCP echo on 127.0.0.1.
private final class TCPEcho {
    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "tcp-echo")

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            Self.echo(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            throw XCTSkip("echo listener did not start")
        }
        self.port = port
    }

    private static func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            if let data, !data.isEmpty { connection.send(content: data, completion: .contentProcessed { _ in }) }
            if complete || error != nil { return connection.cancel() }
            echo(connection)
        }
    }

    func stop() { listener.cancel() }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// Minimal synchronous TLS WebSocket client (what `WebSocketTransport` does on the phone).
private final class WSClient {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ws-client")
    private let readyResult = LockedBox<Bool?>(nil)
    private let readySignal = DispatchSemaphore(value: 0)
    private let endedSignal = DispatchSemaphore(value: 0)

    init(port: UInt16, tls: NWProtocolTLS.Options) {
        let ws = NWProtocolWebSocket.Options()
        ws.maximumMessageSize = 4 * 1024 * 1024
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        connection = NWConnection(to: .url(URL(string: "wss://127.0.0.1:\(port)/")!), using: params)
        connection.stateUpdateHandler = { [readyResult, readySignal, endedSignal] state in
            switch state {
            case .ready:
                if readyResult.value == nil { readyResult.value = true; readySignal.signal() }
            case .failed, .waiting, .cancelled:
                if readyResult.value == nil { readyResult.value = false; readySignal.signal() }
                endedSignal.signal()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func waitReady() -> Bool? {
        _ = readySignal.wait(timeout: .now() + 15)
        return readyResult.value
    }

    /// Whether the connection ended (or a receive failed) within 10 s.
    /// Whether the connection ended within 10 s (messages still queued, like `state`, are skipped).
    func waitEnded() -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let failed = LockedBox(false)
            let done = DispatchSemaphore(value: 0)
            connection.receiveMessage { data, _, _, error in
                failed.value = error != nil || data == nil
                done.signal()
            }
            guard done.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .success else { break }
            if failed.value { return true }
        }
        return endedSignal.wait(timeout: .now() + 1) == .success
    }

    func send(_ data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
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
