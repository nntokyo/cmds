import Foundation

/// Small POSIX helpers shared by the app's socket server and `CmdsClient`.
public enum UnixSocket {
    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let operation: String
        public let code: Int32

        public init(_ operation: String, code: Int32 = errno) {
            self.operation = operation
            self.code = code
        }

        public var description: String { "\(operation): \(String(cString: strerror(code)))" }
    }

    /// Builds a `sockaddr_un` for `path`; throws if the path does not fit (104 bytes on Darwin).
    public static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw Failure("socket path too long (\(bytes.count) bytes)", code: ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// Creates a stream socket with `SO_NOSIGPIPE` (writing to a closed peer returns EPIPE instead of raising SIGPIPE).
    public static func makeStreamSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("socket") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Connects `fd` to the socket at `path`.
    public static func connect(_ fd: Int32, path: String) throws {
        var address = try address(for: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw Failure("connect \(path)") }
    }

    /// Binds `fd` to `path` and starts listening.
    public static func bindAndListen(_ fd: Int32, path: String, backlog: Int32 = 16) throws {
        var address = try address(for: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw Failure("bind \(path)") }
        guard Darwin.listen(fd, backlog) == 0 else { throw Failure("listen") }
    }

    /// Writes all of `data`, retrying on EINTR and partial writes.
    public static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw Failure("write")
                }
                pointer += written
                remaining -= written
            }
        }
    }

    /// Reads up to `capacity` bytes. Returns empty data on EOF; retries on EINTR.
    public static func read(_ fd: Int32, capacity: Int = 64 * 1024) throws -> Data {
        var chunk = Data(count: capacity)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, capacity) }
            if count >= 0 { return chunk.prefix(count) }
            if errno == EINTR { continue }
            throw Failure("read")
        }
    }

    /// Sets the receive timeout (`nil` = block forever).
    public static func setReceiveTimeout(_ fd: Int32, _ timeout: TimeInterval?) {
        let seconds = max(0, timeout ?? 0)
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }
}
