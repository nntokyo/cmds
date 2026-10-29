import Foundation
import Security
import UIKit

/// Pairing tokens, one per Mac (`MacTarget.id`), stored as generic passwords.
enum TokenStore {
    private static let service = "tokyo.n-n.cmds.companion.pairing"

    static func token(for targetID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: targetID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ token: String, for targetID: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: targetID,
        ]
        let data = Data(token.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(base as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func deleteToken(for targetID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: targetID,
        ]
        SecItemDelete(query as CFDictionary)
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
