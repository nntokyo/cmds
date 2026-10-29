import CmdsCore
import Foundation
import os

private let log = Logger(subsystem: "tokyo.n-n.cmds", category: "api")

/// Unix-domain stream socket speaking JSON lines (`CmdsCore/RPC.swift`).
///
/// Accepting runs on a private queue; each connection has a reader thread and a serial writer queue,
/// so a slow request on one connection never blocks another. Only peers with our uid are accepted.
/// Requests are handed to `onRequest` on the reader thread; replies go through `Connection.send`.
final class SocketServer: @unchecked Sendable {
    /// Each client gets a reader thread; more connections than this are refused.
    static let maxConnections = 64
    let path: String
    var onRequest: (@Sendable (RPCRequest, SocketConnection) -> Void)?
    var onClose: (@Sendable (SocketConnection) -> Void)?

    private let acceptQueue = DispatchQueue(label: "tokyo.n-n.cmds.api.accept")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let lock = NSLock()
    private var connections: [Int: SocketConnection] = [:]
    private var nextConnectionID = 1

    init(path: String) {
        self.path = path
    }

    func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: directory) {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try removeStaleSocket()
        let fd = try UnixSocket.makeStreamSocket()
        do {
            try UnixSocket.bindAndListen(fd, path: path, backlog: 32)
            guard chmod(path, 0o600) == 0 else { throw UnixSocket.Failure("chmod \(path)") }
        } catch {
            close(fd)
            throw error
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        acceptSource = source
        source.resume()
        log.info("listening on \(self.path, privacy: .public)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { unlink(path) }
        listenFD = -1
        lock.lock()
        let open = Array(connections.values)
        lock.unlock()
        open.forEach { $0.shutdown() }
    }

    // MARK: - Internals

    /// Removes a socket file nobody is listening on. Refuses to touch non-socket files or a live server.
    private func removeStaleSocket() throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else {
            throw UnixSocket.Failure("\(path) exists and is not a socket", code: EEXIST)
        }
        if let probe = try? UnixSocket.makeStreamSocket() {
            defer { close(probe) }
            if (try? UnixSocket.connect(probe, path: path)) != nil {
                throw UnixSocket.Failure("another cmds instance is listening on \(path)", code: EADDRINUSE)
            }
        }
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return // EAGAIN: drained
            }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
                log.error("rejected connection from uid \(uid)")
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            lock.lock()
            guard connections.count < Self.maxConnections else {
                lock.unlock()
                log.error("rejected connection: \(Self.maxConnections) clients already connected")
                close(fd)
                continue
            }
            let id = nextConnectionID
            nextConnectionID += 1
            let connection = SocketConnection(id: id, fd: fd)
            connections[id] = connection
            lock.unlock()

            let thread = Thread { [weak self] in
                connection.readLoop { request in self?.onRequest?(request, connection) }
                self?.connectionDidClose(connection)
            }
            thread.name = "cmds.api.connection.\(id)"
            thread.start()
        }
    }

    private func connectionDidClose(_ connection: SocketConnection) {
        lock.lock()
        connections[connection.id] = nil
        lock.unlock()
        onClose?(connection)
    }
}

/// One client. Closed (after queued writes) once the peer has stopped sending and every request is answered,
/// or immediately when the peer is gone.
final class SocketConnection: @unchecked Sendable {
    /// Writes queued but not yet sent beyond this many bytes mean the client stopped reading; it gets dropped.
    static let maxPendingBytes = 32 * 1024 * 1024
    /// Requests a client may have in flight; further ones are answered with an error until some finish.
    static let maxOutstanding = 64

    let id: Int
    private let fd: Int32
    private let writeQueue: DispatchQueue
    private let lock = NSLock()
    private var isClosed = false
    private var isReleased = false
    private var pendingBytes = 0
    /// Requests handed to the dispatcher that have not been answered yet.
    private var outstanding = 0
    /// The peer finished sending (EOF); we still answer outstanding requests (half-close).
    private var readFinished = false
    /// A write failed or the connection was dropped: nothing more can be delivered.
    private var isBroken = false

