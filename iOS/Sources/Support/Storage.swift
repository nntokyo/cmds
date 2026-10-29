import CmdsCore
import Foundation
import Security
import UIKit

/// What the phone keeps per Mac (`MacTarget.id`): the pinned certificate fingerprint and the token the
/// Mac issued over a connection verified against it. Stored together as one Keychain item (this device
/// only), so the token is never used without its pin.
struct MacPairing: Codable, Equatable {
    var fingerprint: SyncFingerprint
    var token: String
}

/// Keychain storage of `MacPairing`s (generic passwords, JSON).
enum PairingStore {
    private static let service = "tokyo.n-n.cmds.companion.pairing.v2"
    /// Tokens of protocol v1, which sent them unencrypted. They are deleted, never sent again.
    private static let legacyService = "tokyo.n-n.cmds.companion.pairing"

    static func pairing(for targetID: String) -> MacPairing? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: targetID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(MacPairing.self, from: data)
    }

    static func isPaired(_ targetID: String) -> Bool {
        pairing(for: targetID) != nil
    }

    static func save(_ pairing: MacPairing, for targetID: String) {
        guard let data = try? JSONEncoder().encode(pairing) else { return }
        delete(for: targetID)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: targetID,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    static func delete(for targetID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: targetID,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Deletes every v1 token; true if there was one (the user has to pair again).
    static func removeLegacyTokens() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}

/// Recently used Macs (non-secret), most recent first.
enum RecentMacs {
    private static let key = "recentMacs"

    static func load() -> [MacTarget] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([MacTarget].self, from: data) else { return [] }
        return list
    }

    static func remember(_ target: MacTarget) {
        guard target.kind != .mock else { return }
        var list = load().filter { $0.id != target.id }
        list.insert(target, at: 0)
        save(Array(list.prefix(8)))
    }

    static func forget(_ target: MacTarget) {
        save(load().filter { $0.id != target.id })
    }

    private static func save(_ list: [MacTarget]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key)
    }
}

enum DeviceIdentity {
    static var name: String { UIDevice.current.name }

    static var id: String {
        let key = "deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}
