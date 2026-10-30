import Crypto
import Foundation
import NIOSSH

/// OpenSSH text formats for the phone's Ed25519 key and for host keys (docs/internals/sync-protocol.md "Remote access via SSH").
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

    /// `authorized_keys` line limited to what cmds needs: `direct-tcpip` to 127.0.0.1:`relayPort` only.
    /// `restrict` turns off pty, agent and X11 forwarding (OpenSSH 7.2+); `port-forwarding` turns forwarding
    /// back on, so `permitopen` limits local forwards and `permitlisten` (7.8+) limits remote listening to a
    /// privileged loopback port; `command="false"` ends any shell or exec request (`restrict` alone allows them).
    /// One key has one line in an `authorized_keys` file (the first match wins), so every relay port the phone
    /// uses with that account goes into the same line.
    public static func restrictedAuthorizedKeysLine(for key: Curve25519.Signing.PublicKey, relayPorts: [UInt16], comment: String) -> String {
        var ports: [UInt16] = []
        for port in relayPorts where port != 0 && !ports.contains(port) { ports.append(port) }
        let open = ports.map { "permitopen=\"127.0.0.1:\($0)\"" }.joined(separator: ",")
        return "restrict,port-forwarding,\(open),permitlisten=\"127.0.0.1:1\",command=\"false\" "
            + authorizedKeysLine(for: key, comment: comment)
    }

    public static func restrictedAuthorizedKeysLine(for key: Curve25519.Signing.PublicKey, relayPort: UInt16, comment: String) -> String {
        restrictedAuthorizedKeysLine(for: key, relayPorts: [relayPort], comment: comment)
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
