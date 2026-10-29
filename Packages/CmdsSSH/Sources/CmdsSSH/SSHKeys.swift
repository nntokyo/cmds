import Crypto
import Foundation
import NIOSSH

/// OpenSSH text formats for the phone's Ed25519 key and for host keys (docs/SYNC.md "Remote access via SSH").
public enum SSHKeys {
    /// `ssh-ed25519 AAAA… comment`: the line the user adds to the relay host's `authorized_keys`.
    public static func authorizedKeysLine(for key: Curve25519.Signing.PublicKey, comment: String) -> String {
        var blob = Data()
        appendString(Data("ssh-ed25519".utf8), to: &blob)
        appendString(key.rawRepresentation, to: &blob)
        let cleaned = comment.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let base = "ssh-ed25519 " + blob.base64EncodedString()
        return cleaned.isEmpty ? base : base + " " + cleaned
    }

    /// OpenSSH form of a host key (`<type> <base64>`), the value stored as the host-key pin.
    public static func openSSH(_ key: NIOSSHPublicKey) -> String {
        String(openSSHPublicKey: key)
    }

    /// `SHA256:<base64 without padding>` like `ssh-keygen -lf`, for an OpenSSH public key line. Nil if the
    /// line is not `<type> <base64> [comment]`.
    public static func fingerprint(openSSHPublicKey line: String) -> String? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        var text = Data(SHA256.hash(data: blob)).base64EncodedString()
        while text.hasSuffix("=") { text.removeLast() }
        return "SHA256:" + text
    }

    /// Whether `presented` is the pinned host key (type and key bytes; comments are ignored).
    public static func matches(pin: String, presented: NIOSSHPublicKey) -> Bool {
        let fields = pin.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, let pinned = try? NIOSSHPublicKey(openSSHPublicKey: fields[0...1].joined(separator: " ")) else {
            return false
        }
        return pinned == presented
    }

    private static func appendString(_ bytes: Data, to data: inout Data) {
        var length = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }
}
