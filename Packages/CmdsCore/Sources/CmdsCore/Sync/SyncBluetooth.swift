import Foundation

/// Bluetooth fallback (docs/internals/sync-protocol.md "Bluetooth"). Bluetooth is only a byte pipe: an L2CAP channel that
/// carries the very same TLS 1.3 WebSocket session as the network path, so the phone still checks the
/// Mac's pinned certificate end to end and Bluetooth link encryption is defence in depth only.
///
/// The Mac is a GATT peripheral advertising `serviceUUID`. Its `infoCharacteristicUUID` (readable without
/// pairing, like the Bonjour TXT record) carries `Info`: the L2CAP PSM to open and hints for choosing
/// between several Macs. Hints are never trusted; a wrong Mac fails the pinned TLS handshake.
public enum SyncBluetooth {
    public static let serviceUUID = "8C3E5A70-2F4B-4E1D-9B6A-5D0C7E1F3A21"
    public static let infoCharacteristicUUID = "8C3E5A71-2F4B-4E1D-9B6A-5D0C7E1F3A21"

    /// Screen updates per connection are sent at most this often over Bluetooth (4 Hz; the network path
    /// uses the server's tick). Changes in between are coalesced into one diff.
    public static let screenInterval: TimeInterval = 0.25

    /// Prefix of the per-peer host label the Mac uses for relayed connections (rate limits, display).
    public static let peerHostPrefix = "bluetooth:"

    /// Contents of the info characteristic: `version(1) | psm(UInt16 LE) | fingerprint prefix(8) | name (UTF-8)`.
    public struct Info: Equatable, Sendable {
        public static let version: UInt8 = 1
        public static let fingerprintHintBytes = 8
        public static let maxNameBytes = 64

        public var psm: UInt16
        /// First bytes of the Mac's certificate fingerprint. A hint for picking the paired Mac only.
        public var fingerprintHint: Data
        public var name: String

        public init(psm: UInt16, fingerprint: SyncFingerprint, name: String) {
            self.psm = psm
            fingerprintHint = Data(fingerprint.bytes.prefix(Self.fingerprintHintBytes))
            self.name = Self.truncated(name)
        }

        public var encoded: Data {
            var data = Data([Self.version, UInt8(psm & 0xFF), UInt8(psm >> 8)])
            data.append(fingerprintHint)
            data.append(Data(name.utf8))
            return data
        }

        /// Nil for other versions or malformed values.
        public init?(encoded data: Data) {
            let bytes = Array(data)
            let header = 3 + Self.fingerprintHintBytes
            guard bytes.count >= header, bytes.count <= header + Self.maxNameBytes, bytes[0] == Self.version else { return nil }
            psm = UInt16(bytes[1]) | UInt16(bytes[2]) << 8
            guard psm != 0 else { return nil }
            fingerprintHint = Data(bytes[3..<header])
            name = String(decoding: bytes[header...], as: UTF8.self)
        }

        /// Whether this Mac advertises the pinned identity (hint only; TLS pinning decides).
        public func matches(_ fingerprint: SyncFingerprint) -> Bool {
            fingerprintHint == fingerprint.bytes.prefix(Self.fingerprintHintBytes)
        }

        private static func truncated(_ name: String) -> String {
            var result = ""
            for character in name {
                guard result.utf8.count + character.utf8.count <= maxNameBytes else { break }
                result.append(character)
            }
            return result
        }
    }
}

/// Maps local ports of relayed loopback connections to the peer they carry, so the sync server can keep
/// per-peer limits for them instead of lumping every relayed peer together as "127.0.0.1". The relay
/// registers the port after binding its socket and before connecting, so the entry exists before the
/// server can accept the connection. Only this process can register ports; any other loopback client
/// stays "127.0.0.1". Thread-safe.
public final class SyncLoopbackPeers: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [UInt16: String] = [:]

    public init() {}

    public func register(port: UInt16, peer: String) {
        lock.lock()
        peers[port] = peer
        lock.unlock()
    }

    public func unregister(port: UInt16) {
        lock.lock()
        peers[port] = nil
        lock.unlock()
    }

    public func peer(forPort port: UInt16) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return peers[port]
    }
}
