import CmdsSSH
import CryptoKit
import Foundation
import Security
import UIKit

/// Remote access via SSH for one Mac (docs/SYNC.md "Remote access via SSH"): the relay host the Mac
/// forwards its sync port to, and the relay's pinned host key. Nothing secret (the phone's key is in the
/// Keychain, the Mac's token stays with its pairing), so it is kept in UserDefaults per `MacTarget.id`.
struct RemoteAccessConfig: Codable, Equatable {
    var enabled: Bool
    var endpoint: SSHRelayEndpoint
    /// Relay host key (OpenSSH line) the user confirmed, and the `host:port` it was confirmed for.
    var hostKey: String?
    var hostKeyFor: String?

    init(enabled: Bool = false, endpoint: SSHRelayEndpoint = SSHRelayEndpoint(host: "", user: "")) {
        self.enabled = enabled
        self.endpoint = endpoint
    }

    var hostKeyID: String { "\(endpoint.host):\(endpoint.port)" }

    /// The pin, if it was confirmed for the current host and port.
    var pinnedHostKey: String? {
        guard let hostKey, !hostKey.isEmpty, hostKeyFor == hostKeyID else { return nil }
        return hostKey
    }

    /// Ready to be used as a fallback path.
    var isUsable: Bool { enabled && endpoint.isComplete && pinnedHostKey != nil }
}

enum RemoteAccessStore {
    private static func key(_ targetID: String) -> String { "remoteAccess." + targetID }

    static func config(for targetID: String) -> RemoteAccessConfig? {
        guard let data = UserDefaults.standard.data(forKey: key(targetID)) else { return nil }
        return try? JSONDecoder().decode(RemoteAccessConfig.self, from: data)
    }

    static func save(_ config: RemoteAccessConfig, for targetID: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(config), forKey: key(targetID))
    }

    static func delete(for targetID: String) {
        UserDefaults.standard.removeObject(forKey: key(targetID))
    }

    /// Relay ports of every Mac set up on this phone (the phone key's authorized_keys line allows them all).
    static func allRelayPorts() -> [UInt16] {
        UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("remoteAccess.") }.sorted()
            .compactMap { UserDefaults.standard.data(forKey: $0) }
            .compactMap { try? JSONDecoder().decode(RemoteAccessConfig.self, from: $0) }
            .map(\.endpoint.relayPort)
    }
}

/// The phone's SSH key: Ed25519, generated on the phone, stored in the Keychain for this device only
/// (never in backups that move to another device, never exported except its public half).
enum PhoneSSHKey {
    private static let service = "tokyo.n-n.cmds.companion.ssh-key"
    private static let account = "ed25519"

    static func load() -> Curve25519.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    /// The stored key, or a new one. Nil if the Keychain refuses to store it (then nothing is used).
    static func loadOrCreate() -> Curve25519.Signing.PrivateKey? {
        if let existing = load() { return existing }
        let key = Curve25519.Signing.PrivateKey()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key.rawRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            pairingLog.error("could not save the SSH key: OSStatus \(status, privacy: .public)")
            return nil
        }
        return key
    }

    /// Deletes the key; the next use creates a new one (which must be added to the relay again).
    static func reset() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static var comment: String {
        let name = UIDevice.current.name.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "cmds-" + (name.isEmpty ? "iphone" : name)
    }

    /// `authorized_keys` line limited to what cmds needs: forwarding to the relay port only, no shell,
    /// no agent or X11 forwarding, no pty.
    static func restrictedAuthorizedKeysLine(_ key: Curve25519.Signing.PublicKey, relayPort: UInt16) -> String {
        SSHKeys.restrictedAuthorizedKeysLine(for: key, relayPorts: [relayPort] + RemoteAccessStore.allRelayPorts(), comment: comment)
    }
}
