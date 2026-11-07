import Foundation
@testable import CmdsCore

/// A small SFTP v3 server for tests, behaving like OpenSSH's sftp-server on a real temporary folder, connected to an
/// `SFTPClient` through two pipes (no network, no ssh). Paths are the Mac's real paths; `home` is what `realpath(".")`
/// answers. Faults can be injected: short reads, a write error, dropping the connection.
final class SFTPTestServer: @unchecked Sendable {
    let home: String
    let client: SFTPClient
    private let readFD: Int32
    private let writeFD: Int32
    private var handles: [UInt32: Handle] = [:]
    private var nextHandle: UInt32 = 1
    private let lock = NSLock()

    /// Reads return at most this many bytes (tests short replies).
    var maxRead: Int?
    /// Fail WRITE requests once this many bytes have been written in total.
    var failWritesAfter: Int?
    /// Close the connection after this many requests.
    var dropAfterRequests: Int?
    /// Delay before each READ/WRITE reply (slows transfers so tests can pause and cancel).
    var ioDelay: TimeInterval = 0
    /// Offer OpenSSH's `posix-rename@openssh.com` in `VERSION` (set before `connect()`), as OpenSSH does.
    var offersPosixRename = true
    /// Requests seen, by packet type (tests check that nothing is removed that should not be).
    private(set) var removed: [String] = []
    private(set) var renamed: [(String, String)] = []
    private var bytesWritten = 0
    private var requests = 0
    /// Guards `stopped`; stop() is called by tearDown and by the server thread when its input ends.
    private let stopLock = NSLock()
    private var stopped = false

    enum Handle {
        case file(Int32)
        case directory(path: String, sent: Bool)
    }

    init(home: String) {
        self.home = home
        var toServer: [Int32] = [0, 0]
        var toClient: [Int32] = [0, 0]
        pipe(&toServer)
        pipe(&toClient)
        readFD = toServer[0]
        writeFD = toClient[1]
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
        let transport = FileDescriptorTransport(readFD: toClient[0], writeFD: toServer[1])
        transport.reasonProvider = { "test server closed the connection" }
        client = SFTPClient(transport: transport)
        let thread = Thread { [self] in
            serve()
            stop()
            // Only this thread uses the descriptors, so it frees them, once, after its last read and write (#122).
            Darwin.close(readFD)
            Darwin.close(writeFD)
        }
        thread.name = "sftp-test-server"
        thread.start()
    }

    /// Connected client and tree (after the handshake).
    func connect() throws -> SFTPFileTree {
        try client.start()
        return SFTPFileTree(client: client, home: try client.realpath("."))
    }

    /// Ends the connection; the client sees it closed. Safe more than once and from any thread: like
    /// `FileDescriptorTransport.close`, /dev/null takes the place of the pipes, which ends a read blocked in the server
    /// thread without freeing the numbers. Closing them here let a second stop close descriptors that a later test's
    /// pipe() had been given ("test server closed the connection" in an unrelated test, #122).
    func stop() {
        stopLock.lock()
        defer { stopLock.unlock() }
        guard !stopped else { return }
        stopped = true
        let null = open("/dev/null", O_RDWR)
        dup2(null, readFD)
        dup2(null, writeFD)
        Darwin.close(null)
    }

    // MARK: - Loop

    private func serve() {
        while true {
            guard let header = readExactly(4) else { return stop() }
            let length = Int(header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard let payload = readExactly(length) else { return stop() }
            var reader = SFTP.Reader(payload)
            guard let type = try? reader.byte() else { return stop() }
            if type == SFTP.PacketType.initialize.rawValue {
                let posixRename = offersPosixRename
                send(SFTP.packet(.version) { writer in
                    writer.uint32(3)
                    if posixRename {
                        writer.string(SFTPClient.posixRenameExtension)
                        writer.string("1")
                    }
                })
                continue
            }
            requests += 1
            if let drop = dropAfterRequests, requests > drop { return stop() }
            guard let id = try? reader.uint32() else { return stop() }
            handle(type: type, id: id, reader: &reader)
        }
    }

    private func readExactly(_ count: Int) -> Data? {
        var data = Data(count: count)
        var filled = 0
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            while filled < count {
                let got = read(readFD, buffer.baseAddress! + filled, count - filled)
                if got <= 0 { return false }
                filled += got
            }
            return true
        }
        return ok ? data : nil
    }

