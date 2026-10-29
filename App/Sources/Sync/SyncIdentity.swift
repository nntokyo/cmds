import CmdsCore
import CryptoKit
import Foundation
import Security

/// The Mac's sync identity: an ECDSA P-256 private key and a self-signed certificate (`SyncCertificate`),
/// both in the login keychain. The phone pins the certificate's SHA-256 (`fingerprint`) when pairing.
struct SyncIdentity {
    let secIdentity: SecIdentity
    let certificate: SecCertificate
    let fingerprint: SyncFingerprint
}

/// Keychain storage for `SyncIdentity`. The private key is created in the keychain, is not extractable,
/// and only signs (the certificate here, TLS handshakes in Network.framework). Lookups start from the
/// key's application tag; the certificate is found through the key's public key hash (the file-based
/// keychain ignores a custom certificate label and names it after its common name).
///
/// An isolated instance (`CMDS_SUPPORT_DIR`) uses its own items (label and tag carry a suffix derived from
/// that directory), so a test instance never reads, replaces or deletes the identity of the app in use.
final class SyncIdentityStore {
    enum StoreError: LocalizedError {
        case keychain(String, OSStatus)
        case security(String, CFError?)

        var errorDescription: String? {
            switch self {
            case .keychain(let step, let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "\(step): \(message)"
            case .security(let step, let error):
                return "\(step): \(error.map { CFErrorCopyDescription($0) as String } ?? "unknown error")"
            }
        }
    }

    /// Keychain label of the private key (shown in Keychain Access).
    let label: String
    /// Application tag of the private key; the lookup starts from it.
    let tag: Data

    init(scope: String? = SyncIdentityStore.currentScope()) {
        label = "cmds sync identity" + (scope.map { " (\($0))" } ?? "")
        tag = Data(("tokyo.n-n.cmds.sync-identity" + (scope.map { ".\($0)" } ?? "")).utf8)
    }

    /// nil for the normal app; "test-<hash of CMDS_SUPPORT_DIR>" for an isolated instance.
    static func currentScope(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let directory = CmdsEnv.supportDirectoryOverride(environment: environment) else { return nil }
        let digest = SHA256.hash(data: Data(directory.utf8))
        return "test-" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The stored identity; nil when there is none (or only half of one). Throws when the keychain
    /// cannot be read (locked, access denied): the caller must not replace the identity then.
    func load() throws -> SyncIdentity? {
        guard let publicKeyHash = try privateKeyHash() else { return nil }
        var item: CFTypeRef?
        let query: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecAttrPublicKeyHash: publicKeyHash,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item, CFGetTypeID(item) == SecCertificateGetTypeID() else {
            throw StoreError.keychain("Reading the sync certificate", status)
        }
        let certificate = item as! SecCertificate // swiftlint:disable:this force_cast
        var identity: SecIdentity?
        let identityStatus = SecIdentityCreateWithCertificate(nil, certificate, &identity)
        if identityStatus == errSecItemNotFound { return nil }
        guard identityStatus == errSecSuccess, let identity else {
            throw StoreError.keychain("Opening the sync identity", identityStatus)
        }
        return SyncIdentity(secIdentity: identity, certificate: certificate,
                            fingerprint: SyncFingerprint(certificate: SecCertificateCopyData(certificate) as Data))
    }

    /// Creates a new key and certificate, replacing any stored ones.
    func create(commonName: String) throws -> SyncIdentity {
        delete()
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrIsExtractable: false,
                kSecAttrLabel: label,
                kSecAttrApplicationTag: tag,
            ] as [CFString: Any],
        ]
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw StoreError.security("Creating the sync key", error?.takeRetainedValue())
        }
        do {
            guard let publicKey = SecKeyCopyPublicKey(privateKey),
                  let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
                throw StoreError.security("Reading the sync public key", error?.takeRetainedValue())
            }
            let notBefore = Date().addingTimeInterval(-24 * 60 * 60) // tolerate a phone clock that is behind
            let der = try SyncCertificate.make(commonName: commonName, publicKey: publicKeyData,
                                               serialNumber: SyncCertificate.randomSerialNumber(),
                                               notBefore: notBefore, notAfter: notBefore + SyncCertificate.validity) { tbs in
                var signError: Unmanaged<CFError>?
                guard let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256,
                                                            tbs as CFData, &signError) as Data? else {
                    throw StoreError.security("Signing the sync certificate", signError?.takeRetainedValue())
                }
                return signature
            }
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                throw StoreError.keychain("Parsing the sync certificate", errSecDecode)
            }
            let add: [CFString: Any] = [kSecClass: kSecClassCertificate, kSecValueRef: certificate]
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw StoreError.keychain("Saving the sync certificate", status) }
            guard let identity = try load() else {
                throw StoreError.keychain("Reading back the sync identity", errSecItemNotFound)
            }
            return identity
        } catch {
            delete()
            throw error
        }
    }

    /// Removes the key and its certificate (if any). Missing items are not an error. Certificates are
    /// only ever matched through this store's key, never by name: every identity of this Mac has the
    /// same common name, including the ones of isolated test instances.
    func delete() {
        for hash in (try? privateKeyHashes()) ?? [] {
            deleteAll([kSecClass: kSecClassCertificate, kSecAttrPublicKeyHash: hash])
        }
        deleteAll([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag])
        deleteAll([kSecClass: kSecClassKey, kSecAttrLabel: label])
    }

    // MARK: - Private

    /// Public key hash (`kSecAttrApplicationLabel`) of the stored private key, which is also the
    /// certificate's `kSecAttrPublicKeyHash`.
    private func privateKeyHash() throws -> Data? {
        try privateKeyHashes().first
    }

    private func privateKeyHashes() throws -> [Data] {
        var result: CFTypeRef?
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag: tag,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[CFString: Any]] else {
            throw StoreError.keychain("Reading the sync key", status)
        }
        return items.compactMap { $0[kSecAttrApplicationLabel] as? Data }
    }

    /// SecItemDelete may remove one match per call on the file-based keychain; repeat until none is left.
    private func deleteAll(_ query: [CFString: Any]) {
        var attempts = 0
        while attempts < 16, SecItemDelete(query as CFDictionary) == errSecSuccess { attempts += 1 }
    }
}
