import Foundation

/// Contents of the Mac's pairing QR code:
///
///     cmds-pair:v2?name=<Bonjour name>&host=<IP or .local host>&port=<port>&fp=<SHA-256, base64url>&code=<6 digits>
///
/// The phone pins `fingerprint` before it connects and sends `code` only over a TLS connection whose
/// certificate matches it. Values are percent-encoded (only RFC 3986 unreserved characters stay as they
/// are); unknown keys are ignored.
public struct SyncPairingPayload: Equatable, Sendable {
    public static let scheme = "cmds-pair"
    public static let version = "v2"
    /// Upper bound for a payload we try to parse (a real one is ~150 characters).
    public static let maxLength = 1024

    /// Bonjour service name of the Mac (optional; lets the phone use discovery instead of `host`).
    public var name: String?
    public var host: String
    public var port: UInt16
    public var fingerprint: SyncFingerprint
    public var code: String

    public init(name: String?, host: String, port: UInt16, fingerprint: SyncFingerprint, code: String) {
        self.name = name
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
        self.code = code
    }

    public enum ParseError: Error, Equatable {
        /// Not a cmds pairing code at all (other QR code).
        case notPairingPayload
        /// A cmds pairing code of another protocol version.
        case unsupportedVersion(String)
        case missingField(String)
        case invalidField(String)
    }

    /// The text to put into the QR code.
    public var uri: String {
        var items: [(String, String)] = []
        if let name, !name.isEmpty { items.append(("name", name)) }
        items += [("host", host), ("port", String(port)), ("fp", fingerprint.base64url), ("code", code)]
        let query = items.map { "\($0.0)=\(Self.percentEncode($0.1))" }.joined(separator: "&")
        return "\(Self.scheme):\(Self.version)?\(query)"
    }

    public static func parse(_ text: String) throws -> SyncPairingPayload {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = scheme + ":"
        // Schemes are case-insensitive (RFC 3986); compare the ASCII bytes only.
        guard text.utf8.count <= maxLength,
              String(decoding: text.utf8.prefix(prefix.utf8.count), as: UTF8.self).lowercased() == prefix
        else { throw ParseError.notPairingPayload }
        let rest = Substring(String(decoding: text.utf8.dropFirst(prefix.utf8.count), as: UTF8.self))
        let version = rest.prefix { $0 != "?" }
        guard version == Self.version else { throw ParseError.unsupportedVersion(String(version.prefix(16))) }
        let query = rest.dropFirst(version.count + 1)

        var fields: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let key = parts[0].removingPercentEncoding,
                  let value = parts[1].removingPercentEncoding else { throw ParseError.invalidField(String(pair.prefix(16))) }
            // A repeated key would make the result depend on which copy wins.
            guard fields[key] == nil else { throw ParseError.invalidField(key) }
            fields[key] = value
        }

        func required(_ key: String) throws -> String {
            guard let value = fields[key], !value.isEmpty else { throw ParseError.missingField(key) }
            return value
        }
        let host = try required("host")
        guard isValidHost(host) else { throw ParseError.invalidField("host") }
        guard let port = UInt16(try required("port")), port != 0 else { throw ParseError.invalidField("port") }
        guard let fingerprint = SyncFingerprint(base64url: try required("fp")) else { throw ParseError.invalidField("fp") }
        let code = try required("code")
        guard PairingToken.isWellFormedCode(code) else { throw ParseError.invalidField("code") }
        var name: String?
        if let value = fields["name"], !value.isEmpty {
            // Bonjour instance names are at most 63 bytes of UTF-8 and have no control characters.
            guard value.utf8.count <= 63, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw ParseError.invalidField("name") }
            name = value
        }
        return SyncPairingPayload(name: name, host: host, port: port, fingerprint: fingerprint, code: code)
    }

    /// Host name, IPv4 or IPv6 literal (optionally with a %zone); nothing that could change a URL's meaning.
    public static func isValidHost(_ host: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._:%".utf8)
        return !host.isEmpty && host.utf8.count <= 253 && host.utf8.allSatisfy(allowed.contains)
    }

    static func percentEncode(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
