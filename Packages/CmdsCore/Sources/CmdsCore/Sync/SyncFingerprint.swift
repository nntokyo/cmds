import CryptoKit
import Foundation

/// SHA-256 of the Mac's sync certificate (DER). The phone pins it per Mac at pairing time and accepts
/// no other certificate afterwards (`SyncTLS`).
public struct SyncFingerprint: Hashable, Sendable, CustomStringConvertible {
    public static let byteCount = 32

    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = Data(bytes)
    }

    /// Fingerprint of a DER certificate.
    public init(certificate der: Data) {
        bytes = Data(SHA256.hash(data: der))
    }

    /// Parses the unpadded base64url form (`base64url`).
    public init?(base64url: String) {
        guard let data = Base64URL.decode(base64url) else { return nil }
        self.init(bytes: data)
    }

    /// Unpadded base64url (43 characters): QR payload, Bonjour TXT hint, phone storage.
    public var base64url: String { Base64URL.encode(bytes) }

    /// First 48 bits as "A1B2-C3D4-E5F6", for people to compare when pairing without the QR code.
    /// Shown by both the Mac and the phone. Weaker than the full fingerprint the QR code carries.
    public var short: String {
        let hex = bytes.prefix(6).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { offset -> String in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: "-")
    }

    /// Full fingerprint as colon-separated uppercase hex (diagnostics, `openssl x509 -fingerprint -sha256`).
    public var hex: String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Compares without an early exit. Fingerprints are not secret; this just keeps every check uniform.
    public func matches(_ other: SyncFingerprint) -> Bool {
        let a = Array(bytes), b = Array(other.bytes)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    public var description: String { short }
}

extension SyncFingerprint: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = SyncFingerprint(base64url: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a base64url SHA-256 fingerprint")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(base64url)
    }
}

/// Unpadded base64url (RFC 4648 §5).
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Strict decoding: only the base64url alphabet, no padding, canonical trailing bits.
    public static func decode(_ string: String) -> Data? {
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
        guard string.utf8.allSatisfy(alphabet.contains), string.utf8.count % 4 != 1 else { return nil }
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), encode(data) == string else { return nil }
        return data
    }
}
