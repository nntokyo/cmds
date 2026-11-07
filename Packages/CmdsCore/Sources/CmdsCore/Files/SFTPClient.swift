import Foundation

/// The byte stream an `SFTPClient` talks over: the stdin/stdout of `ssh -s HOST sftp` (`SSHFileConnection`), or a
/// pipe to a test server.
public protocol SFTPTransport: AnyObject, Sendable {
    /// Writes all of `data` (called under the client's write lock).
    func write(_ data: Data) throws
    /// Exactly `count` bytes; throws at end of stream (called from the client's reader thread only).
    func read(count: Int) throws -> Data
    func close()
    /// Why the stream ended, for the user (e.g. ssh's error classified), once reads have failed; nil if unknown.
    var closeReason: String? { get }
}

/// A transport over two file descriptors (pipes). `close` points both at /dev/null (`dup2`) rather than closing them,
/// so a reader or writer still inside a system call never ends up on a descriptor number the app has reused for
/// another file; they are closed for good when the transport goes away.
public final class FileDescriptorTransport: SFTPTransport, @unchecked Sendable {
    private let readFD: Int32
    private let writeFD: Int32
    private let lock = NSLock()
    private var closed = false
    /// Set by the owner when it learns why the stream ended (ssh's stderr).
    public var reasonProvider: (@Sendable () -> String?)?

    public init(readFD: Int32, writeFD: Int32) {
        self.readFD = readFD
        self.writeFD = writeFD
        // Writing after ssh exited returns EPIPE instead of raising SIGPIPE (which would end the app).
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
    }

    public struct StreamError: Error, CustomStringConvertible {
        public var description: String
    }

    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard var pointer = buffer.baseAddress else { return }
            var left = buffer.count
            while left > 0 {
                let written = Darwin.write(writeFD, pointer, left)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw StreamError(description: "write failed: \(String(cString: strerror(errno)))")
                }
                left -= written
                pointer += written
            }
        }
    }

    public func read(count: Int) throws -> Data {
        var data = Data(count: count)
        var filled = 0
        try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            while filled < count {
                let got = Darwin.read(readFD, base + filled, count - filled)
                if got < 0 {
                    if errno == EINTR { continue }
                    throw StreamError(description: "read failed: \(String(cString: strerror(errno)))")
                }
                if got == 0 { throw StreamError(description: "connection closed") }
                filled += got
            }
        }
        return data
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        let null = open("/dev/null", O_RDWR)
        guard null >= 0 else { return }
        dup2(null, writeFD)
        dup2(null, readFD)
        Darwin.close(null)
    }

    deinit {
        Darwin.close(writeFD)
        Darwin.close(readFD)
    }

    public var closeReason: String? { reasonProvider?() }
}

public enum SFTPError: Error, Equatable, CustomStringConvertible {
    /// The server answered with an error status (`code` as sent; `message` its text).
    case status(code: UInt32, message: String)
    /// The connection is gone; the reason is for the user.
    case disconnected(String)
    case protocolError(String)

    public var statusCode: SFTP.StatusCode? {
        if case .status(let code, _) = self { return SFTP.StatusCode(rawValue: code) }
        return nil
    }

    public var description: String {
        switch self {
        case .status(let code, let message):
            if !message.isEmpty, message.lowercased() != "failure" { return message }
            switch SFTP.StatusCode(rawValue: code) {
            case .noSuchFile: return "No such file or folder"
            case .permissionDenied: return "Permission denied"
            case .unsupported: return "Not supported by the server"
            case .eof: return "End of file"
            default: return message.isEmpty ? "The server reported a failure" : message
            }
        case .disconnected(let reason): return reason
        case .protocolError(let message): return "SFTP protocol error: \(message)"
        }
    }
}

/// SFTP v3 client (docs/internals/files-sftp.md). Requests may be sent from any thread and are answered by id, so
/// one connection serves a listing while a transfer runs; a reader thread matches replies. Calls block the calling
/// thread (never the main thread: the app calls them from background queues and transfer threads).
public final class SFTPClient: @unchecked Sendable {
    /// One request in flight.
    public final class Pending: @unchecked Sendable {
        fileprivate let semaphore = DispatchSemaphore(value: 0)
        fileprivate var result: Result<SFTP.Response, SFTPError>?

        public func wait() throws -> SFTP.Response {
            semaphore.wait()
            return try result!.get()
        }

        fileprivate func finish(_ value: Result<SFTP.Response, SFTPError>) {
            result = value
            semaphore.signal()
        }
    }

    private let transport: SFTPTransport
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var nextID: UInt32 = 1
    private var pending: [UInt32: Pending] = [:]
    private var closedReason: String?
    private var disconnectHandler: (@Sendable (String) -> Void)?
    private var serverExtensions: [String: String] = [:]

