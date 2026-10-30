import Crypto
import Foundation
import Network
import NIOCore
import NIOSSH
import NIOTransportServices

/// The SSH relay host as entered on the phone (docs/internals/sync-protocol.md "Remote access via SSH").
public struct SSHRelayEndpoint: Codable, Hashable, Sendable {
    /// Hostname or address of the relay host.
    public var host: String
    /// Its sshd port.
    public var port: UInt16
    public var user: String
    /// Port on the relay's loopback that the Mac forwards to its sync listener (`ssh -R`).
    public var relayPort: UInt16

    public static let defaultRelayPort: UInt16 = 47_824

    public init(host: String, port: UInt16 = 22, user: String, relayPort: UInt16 = defaultRelayPort) {
        self.host = host
        self.port = port
        self.user = user
        self.relayPort = relayPort
    }

    /// Whether every field is usable.
    public var isComplete: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !user.trimmingCharacters(in: .whitespaces).isEmpty
            && port != 0 && relayPort != 0
    }
}

public enum SSHTunnelError: Error, Equatable, CustomStringConvertible {
    /// No host key is pinned yet: the user must confirm this one (`SSHKeys.fingerprint`) first.
    case unknownHostKey(presented: String)
    /// The relay presented a host key other than the pinned one. Nothing was sent.
    case hostKeyMismatch(presented: String)
    /// The relay did not accept the phone's key (not in `authorized_keys`, wrong user).
    case authenticationFailed
    /// The relay refused the `direct-tcpip` channel: nothing listens on the relay port (Mac offline or its
    /// remote access is off), or forwarding is disabled for this user.
    case forwardRefused(String)
    case connectionFailed(String)
    case timedOut
    case closed

    public var description: String {
        switch self {
        case .unknownHostKey: return "The relay host's key is not confirmed yet."
        case .hostKeyMismatch(let presented):
            return "The relay host presented a different host key (\(SSHKeys.fingerprint(openSSHPublicKey: presented) ?? "?")). Nothing was sent."
        case .authenticationFailed: return "The relay host did not accept this device's SSH key. Add it to authorized_keys."
        case .forwardRefused(let detail):
            return "The relay host could not reach the Mac's forwarded port. Is remote access on and the Mac online? (\(detail))"
        case .connectionFailed(let detail): return "Could not reach the relay host: \(detail)"
        case .timedOut: return "The relay host did not answer in time."
        case .closed: return "The SSH connection was closed."
        }
    }
}

/// An SSH client connection (swift-nio-ssh) to the relay host that carries one `direct-tcpip` channel to
/// `127.0.0.1:<relayPort>` on the relay, exposed to the app as a one-shot loopback listener on the phone.
/// The bytes inside are the pinned TLS session to the Mac; SSH is only the pipe.
///
/// Host key: pinned (OpenSSH line). Without a pin the connection fails with `.unknownHostKey` carrying
/// the presented key so the user can confirm it first. Authentication: the Ed25519 key only (never a password).
public final class SSHTunnel: @unchecked Sendable {
    public let endpoint: SSHRelayEndpoint
    private let group: NIOTSEventLoopGroup
    private let channel: Channel
    private let handler: NIOSSHHandler
    private let outcome: Outcome
    private let lock = NSLock()
    private var listener: Channel?
    private var closed = false

    /// Errors seen by the delegates and handlers; only touched on the channel's event loop.
    final class Outcome: @unchecked Sendable {
        var error: SSHTunnelError?
        let authenticated: EventLoopPromise<Void>
        init(_ promise: EventLoopPromise<Void>) { authenticated = promise }
    }

    private init(endpoint: SSHRelayEndpoint, group: NIOTSEventLoopGroup, channel: Channel, handler: NIOSSHHandler, outcome: Outcome) {
        self.endpoint = endpoint
        self.group = group
        self.channel = channel
        self.handler = handler
        self.outcome = outcome
    }

