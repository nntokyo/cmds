import Foundation

/// One paired iPhone/iPad as `sync.devices` lists it (`cmds sync devices`, #114). Local socket only, like every
/// `sync.*` method. Holds no token or hash: the id is the pairing's own random id.
public struct SyncPairedDevice: Codable, Equatable, Sendable {
    /// The pairing's id (`sync.revoke` takes it).
    public var id: String
    public var name: String
    /// ISO 8601.
    public var pairedAt: String
    /// ISO 8601; nil when never seen since pairing.
    public var lastSeen: String?
    /// Peers of its open, authenticated connections (IP, `bluetooth:…`, `ssh:…`); empty when not connected.
    public var connectedFrom: [String]

    public init(id: String, name: String, pairedAt: String, lastSeen: String?, connectedFrom: [String]) {
        self.id = id
        self.name = name
        self.pairedAt = pairedAt
        self.lastSeen = lastSeen
        self.connectedFrom = connectedFrom
    }

    /// The device `cmds sync revoke` means: an id, an id prefix of at least 4 characters, or a name (case-insensitive),
    /// as long as exactly one device matches. Throws the reason otherwise, so the CLI never revokes a guess.
    public static func match(_ query: String, in devices: [SyncPairedDevice]) throws -> SyncPairedDevice {
        let query = query.trimmingCharacters(in: .whitespaces)
        if let exact = devices.first(where: { $0.id == query }) { return exact }
        let byName = devices.filter { $0.name.compare(query, options: .caseInsensitive) == .orderedSame }
        let byPrefix = query.count >= 4 ? devices.filter { $0.id.lowercased().hasPrefix(query.lowercased()) } : []
        let matches = byName.isEmpty ? byPrefix : byName
        switch matches.count {
        case 1: return matches[0]
        case 0: throw MatchError.none(query)
        default: throw MatchError.ambiguous(query, matches.map(\.id))
        }
    }

    public enum MatchError: Error, Equatable, CustomStringConvertible {
        case none(String)
        case ambiguous(String, [String])

        public var description: String {
            switch self {
            case .none(let query): return "no paired device \"\(query)\" (see `cmds sync devices`)"
            case .ambiguous(let query, let ids):
                return "\"\(query)\" matches several devices (\(ids.joined(separator: ", "))); give the id"
            }
        }
    }
}
