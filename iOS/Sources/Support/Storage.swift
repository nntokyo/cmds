import CmdsCore
import Foundation
import os
import Security
import UIKit

/// Pairing storage log (subsystem tokyo.n-n.cmds.companion). Never log tokens.
let pairingLog = Logger(subsystem: "tokyo.n-n.cmds.companion", category: "pairing")

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
        guard let data = Keychain.read(service: service, account: targetID) else { return nil }
        return try? JSONDecoder().decode(MacPairing.self, from: data)
    }

    static func isPaired(_ targetID: String) -> Bool {
        pairing(for: targetID) != nil
    }

    static func save(_ pairing: MacPairing, for targetID: String) {
        guard let data = try? JSONEncoder().encode(pairing) else { return }
        delete(for: targetID)
        let status = Keychain.add(data, service: service, account: targetID)
        if status != errSecSuccess {
            // Fails closed: without a saved pin the next connection asks to pair again. (Unsigned
            // simulator builds have no keychain entitlement and always end up here, -34018.)
            pairingLog.error("could not save the pairing: OSStatus \(status, privacy: .public)")
        }
    }

    static func delete(for targetID: String) {
        Keychain.delete(service: service, account: targetID)
    }

    /// The fingerprint pinned for every saved Mac, by `MacTarget.id`.
    static func fingerprints() -> [(id: String, fingerprint: SyncFingerprint)] {
        Keychain.accounts(service: service).compactMap { id in pairing(for: id).map { (id, $0.fingerprint) } }
    }

    /// Deletes every v1 token; true if there was one (the user has to pair again).
    static func removeLegacyTokens() -> Bool {
        Keychain.delete(service: legacyService, account: nil) == errSecSuccess
    }
}

/// One Mac under several names (#325). What the phone keeps per Mac is filed under `MacTarget.id`: the Bonjour service
/// name, or the address it was paired by. That id changes while the Mac stays the same: Bonjour renames the service
/// after a name conflict ("Name (2)", e.g. when the app restarts for an update), the Mac is renamed, or it was paired
/// by address and is later found on the network. The Mac is the same one when it has the certificate the phone
/// pinned, so the pairing, its remote access and its place in Recent follow the fingerprint (`SyncMacContinuity`).
/// The fingerprint a Mac advertises is only a hint: every connection is still pinned to the saved one, so a wrong or
/// forged hint can only fail to connect.
enum MacContinuity {
    /// `target` has no pairing under its id, but a saved Mac has the fingerprint it advertises.
    static func canAdopt(_ target: MacTarget) -> Bool {
        savedID(for: target) != nil
    }

    private static func savedID(for target: MacTarget) -> String? {
        guard target.kind != .mock, !PairingStore.isPaired(target.id),
              let hint = target.fingerprintHint.flatMap(SyncFingerprint.init(base64url:)) else { return nil }
        return SyncMacContinuity.ids(sharing: hint, in: PairingStore.fingerprints(), except: target.id).first
    }

    /// Before connecting to `target`: when it is a saved Mac under a new name, its pairing and remote access are
    /// filed under the new id as well. A saved Bonjour name is replaced (the service was renamed); an address stays,
    /// as it may still be used from elsewhere. True when `target` is paired afterwards.
    @discardableResult
    static func adopt(_ target: MacTarget) -> Bool {
        guard let old = savedID(for: target), let pairing = PairingStore.pairing(for: old) else { return false }
        PairingStore.save(pairing, for: target.id)
        guard PairingStore.isPaired(target.id) else { return false }
        carryRemoteAccess(from: old, to: target.id)
        if SyncMacContinuity.isBonjourID(old) {
            PairingStore.delete(for: old)
            RemoteAccessStore.delete(for: old)
            RecentMacs.forget(id: old)
        }
        pairingLog.notice("a paired Mac is known under a new name: its pairing follows")
        return true
    }

    /// After `id` was paired anew with `fingerprint`: the Mac replaced this phone's token, so the other entries of
    /// the same Mac get the new one (else they would ask to pair again), and its remote access is kept.
    static func paired(_ id: String, pairing: MacPairing) {
        for other in SyncMacContinuity.ids(sharing: pairing.fingerprint, in: PairingStore.fingerprints(), except: id) {
            PairingStore.save(pairing, for: other)
            carryRemoteAccess(from: other, to: id)
        }
    }

    private static func carryRemoteAccess(from old: String, to id: String) {
        guard RemoteAccessStore.config(for: id) == nil, let config = RemoteAccessStore.config(for: old) else { return }
        RemoteAccessStore.save(config, for: id)
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
        forget(id: target.id)
    }

    static func forget(id: String) {
        save(load().filter { $0.id != id })
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