    /// Called once (on the thread that noticed) when the connection ends, with the reason for the user.
    public var onDisconnect: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return disconnectHandler }
        set { lock.lock(); disconnectHandler = newValue; lock.unlock() }
    }

    public init(transport: SFTPTransport) {
        self.transport = transport
    }

    /// Extensions the server named in its `VERSION` reply (name → version), e.g. OpenSSH's
    /// `posix-rename@openssh.com`.
    public var extensions: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return serverExtensions
    }

    /// OpenSSH's extension that renames with POSIX `rename(2)`, replacing the target in one step.
    public static let posixRenameExtension = "posix-rename@openssh.com"

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closedReason == nil
    }

    /// `INIT` → `VERSION`, then starts the reader thread. Throws when the server does not speak SFTP v3 or the stream
    /// ends first (ssh failed: wrong host key, no key, …; the transport's `closeReason` says which).
    public func start() throws {
        do {
            try transport.write(SFTP.packet(.initialize) { $0.uint32(SFTP.version) })
            let response = try readResponse()
            guard case .version(let version, let extensions) = response else {
                throw SFTPError.protocolError("expected VERSION")
            }
            guard version >= 3 else { throw SFTPError.protocolError("server speaks SFTP version \(version)") }
            lock.lock()
            serverExtensions = extensions
            lock.unlock()
        } catch let error as SFTPError {
            transport.close()
            throw (error.isStreamEnd ? SFTPError.disconnected(transport.closeReason ?? error.description) : error)
        } catch {
            transport.close()
            throw SFTPError.disconnected(transport.closeReason ?? "\(error)")
        }
        let thread = Thread { [self] in readLoop() }
        thread.name = "cmds.sftp-reader"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Closes the stream; requests in flight fail with `disconnected`.
    public func disconnect(reason: String = "Disconnected") {
        transport.close()
        fail(reason)
    }

    // MARK: - Requests

    /// Sends a request; `body` writes everything after the id.
    public func send(_ type: SFTP.PacketType, _ body: (inout SFTP.Writer) -> Void = { _ in }) -> Pending {
        let request = Pending()
        lock.lock()
        if let closedReason {
            lock.unlock()
            request.finish(.failure(.disconnected(closedReason)))
            return request
        }
        let id = nextID
        nextID = nextID == UInt32.max ? 1 : nextID + 1
        pending[id] = request
        lock.unlock()
        let packet = SFTP.packet(type) { writer in
            writer.uint32(id)
            body(&writer)
        }
        writeLock.lock()
        let written = Result { try transport.write(packet) }
        writeLock.unlock()
        if case .failure(let error) = written {
            // The stream is broken (ssh exited): this request and every other one fails.
            transport.close()
            fail(transport.closeReason ?? "\(error)")
        }
        return request
    }

    private func readResponse() throws -> SFTP.Response {
        let header = try transport.read(count: 4)
        let length = header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard length >= 1, length <= UInt32(SFTP.maxPacketLength) else {
            throw SFTPError.protocolError("bad packet length \(length)")
        }
        let payload = try transport.read(count: Int(length))
        do {
            return try SFTP.decodeResponse(payload)
        } catch let error as SFTP.ProtocolError {
            throw SFTPError.protocolError(error.description)
        }
    }

    private func readLoop() {
        while true {
            do {
                let response = try readResponse()
                guard let id = response.id else { continue }
                lock.lock()
                let request = pending.removeValue(forKey: id)
                lock.unlock()
                request?.finish(.success(response))
            } catch {
                transport.close()
                let reason = transport.closeReason
                    ?? ((error as? SFTPError).map(\.description) ?? "The connection was closed")
                fail(reason)
                return
            }
        }
    }

    private func fail(_ reason: String) {
        lock.lock()
        guard closedReason == nil else {
            lock.unlock()
            return
        }
        closedReason = reason
        let waiting = pending
        pending.removeAll()
        let handler = disconnectHandler
        lock.unlock()
        for request in waiting.values { request.finish(.failure(.disconnected(reason))) }
        handler?(reason)
    }

    // MARK: - Operations

    /// Waits for a status reply and throws unless it is OK.
    public static func expectOK(_ response: SFTP.Response) throws {
        guard case .status(_, let code, let message) = response else {
            throw SFTPError.protocolError("expected STATUS")
        }
        guard code == SFTP.StatusCode.ok.rawValue else { throw SFTPError.status(code: code, message: message) }
    }

    private static func unexpected(_ response: SFTP.Response) -> SFTPError {
        if case .status(_, let code, let message) = response { return .status(code: code, message: message) }
        return .protocolError("unexpected reply")
    }

    /// The absolute, canonical form of `path` (`.` is the login folder, normally the home folder).
    public func realpath(_ path: String) throws -> String {
        let response = try send(.realpath) { $0.string(path) }.wait()
        guard case .name(_, let entries) = response, let first = entries.first else { throw Self.unexpected(response) }
        return first.name
    }

    public func stat(_ path: String) throws -> SFTP.Attributes {
        try attributes(send(.stat) { $0.string(path) }.wait())
    }

    public func lstat(_ path: String) throws -> SFTP.Attributes {
        try attributes(send(.lstat) { $0.string(path) }.wait())
    }

    private func attributes(_ response: SFTP.Response) throws -> SFTP.Attributes {
        guard case .attrs(_, let attributes) = response else { throw Self.unexpected(response) }
        return attributes
    }

    /// Entries of a folder (without `.` and `..`), with the attributes the server sends (of links, not their targets).
    public func list(_ path: String) throws -> [SFTP.NameEntry] {
        let opened = try send(.opendir) { $0.string(path) }.wait()
        guard case .handle(_, let handle) = opened else { throw Self.unexpected(opened) }
        defer { _ = try? close(handle) }
        var entries: [SFTP.NameEntry] = []
        while true {
            let response = try send(.readdir) { $0.bytes(handle) }.wait()
            switch response {
            case .name(_, let batch):
                entries += batch.filter { $0.name != "." && $0.name != ".." }
            case .status(_, let code, _) where code == SFTP.StatusCode.eof.rawValue:
                return entries
            default:
                throw Self.unexpected(response)
            }
        }
    }

    public func mkdir(_ path: String, permissions: UInt32? = nil) throws {
        try Self.expectOK(send(.mkdir) { $0.string(path); $0.attributes(SFTP.Attributes(permissions: permissions)) }.wait())
    }

    /// SFTP v3 rename: fails when `newPath` exists (OpenSSH links and unlinks files, and checks first for others), so
    /// nothing is overwritten.
    public func rename(_ oldPath: String, to newPath: String) throws {
        try Self.expectOK(send(.rename) { $0.string(oldPath); $0.string(newPath) }.wait())
    }

    /// Renames with POSIX semantics (`posix-rename@openssh.com`): an existing file at `newPath` is replaced in one
    /// step, so readers see the old or the new file, never neither. Only for saving an edited file over the one it
    /// came from (`TransferJob` `.save`). Fails with `.unsupported` when the server did not offer the extension.
    public func posixRename(_ oldPath: String, to newPath: String) throws {
        guard extensions[Self.posixRenameExtension] != nil else {
            throw SFTPError.status(code: SFTP.StatusCode.unsupported.rawValue, message: "")
        }
        try Self.expectOK(send(.extended) { writer in
            writer.string(Self.posixRenameExtension)
            writer.string(oldPath)
            writer.string(newPath)
        }.wait())
    }

    /// Removes a file. Used only for a transfer's own temporary file (`.cmds-part-…`), never for the user's files.
    public func remove(_ path: String) throws {
        try Self.expectOK(send(.remove) { $0.string(path) }.wait())
    }

    public func readlink(_ path: String) throws -> String {
        let response = try send(.readlink) { $0.string(path) }.wait()
        guard case .name(_, let entries) = response, let first = entries.first else { throw Self.unexpected(response) }
        return first.name
    }

    /// Creates `linkPath` pointing at `target`. OpenSSH's server takes the two in the opposite order to the draft
    /// (target first), and every common server follows OpenSSH.
    public func symlink(target: String, linkPath: String) throws {
        try Self.expectOK(send(.symlink) { $0.string(target); $0.string(linkPath) }.wait())
    }

    public func setstat(_ path: String, _ attributes: SFTP.Attributes) throws {
        try Self.expectOK(send(.setstat) { $0.string(path); $0.attributes(attributes) }.wait())
    }

    public func open(_ path: String, flags: SFTP.OpenFlags, attributes: SFTP.Attributes = SFTP.Attributes()) throws -> Data {
        let response = try send(.open) { writer in
            writer.string(path)
            writer.uint32(flags.rawValue)
            writer.attributes(attributes)
        }.wait()
        guard case .handle(_, let handle) = response else { throw Self.unexpected(response) }
        return handle
    }

    public func close(_ handle: Data) throws {
        try Self.expectOK(send(.close) { $0.bytes(handle) }.wait())
    }

    /// A read request; its reply is `.data` (possibly shorter than asked) or an EOF status.
    public func read(_ handle: Data, offset: UInt64, length: UInt32) -> Pending {
        send(.read) { writer in
            writer.bytes(handle)
            writer.uint64(offset)
            writer.uint32(length)
        }
    }

    public func write(_ handle: Data, offset: UInt64, data: Data) -> Pending {
        send(.write) { writer in
            writer.bytes(handle)
            writer.uint64(offset)
            writer.bytes(data)
        }
    }
}

extension SFTPError {
    /// The stream ended while starting (ssh exited): the transport's reason says why.
    fileprivate var isStreamEnd: Bool {
        if case .protocolError = self { return false }
        return true
    }
}
