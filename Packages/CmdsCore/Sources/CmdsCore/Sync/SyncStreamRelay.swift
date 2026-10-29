import Foundation

/// Copies bytes both ways between two stream pairs (e.g. an L2CAP channel and a loopback TCP socket) until
/// either side ends. It never looks at the bytes: the TLS session inside is end to end.
///
/// Each direction has a bounded buffer; while it is full the relay stops reading that side, so a slow
/// reader pushes back on the writer (Bluetooth or TCP flow control) instead of growing memory. When one
/// input ends, what was already read is written out, then all four streams are closed and `onClose` runs
/// once (on a background queue). Errors close everything at once.
///
/// The streams run on a dedicated thread with its own run loop. `anchors` are kept alive until the relay
/// is closed (a `CBL2CAPChannel` closes when released).
public final class SyncStreamRelay: @unchecked Sendable {
    public typealias StreamPair = (input: InputStream, output: OutputStream)

    private final class Direction {
        let input: InputStream
        let output: OutputStream
        var buffer: [UInt8] = []
        var head = 0
        var inputEnded = false

        init(input: InputStream, output: OutputStream) {
            self.input = input
            self.output = output
        }

        var buffered: Int { buffer.count - head }
    }

    private final class Delegate: NSObject, StreamDelegate {
        weak var relay: SyncStreamRelay?
        func stream(_ stream: Stream, handle event: Stream.Event) { relay?.handle(stream, event: event) }
    }

    public let bufferSize: Int
    private let forward: Direction
    private let backward: Direction
    private var anchors: [AnyObject]
    private let onClose: @Sendable () -> Void
    private let delegate = Delegate()
    private var scratch: [UInt8]

    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var started = false
    /// Only touched on the relay thread.
    private var finished = false
    private var closeRequested = false

    /// Bytes relayed so far (a → b, b → a); for tests and diagnostics.
    public private(set) var bytesForward = 0
    public private(set) var bytesBackward = 0

    public init(_ a: StreamPair, _ b: StreamPair, bufferSize: Int = 64 * 1024, anchors: [AnyObject] = [],
                onClose: @escaping @Sendable () -> Void = {}) {
        self.bufferSize = bufferSize
        forward = Direction(input: a.input, output: b.output)
        backward = Direction(input: b.input, output: a.output)
        self.anchors = anchors
        self.onClose = onClose
        scratch = [UInt8](repeating: 0, count: bufferSize)
    }

    public func start() {
        lock.lock()
        guard !started else { return lock.unlock() }
        started = true
        lock.unlock()
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            run(ready: ready)
        }
        thread.name = "tokyo.n-n.cmds.sync-relay"
        thread.qualityOfService = .userInitiated
        thread.start()
        ready.wait()
    }

    /// Closes both sides now (idempotent, any thread).
    public func close() {
        lock.lock()
        closeRequested = true
        let loop = runLoop
        lock.unlock()
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in finish() }
        CFRunLoopWakeUp(loop)
    }

    // MARK: - Relay thread

    private var streams: [Stream] { [forward.input, forward.output, backward.input, backward.output] }

    private func run(ready: DispatchSemaphore) {
        delegate.relay = self
        let loop = RunLoop.current
        for stream in streams {
            stream.delegate = delegate
            stream.schedule(in: loop, forMode: .default)
        }
        lock.lock()
        runLoop = CFRunLoopGetCurrent()
        let closeEarly = closeRequested
        lock.unlock()
        ready.signal()
        for stream in streams where stream.streamStatus == .notOpen { stream.open() }
        if closeEarly { finish() }
        while !finished {
            autoreleasepool { _ = loop.run(mode: .default, before: .distantFuture) }
        }
    }

    private func handle(_ stream: Stream, event: Stream.Event) {
        guard !finished else { return }
        if event.contains(.errorOccurred) { return finish() }
        if event.contains(.endEncountered) {
            if stream === forward.input { forward.inputEnded = true }
            if stream === backward.input { backward.inputEnded = true }
            // An output that ends cannot take more bytes: nothing left to relay.
            if stream === forward.output || stream === backward.output { return finish() }
        }
        pump(forward, isForward: true)
        pump(backward, isForward: false)
    }

    private func pump(_ d: Direction, isForward: Bool) {
        while !finished {
            var progress = false
            if !d.inputEnded, d.buffered < bufferSize, d.input.hasBytesAvailable {
                let room = bufferSize - d.buffered
                let n = scratch.withUnsafeMutableBufferPointer { d.input.read($0.baseAddress!, maxLength: room) }
                if n > 0 {
                    if d.head > 0, d.head == d.buffer.count {
                        d.buffer.removeAll(keepingCapacity: true)
                        d.head = 0
                    }
                    d.buffer.append(contentsOf: scratch[0..<n])
                    progress = true
                } else if n == 0 {
                    d.inputEnded = true
                } else {
                    return finish()
                }
            }
            if d.buffered > 0, d.output.hasSpaceAvailable {
                let n = d.buffer.withUnsafeBufferPointer { d.output.write($0.baseAddress! + d.head, maxLength: d.buffered) }
                if n > 0 {
                    d.head += n
                    if isForward { bytesForward += n } else { bytesBackward += n }
                    if d.head == d.buffer.count {
                        d.buffer.removeAll(keepingCapacity: true)
                        d.head = 0
                    } else if d.head > bufferSize {
                        d.buffer.removeFirst(d.head)
                        d.head = 0
                    }
                    progress = true
                } else if n < 0 {
                    return finish()
                }
            }
            if d.inputEnded, d.buffered == 0 { return finish() }
            if !progress { return }
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        for stream in streams {
            stream.delegate = nil
            stream.close()
            stream.remove(from: .current, forMode: .default)
        }
        anchors.removeAll()
        let onClose = onClose
        DispatchQueue.global(qos: .utility).async { onClose() }
    }
}