    /// Connects, checks the host key against `hostKeyPin` and authenticates with `key`.
    public static func connect(to endpoint: SSHRelayEndpoint, key: Curve25519.Signing.PrivateKey, hostKeyPin: String?,
                               timeout: TimeInterval = 15) async throws -> SSHTunnel {
        let group = NIOTSEventLoopGroup(loopCount: 1)
        let loop = group.next()
        let outcome = Outcome(loop.makePromise(of: Void.self))
        let handlerBox = Locked<NIOSSHHandler?>(nil)
        let user = endpoint.user
        let bootstrap = NIOTSConnectionBootstrap(group: loop)
            .connectTimeout(.milliseconds(Int64(timeout * 1000)))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let config = SSHClientConfiguration(userAuthDelegate: KeyAuthentication(user: user, key: key, outcome: outcome),
                                                        serverAuthDelegate: HostKeyCheck(pin: hostKeyPin, outcome: outcome))
                    let ssh = NIOSSHHandler(role: .client(config), allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    handlerBox.value = ssh
                    try channel.pipeline.syncOperations.addHandlers(ssh, ConnectionWatcher(outcome: outcome))
                }
            }
        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: endpoint.host, port: Int(endpoint.port)).get()
        } catch {
            try? await group.shutdownGracefully()
            throw SSHTunnelError.connectionFailed(String(describing: error))
        }
        let deadline = loop.scheduleTask(in: .milliseconds(Int64(timeout * 1000))) {
            if outcome.error == nil { outcome.error = .timedOut }
            outcome.authenticated.fail(SSHTunnelError.timedOut)
            channel.close(promise: nil)
        }
        do {
            try await outcome.authenticated.futureResult.get()
            deadline.cancel()
        } catch {
            deadline.cancel()
            let mapped = try? await loop.submit { outcome.error }.get()
            channel.close(promise: nil)
            try? await group.shutdownGracefully()
            throw mapped.flatMap { $0 } ?? (error as? SSHTunnelError) ?? .connectionFailed(String(describing: error))
        }
        guard let ssh = handlerBox.value else { throw SSHTunnelError.closed }
        return SSHTunnel(endpoint: endpoint, group: group, channel: channel, handler: ssh, outcome: outcome)
    }

    /// Completes when the SSH connection is gone.
    public var closeFuture: EventLoopFuture<Void> { channel.closeFuture }

    /// Opens the `direct-tcpip` channel to the relay port, then listens on 127.0.0.1 (ephemeral port) and
    /// glues the first accepted connection to it; later connections are closed at once. Returns the loopback
    /// port. The listener stays bound until the forwarded channel or the tunnel closes (closing a
    /// Network.framework listener also closes the connections it accepted).
    /// Opening the channel first reports a Mac that is not forwarding as `.forwardRefused`.
    public func openForward() async throws -> UInt16 {
        let loop = channel.eventLoop
        let relayPort = Int(endpoint.relayPort)
        // Only used on the event loop.
        let handler = Locked(handler)
        let sshChannel: Channel
        do {
            sshChannel = try await loop.flatSubmit { () -> EventLoopFuture<Channel> in
                let promise = loop.makePromise(of: Channel.self)
                let type = SSHChannelType.directTCPIP(.init(targetHost: "127.0.0.1", targetPort: relayPort,
                                                             originatorAddress: try! SocketAddress(ipAddress: "127.0.0.1", port: 0)))
                handler.value.createChannel(promise, channelType: type) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(SSHChannelDataUnwrapper())
                    }
                }
                return promise.futureResult
            }.get()
        } catch {
            if !channel.isActive { throw SSHTunnelError.closed }
            throw SSHTunnelError.forwardRefused(String(describing: error))
        }

        let accepted = Locked(false)
        let bootstrap = NIOTSListenerBootstrap(group: loop, childGroup: loop)
            .childChannelInitializer { local in
                guard !accepted.value else { return local.close() }
                accepted.value = true
                let (a, b) = GlueHandler.matchedPair()
                return sshChannel.pipeline.addHandler(b).flatMap {
                    local.pipeline.addHandler(a)
                }
            }
        let listener: Channel
        do {
            listener = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        } catch {
            sshChannel.close(promise: nil)
            throw SSHTunnelError.connectionFailed("loopback listener: \(error)")
        }
        sshChannel.closeFuture.whenComplete { _ in listener.close(promise: nil) }
        let isClosed = lock.withLock {
            self.listener = listener
            return closed
        }
        if isClosed { listener.close(promise: nil) }
        guard let port = listener.localAddress?.port, port > 0 else {
            listener.close(promise: nil)
            throw SSHTunnelError.connectionFailed("loopback listener has no port")
        }
        return UInt16(port)
    }

    /// Closes the SSH connection, its channel and the listener (idempotent).
    public func close() {
        lock.lock()
        guard !closed else { return lock.unlock() }
        closed = true
        let listener = listener
        lock.unlock()
        listener?.close(promise: nil)
        channel.close(promise: nil)
        let group = group
        channel.closeFuture.whenComplete { _ in
            group.shutdownGracefully { _ in }
        }
    }

    deinit { close() }
}

