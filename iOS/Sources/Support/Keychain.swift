import Foundation
import Security

/// Generic-password Keychain items of this app (`PairingStore`, `PhoneSSHKey`). Items are added as
/// "after first unlock, this device only": never in backups that move to another device.
enum Keychain {
    /// The data of the item, or nil if there is none (or it cannot be read).
    static func read(service: String, account: String) -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Adds a new item (does not replace an existing one; delete it first).
    @discardableResult
    static func add(_ data: Data, service: String, account: String) -> OSStatus {
        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }

    /// Deletes the item for `account`, or every item of `service` when `account` is nil.
    @discardableResult
    static func delete(service: String, account: String?) -> OSStatus {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }

    private static func baseQuery(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }
}