    private func send(_ packet: Data) {
        packet.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(writeFD, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    private func status(_ id: UInt32, _ code: SFTP.StatusCode, _ message: String = "") {
        send(SFTP.packet(.status) { w in
            w.uint32(id)
            w.uint32(code.rawValue)
            w.string(message)
            w.string("")
        })
    }

    private func errnoStatus(_ id: UInt32) {
        switch errno {
        case ENOENT, ENOTDIR: status(id, .noSuchFile, "No such file")
        case EACCES, EPERM: status(id, .permissionDenied, "Permission denied")
        default: status(id, .failure, "Failure")
        }
    }

    private static func attributes(_ info: stat) -> SFTP.Attributes {
        SFTP.Attributes(size: UInt64(info.st_size), uid: info.st_uid, gid: info.st_gid, permissions: UInt32(info.st_mode),
                        accessTime: UInt32(info.st_atimespec.tv_sec), modificationTime: UInt32(info.st_mtimespec.tv_sec))
    }

    private func attrsReply(_ id: UInt32, _ info: stat) {
        send(SFTP.packet(.attrs) { w in
            w.uint32(id)
            w.attributes(Self.attributes(info))
        })
    }

    private func newHandle(_ value: Handle) -> Data {
        lock.lock()
        defer { lock.unlock() }
        let id = nextHandle
        nextHandle += 1
        handles[id] = value
        var writer = SFTP.Writer()
        writer.uint32(id)
        return writer.data
    }

    private func lookup(_ raw: Data) -> (UInt32, Handle)? {
        var reader = SFTP.Reader(raw)
        guard let id = try? reader.uint32() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return handles[id].map { (id, $0) }
    }

    private func statPath(_ path: String, _ info: inout Darwin.stat) -> Int32 { stat(path, &info) }

    private func handle(type: UInt8, id: UInt32, reader: inout SFTP.Reader) {
        guard let packetType = SFTP.PacketType(rawValue: type) else { return status(id, .unsupported) }
        do {
            switch packetType {
            case .realpath:
                var path = try reader.string()
                if path == "." || path.isEmpty { path = home }
                if !path.hasPrefix("/") { path = (home as NSString).appendingPathComponent(path) }
                var resolved = (path as NSString).standardizingPath
                // Like OpenSSH, a link (here: the last component only) is resolved.
                if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: resolved) {
                    resolved = target.hasPrefix("/") ? target
                        : ((resolved as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target)
                }
                send(SFTP.packet(.name) { w in
                    w.uint32(id)
                    w.uint32(1)
                    w.string(resolved)
                    w.string(resolved)
                    w.attributes(SFTP.Attributes())
                })
            case .stat, .lstat:
                let path = try reader.string()
                var info = Darwin.stat()
                let result: Int32 = packetType == .stat ? statPath(path, &info) : lstat(path, &info)
                guard result == 0 else { return errnoStatus(id) }
                attrsReply(id, info)
            case .fstat:
                guard let (_, handle) = lookup(try reader.bytes()), case .file(let fd) = handle else { return status(id, .failure) }
                var info = Darwin.stat()
                guard fstat(fd, &info) == 0 else { return errnoStatus(id) }
                attrsReply(id, info)
            case .opendir:
                let path = try reader.string()
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return status(id, .noSuchFile) }
                guard isDirectory.boolValue else { return status(id, .failure, "Not a directory") }
                let handle = newHandle(.directory(path: path, sent: false))
                send(SFTP.packet(.handle) { w in w.uint32(id); w.bytes(handle) })
            case .readdir:
                guard let (key, handle) = lookup(try reader.bytes()), case .directory(let path, let sent) = handle else {
                    return status(id, .failure)
                }
                if sent { return status(id, .eof) }
                lock.lock()
                handles[key] = .directory(path: path, sent: true)
                lock.unlock()
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []) + [".", ".."]
                send(SFTP.packet(.name) { w in
                    w.uint32(id)
                    w.uint32(UInt32(names.count))
                    for name in names {
                        var info = Darwin.stat()
                        lstat((path as NSString).appendingPathComponent(name), &info)
                        w.string(name)
                        w.string("-rw-r--r-- 1 u g 0 Jan 1 00:00 \(name)")
                        w.attributes(Self.attributes(info))
                    }
                })
            case .close:
                guard let (key, handle) = lookup(try reader.bytes()) else { return status(id, .failure) }
                if case .file(let fd) = handle { Darwin.close(fd) }
                lock.lock()
                handles[key] = nil
                lock.unlock()
                status(id, .ok)
            case .open:
                let path = try reader.string()
                let flags = SFTP.OpenFlags(rawValue: try reader.uint32())
                let attributes = try reader.attributes()
                var mode: Int32 = flags.contains(.write) ? (flags.contains(.read) ? O_RDWR : O_WRONLY) : O_RDONLY
                if flags.contains(.create) { mode |= O_CREAT }
                if flags.contains(.exclusive) { mode |= O_EXCL }
                if flags.contains(.truncate) { mode |= O_TRUNC }
                if flags.contains(.append) { mode |= O_APPEND }
                let fd = Darwin.open(path, mode, mode_t(attributes.permissions ?? 0o644) & 0o777)
                guard fd >= 0 else { return errnoStatus(id) }
                let handle = newHandle(.file(fd))
                send(SFTP.packet(.handle) { w in w.uint32(id); w.bytes(handle) })
            case .read:
                guard let (_, handle) = lookup(try reader.bytes()), case .file(let fd) = handle else { return status(id, .failure) }
                let offset = try reader.uint64()
                var length = Int(try reader.uint32())
                if let maxRead { length = min(length, maxRead) }
                if ioDelay > 0 { Thread.sleep(forTimeInterval: ioDelay) }
                var buffer = Data(count: length)
                let got = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, length, off_t(offset)) }
                guard got >= 0 else { return errnoStatus(id) }
                if got == 0 { return status(id, .eof) }
                send(SFTP.packet(.data) { w in w.uint32(id); w.bytes(buffer.prefix(got)) })
            case .write:
                guard let (_, handle) = lookup(try reader.bytes()), case .file(let fd) = handle else { return status(id, .failure) }
                let offset = try reader.uint64()
                let data = try reader.bytes()
                if ioDelay > 0 { Thread.sleep(forTimeInterval: ioDelay) }
                if let limit = failWritesAfter, bytesWritten + data.count > limit { return status(id, .failure, "No space left on device") }
                let written = data.withUnsafeBytes { pwrite(fd, $0.baseAddress!, data.count, off_t(offset)) }
                guard written == data.count else { return errnoStatus(id) }
                bytesWritten += data.count
                status(id, .ok)
            case .mkdir:
                let path = try reader.string()
                let attributes = try reader.attributes()
                guard mkdir(path, mode_t(attributes.permissions ?? 0o755) & 0o777) == 0 else { return errnoStatus(id) }
                status(id, .ok)
            case .rename:
                let old = try reader.string()
                let new = try reader.string()
                // Like OpenSSH: never replaces an existing item.
                var info = Darwin.stat()
                if lstat(new, &info) == 0 { return status(id, .failure, "Failure") }
                guard Darwin.rename(old, new) == 0 else { return errnoStatus(id) }
                renamed.append((old, new))
                status(id, .ok)
            case .extended:
                let name = try reader.string()
                guard name == SFTPClient.posixRenameExtension, offersPosixRename else { return status(id, .unsupported) }
                let old = try reader.string()
                let new = try reader.string()
                // rename(2): replaces an existing file.
                guard Darwin.rename(old, new) == 0 else { return errnoStatus(id) }
                renamed.append((old, new))
                status(id, .ok)
            case .remove:
                let path = try reader.string()
                guard unlink(path) == 0 else { return errnoStatus(id) }
                removed.append(path)
                status(id, .ok)
            case .rmdir:
                status(id, .unsupported)
            case .readlink:
                let path = try reader.string()
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return errnoStatus(id) }
                send(SFTP.packet(.name) { w in
                    w.uint32(id); w.uint32(1); w.string(target); w.string(target); w.attributes(SFTP.Attributes())
                })
            case .symlink:
                // OpenSSH order: target first, then the link's path.
                let target = try reader.string()
                let link = try reader.string()
                guard Darwin.symlink(target, link) == 0 else { return errnoStatus(id) }
                status(id, .ok)
            case .setstat:
                let path = try reader.string()
                let attributes = try reader.attributes()
                if let permissions = attributes.permissions { chmod(path, mode_t(permissions & 0o7777)) }
                if let mtime = attributes.modificationTime {
                    var times = [timeval(tv_sec: Int(attributes.accessTime ?? mtime), tv_usec: 0),
                                 timeval(tv_sec: Int(mtime), tv_usec: 0)]
                    utimes(path, &times)
                }
                status(id, .ok)
            default:
                status(id, .unsupported)
            }
        } catch {
            status(id, .badMessage)
        }
    }
}