// MARK: - Handlers and delegates

/// A value shared between the caller and the event loop.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

private final class HostKeyCheck: NIOSSHClientServerAuthenticationDelegate {
    let pin: String?
    let outcome: SSHTunnel.Outcome

    init(pin: String?, outcome: SSHTunnel.Outcome) {
        self.pin = pin
        self.outcome = outcome
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = SSHKeys.openSSH(hostKey)
        guard let pin, !pin.isEmpty else {
            outcome.error = .unknownHostKey(presented: presented)
            return validationCompletePromise.fail(SSHTunnelError.unknownHostKey(presented: presented))
        }
        if SSHKeys.matches(pin: pin, presented: hostKey) {
            validationCompletePromise.succeed(())
        } else {
            outcome.error = .hostKeyMismatch(presented: presented)
            validationCompletePromise.fail(SSHTunnelError.hostKeyMismatch(presented: presented))
        }
    }
}

private final class KeyAuthentication: NIOSSHClientUserAuthenticationDelegate {
    let user: String
    let key: Curve25519.Signing.PrivateKey
    let outcome: SSHTunnel.Outcome
    private var offered = false

    init(user: String, key: Curve25519.Signing.PrivateKey, outcome: SSHTunnel.Outcome) {
        self.user = user
        self.key = key
        self.outcome = outcome
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        // Public key only, offered once. A second call means it was refused; never fall back to a password.
        guard !offered, availableMethods.contains(.publicKey) else {
            outcome.error = .authenticationFailed
            return nextChallengePromise.fail(SSHTunnelError.authenticationFailed)
        }
        offered = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: user, serviceName: "ssh-connection",
            offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(ed25519Key: key)))))
    }
}

/// Reports authentication success and connection errors of the SSH connection.
private final class ConnectionWatcher: ChannelInboundHandler {
    typealias InboundIn = Any
    let outcome: SSHTunnel.Outcome

    init(outcome: SSHTunnel.Outcome) { self.outcome = outcome }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { outcome.authenticated.succeed(()) }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if outcome.error == nil { outcome.error = (error as? SSHTunnelError) ?? .connectionFailed(String(describing: error)) }
        outcome.authenticated.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        outcome.authenticated.fail(outcome.error ?? SSHTunnelError.closed)
        context.fireChannelInactive()
    }
}

/// `SSHChannelData` ↔ `ByteBuffer` for the forwarded channel.
private final class SSHChannelDataUnwrapper: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .channel = data.type, case .byteBuffer(let buffer) = data.data else { return }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))), promise: promise)
    }
}

/// Copies reads of one channel to the other with backpressure (from the swift-nio-ssh examples, Apache 2.0).
private final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    private func partnerWrite(_ data: NIOAny) { context?.write(data, promise: nil) }
    private func partnerFlush() { context?.flush() }
    private func partnerClose() { context?.close(promise: nil) }
    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }
    private var partnerWritable: Bool { context?.channel.isWritable ?? false }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner?.partnerWrite(data) }
    func channelReadComplete(context: ChannelHandlerContext) { partner?.partnerFlush() }
    func channelInactive(context: ChannelHandlerContext) { partner?.partnerClose() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { partner?.partnerClose() }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // TLS needs no half-close: end of input ends both sides.
        if let event = event as? ChannelEvent, case .inputClosed = event { partner?.partnerClose() }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}
