import Foundation

/// SFTP protocol version 3 (draft-ietf-secsh-filexfer-02), the version OpenSSH's sftp-server speaks: packet types,
/// attributes and the binary encoding (docs/internals/files-sftp.md). Pure, so it is unit-tested byte for byte.
public enum SFTP {
    public static let version: UInt32 = 3
    /// Largest packet accepted from the server (OpenSSH's own limit is 256 KiB).
    public static let maxPacketLength = 512 * 1024

    public enum PacketType: UInt8, Sendable {
        case initialize = 1, version = 2, open = 3, close = 4, read = 5, write = 6, lstat = 7, fstat = 8
        case setstat = 9, fsetstat = 10, opendir = 11, readdir = 12, remove = 13, mkdir = 14, rmdir = 15
        case realpath = 16, stat = 17, rename = 18, readlink = 19, symlink = 20
        case status = 101, handle = 102, data = 103, name = 104, attrs = 105
        case extended = 200, extendedReply = 201
    }

    /// `SSH_FXF_*` open flags.
    public struct OpenFlags: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let read = OpenFlags(rawValue: 0x01)
        public static let write = OpenFlags(rawValue: 0x02)
        public static let append = OpenFlags(rawValue: 0x04)
        public static let create = OpenFlags(rawValue: 0x08)
        public static let truncate = OpenFlags(rawValue: 0x10)
        public static let exclusive = OpenFlags(rawValue: 0x20)
    }

    /// `SSH_FX_*` status codes.
    public enum StatusCode: UInt32, Sendable {
        case ok = 0, eof = 1, noSuchFile = 2, permissionDenied = 3, failure = 4, badMessage = 5
        case noConnection = 6, connectionLost = 7, unsupported = 8
    }

    /// File attributes (`ATTRS`); a nil field was not sent.
    public struct Attributes: Equatable, Sendable {
        public var size: UInt64?
        public var uid: UInt32?
        public var gid: UInt32?
        public var permissions: UInt32?
        public var accessTime: UInt32?
        public var modificationTime: UInt32?

        public init(size: UInt64? = nil, uid: UInt32? = nil, gid: UInt32? = nil, permissions: UInt32? = nil,
                    accessTime: UInt32? = nil, modificationTime: UInt32? = nil) {
            self.size = size
            self.uid = uid
            self.gid = gid
            self.permissions = permissions
            self.accessTime = accessTime
            self.modificationTime = modificationTime
        }

        static let sizeFlag: UInt32 = 0x1
        static let uidGidFlag: UInt32 = 0x2
        static let permissionsFlag: UInt32 = 0x4
        static let timesFlag: UInt32 = 0x8
        static let extendedFlag: UInt32 = 0x8000_0000

        /// `S_IFMT` bits of `permissions`.
        public var fileType: FileType {
            guard let permissions else { return .unknown }
            switch permissions & 0o170000 {
            case 0o040000: return .folder
            case 0o100000: return .file
            case 0o120000: return .symlink
            default: return .other
            }
        }

        public enum FileType: Sendable { case file, folder, symlink, other, unknown }

        public var modified: Date? { modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    }

    public struct NameEntry: Equatable, Sendable {
        public var name: String
        public var longName: String
        public var attributes: Attributes
    }

    public enum Response: Equatable, Sendable {
        case version(UInt32, extensions: [String: String])
        case status(id: UInt32, code: UInt32, message: String)
        case handle(id: UInt32, Data)
        case data(id: UInt32, Data)
        case name(id: UInt32, [NameEntry])
        case attrs(id: UInt32, Attributes)
        case extendedReply(id: UInt32, Data)

        public var id: UInt32? {
            switch self {
            case .version: return nil
            case .status(let id, _, _), .handle(let id, _), .data(let id, _), .name(let id, _), .attrs(let id, _),
                 .extendedReply(let id, _):
                return id
            }
        }
    }

    public struct ProtocolError: Error, CustomStringConvertible, Equatable {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    // MARK: - Encoding

    public struct Writer {
        public private(set) var data = Data()

        public init() {}

        public mutating func byte(_ value: UInt8) { data.append(value) }

        public mutating func uint32(_ value: UInt32) {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }

        public mutating func uint64(_ value: UInt64) {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }

        public mutating func bytes(_ value: Data) {
            uint32(UInt32(value.count))
            data.append(value)
        }

        public mutating func string(_ value: String) { bytes(Data(value.utf8)) }

        public mutating func attributes(_ value: Attributes) {
            var flags: UInt32 = 0
            if value.size != nil { flags |= Attributes.sizeFlag }
            if value.uid != nil, value.gid != nil { flags |= Attributes.uidGidFlag }
            if value.permissions != nil { flags |= Attributes.permissionsFlag }
            if value.accessTime != nil, value.modificationTime != nil { flags |= Attributes.timesFlag }
            uint32(flags)
            if let size = value.size { uint64(size) }
            if let uid = value.uid, let gid = value.gid { uint32(uid); uint32(gid) }
            if let permissions = value.permissions { uint32(permissions) }
            if let atime = value.accessTime, let mtime = value.modificationTime { uint32(atime); uint32(mtime) }
        }
    }

    /// A whole packet: length, type, then `body`.
    public static func packet(_ type: PacketType, _ body: (inout Writer) -> Void) -> Data {
        var payload = Writer()
        payload.byte(type.rawValue)
        body(&payload)
        var framed = Writer()
        framed.bytes(payload.data)
        return framed.data
    }

    // MARK: - Decoding

    public struct Reader {
        let data: Data
        var offset: Int

        public init(_ data: Data) {
            self.data = data
            offset = data.startIndex
        }

        public var isAtEnd: Bool { offset >= data.endIndex }

        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, data.endIndex - offset >= count else { throw ProtocolError("truncated packet") }
            let slice = data[offset..<offset + count]
            offset += count
            return Data(slice)
        }

        public mutating func byte() throws -> UInt8 { try take(1).first ?? 0 }

        public mutating func uint32() throws -> UInt32 {
            try take(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }

        public mutating func uint64() throws -> UInt64 {
            try take(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }

        public mutating func bytes() throws -> Data {
            let count = try uint32()
            guard count <= UInt32(SFTP.maxPacketLength) else { throw ProtocolError("string too long") }
            return try take(Int(count))
        }

        /// Names are UTF-8 on every server cmds expects; anything else is shown with replacement characters.
        public mutating func string() throws -> String { String(decoding: try bytes(), as: UTF8.self) }

        public mutating func attributes() throws -> Attributes {
            let flags = try uint32()
            var value = Attributes()
            if flags & Attributes.sizeFlag != 0 { value.size = try uint64() }
            if flags & Attributes.uidGidFlag != 0 {
                value.uid = try uint32()
                value.gid = try uint32()
            }
            if flags & Attributes.permissionsFlag != 0 { value.permissions = try uint32() }
            if flags & Attributes.timesFlag != 0 {
                value.accessTime = try uint32()
                value.modificationTime = try uint32()
            }
            if flags & Attributes.extendedFlag != 0 {
                let count = try uint32()
                guard count < 1024 else { throw ProtocolError("too many extended attributes") }
                for _ in 0..<count {
                    _ = try bytes()
                    _ = try bytes()
                }
            }
            return value
        }
    }

    /// A response packet without its length (`type` byte first).
    public static func decodeResponse(_ payload: Data) throws -> Response {
        var reader = Reader(payload)
        let rawType = try reader.byte()
        guard let type = PacketType(rawValue: rawType) else { throw ProtocolError("unknown packet type \(rawType)") }
        switch type {
        case .version:
            let version = try reader.uint32()
            var extensions: [String: String] = [:]
            while !reader.isAtEnd {
                let name = try reader.string()
                extensions[name] = try reader.string()
            }
            return .version(version, extensions: extensions)
        case .status:
            let id = try reader.uint32()
            let code = try reader.uint32()
            // Message and language tag are optional in very old servers.
            let message = reader.isAtEnd ? "" : try reader.string()
            return .status(id: id, code: code, message: message)
        case .handle:
            return .handle(id: try reader.uint32(), try reader.bytes())
        case .data:
            return .data(id: try reader.uint32(), try reader.bytes())
        case .name:
            let id = try reader.uint32()
            let count = try reader.uint32()
            guard count <= 100_000 else { throw ProtocolError("too many names") }
            var entries: [NameEntry] = []
            for _ in 0..<count {
                let name = try reader.string()
                let longName = try reader.string()
                entries.append(NameEntry(name: name, longName: longName, attributes: try reader.attributes()))
            }
            return .name(id: id, entries)
        case .attrs:
            return .attrs(id: try reader.uint32(), try reader.attributes())
        case .extendedReply:
            let id = try reader.uint32()
            return .extendedReply(id: id, Data(payload[reader.offset...]))
        default:
            throw ProtocolError("unexpected packet type \(rawType) from the server")
        }
    }
}