/// Loopback TCP sockets for the Bluetooth relay (127.0.0.1 only).
public enum SyncLoopback {
    public struct SocketError: Error, CustomStringConvertible {
        public var call: String
        public var code: Int32
        public var description: String { "\(call): \(String(cString: strerror(code)))" }
    }

    /// Connects to 127.0.0.1:`port`. `bound` gets the local port after binding and before connecting, so
    /// the peer registry has the entry before the server can see the connection. Blocking (loopback).
    public static func connect(port: UInt16, bound: (UInt16) -> Void) throws -> Int32 {
        let fd = try makeSocket()
        do {
            var local = address(port: 0)
            try check("bind", withSockaddr(&local) { Darwin.bind(fd, $0, $1) })
            let localPort = try boundPort(fd)
            bound(localPort)
            var remote = address(port: port)
            try check("connect", withSockaddr(&remote) { Darwin.connect(fd, $0, $1) })
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    /// Stream pair over a connected socket; closing the streams closes the socket.
    public static func streams(socket fd: Int32) -> SyncStreamRelay.StreamPair {
        var read: Unmanaged<CFReadStream>?
        var write: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocket(kCFAllocatorDefault, fd, &read, &write)
        let input = read!.takeRetainedValue() as InputStream
        let output = write!.takeRetainedValue() as OutputStream
        input.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))
        output.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))
        return (input, output)
    }

    /// Listens on 127.0.0.1 (ephemeral port) and hands out exactly one accepted connection.
    public final class Listener: @unchecked Sendable {
        public let port: UInt16
        private let fd: Int32
        private let queue = DispatchQueue(label: "tokyo.n-n.cmds.sync-loopback")
        private var source: DispatchSourceRead?
        private let lock = NSLock()
        private var closed = false

        public init() throws {
            let fd = try makeSocket()
            do {
                var local = address(port: 0)
                try check("bind", withSockaddr(&local) { Darwin.bind(fd, $0, $1) })
                try check("listen", Darwin.listen(fd, 1))
                port = try boundPort(fd)
            } catch {
                Darwin.close(fd)
                throw error
            }
            self.fd = fd
        }

        /// Calls `handler` once, on a background queue, with the first accepted socket (the caller owns it),
        /// then stops listening. Nil if the listener was closed first.
        public func acceptOne(_ handler: @escaping @Sendable (Int32?) -> Void) {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            var delivered = false
            source.setEventHandler { [weak self] in
                guard let self, !delivered else { return }
                let client = Darwin.accept(self.fd, nil, nil)
                guard client >= 0 else { return }
                delivered = true
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                handler(client)
                self.close()
            }
            source.setCancelHandler { [fd] in Darwin.close(fd) }
            lock.lock()
            if closed {
                lock.unlock()
                handler(nil)
                return
            }
            self.source = source
            lock.unlock()
            source.resume()
        }

        public func close() {
            lock.lock()
            let wasClosed = closed
            closed = true
            let source = self.source
            lock.unlock()
            guard !wasClosed else { return }
            if let source { source.cancel() } else { Darwin.close(fd) }
        }

        deinit { close() }
    }

    // MARK: - Helpers

    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw SocketError(call: "socket", code: errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private static func address(port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        return addr
    }

    private static func withSockaddr(_ addr: inout sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }

    private static func boundPort(_ fd: Int32) throws -> UInt16 {
        var addr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        try check("getsockname", result)
        return UInt16(bigEndian: addr.sin_port)
    }

    private static func check(_ call: String, _ result: Int32) throws {
        if result != 0 { throw SocketError(call: call, code: errno) }
    }
}
