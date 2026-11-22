import CryptoKit
import Foundation

/// Login profiles of browser panes (docs/guide/workspaces-and-panes.md "Login profiles"): each named profile keeps its
/// own cookies, storage and sign-ins; panes without one share the default data, as before. Panes of the same profile
/// share its sign-ins, so separate agent sessions can sign in as different users, or share one by naming the same
/// profile.
public enum BrowserProfile {
    /// The longest name accepted.
    public static let maxLength = 64

    /// `raw` checked as a profile name: surrounding spaces dropped; nil for none (the shared default data). Throws for
    /// a name that is too long or has control characters.
    public static func validated(_ raw: String?) throws -> String? {
        guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        guard name.count <= maxLength else {
            throw RPCError.invalidParams("a profile name is at most \(maxLength) characters")
        }
        guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RPCError.invalidParams("a profile name cannot have control characters")
        }
        return name
    }

    /// A requested change: `""` is the shared data (nil); anything else must be a valid name (a name of spaces alone
    /// is refused, so a typo never drops a session's sign-ins apart silently).
    public static func change(_ raw: String) throws -> String? {
        guard !raw.isEmpty else { return nil }
        guard let name = try validated(raw) else {
            throw RPCError.invalidParams("a profile name cannot be only spaces; use \"\" for the shared data")
        }
        return name
    }

    /// The identifier of the profile's WebKit data store: a name-based UUID (version 5), so a profile finds its data
    /// again from its name alone, even if the list of profiles is lost.
    public static func identifier(for name: String) -> UUID {
        // RFC 4122 name-based UUID; the namespace is the bytes of "cmds-browser-prf" (never change it: profiles would
        // lose their data).
        let namespace: [UInt8] = [0x63, 0x6d, 0x64, 0x73, 0x2d, 0x62, 0x72, 0x6f, 0x77, 0x73, 0x65, 0x72, 0x2d, 0x70, 0x72, 0x66]
        var bytes = Array(Insecure.SHA1.hash(data: Data(namespace + Array(name.utf8))).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// How a profile is named to people: the name, or "shared" for none.
    public static func label(_ name: String?) -> String { name.map { "\"\($0)\"" } ?? "shared (default)" }
}

/// `browser.profile`'s answer: the profile of a browser pane or of the pages a terminal opens, and the known profiles.
public struct BrowserProfileState: Codable, Equatable, Sendable {
    /// The pane asked about.
    public var pane: String
    /// Its profile (nil: the shared default data).
    public var profile: String?
    /// Every profile created so far, sorted.
    public var profiles: [String]

    public init(pane: String, profile: String?, profiles: [String]) {
        self.pane = pane
        self.profile = profile
        self.profiles = profiles
    }
}
