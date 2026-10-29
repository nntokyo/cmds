import CryptoKit
import Foundation
import os

/// Paired iOS devices. Tokens are bearer secrets: only their SHA-256 (hex) is persisted, in
/// `~/Library/Application Support/cmds/sync-devices.json` (`$CMDS_SUPPORT_DIR` when set) with mode 0600
/// (directory 0700).
/// Never log tokens or their hashes.
@MainActor
final class SyncDeviceStore {
    struct Device: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        /// Phone's per-install ID; re-pairing the same install replaces its old token.
        var deviceID: String?
        var tokenHash: String
        var pairedAt: Date
        var lastSeen: Date?
    }

    private(set) var devices: [Device] = []
    private let fileURL: URL

    init(directory: URL = SessionStore.directory) {
        fileURL = directory.appendingPathComponent("sync-devices.json")
        load()
    }

    var tokenHashes: [String] { devices.map(\.tokenHash) }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Records a newly issued token and returns the stored device.
    @discardableResult
    func add(token: String, deviceName: String, deviceID: String?) -> Device {
        if let deviceID { devices.removeAll { $0.deviceID == deviceID } }
        let device = Device(id: UUID().uuidString, name: deviceName, deviceID: deviceID,
                            tokenHash: Self.hash(token), pairedAt: Date(), lastSeen: Date())
        devices.append(device)
        save()
        return device
    }

    func device(tokenHash: String) -> Device? {
        devices.first { Self.digestsEqual($0.tokenHash, tokenHash) }
    }

    func touch(tokenHash: String, name: String) {
        guard let index = devices.firstIndex(where: { Self.digestsEqual($0.tokenHash, tokenHash) }) else { return }
        devices[index].lastSeen = Date()
        devices[index].name = name
        save()
    }

    func revoke(id: String) {
        devices.removeAll { $0.id == id }
        save()
    }

    func revokeAll() {
        devices.removeAll()
        save()
    }

    /// Constant-time comparison of equal-length hex digests.
    static func digestsEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        devices = (try? decoder.decode([Device].self, from: data)) ?? []
    }

    private func save() {
        let fm = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(devices)
            // Write to a 0600 temp file in the same directory, then rename over the old one,
            // so the content is never readable by others even briefly.
            let temp = directory.appendingPathComponent(".sync-devices.\(UUID().uuidString).tmp")
            guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            if fm.fileExists(atPath: fileURL.path) {
                _ = try fm.replaceItemAt(fileURL, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: fileURL)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            syncLog.error("could not save paired devices: \(error.localizedDescription, privacy: .public)")
        }
    }
}