    init(id: Int, fd: Int32) {
        self.id = id
        self.fd = fd
        writeQueue = DispatchQueue(label: "tokyo.n-n.cmds.api.write.\(id)")
    }

    /// True once the connection is finished; further replies and events are dropped.
    var closed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isClosed
    }

    /// Answers a request passed to the dispatcher (exactly once per request).
    func reply(id: Int, result: JSONValue?) {
        send(RPCResponse(id: id, result: result ?? .object([:])))
        requestDidFinish()
    }

    func reply(id: Int, error: RPCError) {
        send(RPCResponse(id: id, error: error))
        requestDidFinish()
    }

    private func requestDidFinish() {
        lock.lock()
        outstanding = max(0, outstanding - 1)
        lock.unlock()
        finishIfIdle()
    }

    /// Closes once the peer stopped sending and every request has been answered (or the peer is gone).
    private func finishIfIdle() {
        lock.lock()
        guard !isClosed, readFinished, outstanding == 0 || isBroken else {
            lock.unlock()
            return
        }
        isClosed = true
        lock.unlock()
        // Flush what is queued, then release the descriptor.
        writeQueue.async { [self] in
            lock.lock()
            isReleased = true
            close(fd)
            lock.unlock()
        }
    }

    func send<T: Encodable>(_ message: T) {
        guard let data = try? JSONLineBuffer.encodeLine(message) else { return }
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        pendingBytes += data.count
        let overflow = pendingBytes > Self.maxPendingBytes
        lock.unlock()
        if overflow {
            log.error("connection \(self.id) is not reading; dropping it")
            shutdown()
            return
        }
        writeQueue.async { [self] in
            if (try? UnixSocket.writeAll(fd, data)) == nil { shutdown() }
            lock.lock()
            pendingBytes -= data.count
            lock.unlock()
        }
    }

    /// Drops the connection: wakes the reader thread and stops waiting for outstanding replies.
    func shutdown() {
        lock.lock()
        isBroken = true
        if !isReleased { Darwin.shutdown(fd, SHUT_RDWR) }
        lock.unlock()
        finishIfIdle()
    }

    /// Reads request lines until EOF, error or an oversized line. Runs on the connection's thread.
    func readLoop(_ handle: (RPCRequest) -> Void) {
        var buffer = JSONLineBuffer()
        var dropped = false
        reading: while true {
            let chunk: Data
            do {
                chunk = try UnixSocket.read(fd)
            } catch {
                dropped = true
                break reading
            }
            if chunk.isEmpty { break } // EOF; the peer may still be reading (half-close)
            let lines: [Data]
            do {
                lines = try buffer.append(chunk)
            } catch {
                send(RPCResponse(id: 0, error: RPCError(code: -32600, message: "request too large (max \(JSONLineBuffer.defaultMaxLineLength) bytes)")))
                dropped = true
                break reading
            }
            for line in lines {
                if let request = try? JSONDecoder().decode(RPCRequest.self, from: line) {
                    lock.lock()
                    let busy = outstanding >= Self.maxOutstanding
                    if !busy { outstanding += 1 }
                    lock.unlock()
                    if busy {
                        send(RPCResponse(id: request.id, error: RPCError(code: 429, message: "too many requests in flight (max \(Self.maxOutstanding))")))
                    } else {
                        handle(request)
                    }
                } else {
                    let value = try? JSONDecoder().decode(JSONValue.self, from: line)
                    let id = value?["id"]?.intValue ?? 0
                    send(RPCResponse(id: id, error: value == nil
                          ? RPCError(code: -32700, message: "parse error: invalid JSON")
                          : RPCError(code: -32600, message: "invalid request: expected {\"id\": Int, \"method\": String, \"params\"?: …}")))
                }
            }
        }
        lock.lock()
        readFinished = true
        if dropped { isBroken = true }
        lock.unlock()
        finishIfIdle()
    }
}
