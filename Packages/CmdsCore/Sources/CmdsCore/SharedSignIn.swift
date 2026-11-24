import CryptoKit
import Foundation

/// Keeping one workspace's sign-ins away from another's. On 2026-11-22 one workspace's agent switched X to another
/// account in the shared browser data, and another workspace's agent nearly posted as that account. Another opened a
/// shopping account's page in the shared data.
/// - `WorkspaceProfile`: each workspace's own login profile, the default for browser panes opened in it.
/// - `SharedSignIn`: sites whose sign-in a page in the shared data would use, told by their sign-in cookies, so the pane
///   can warn before an agent acts as whoever is signed in there.
public enum WorkspaceProfile {
    /// `notes · 3fa2`: the project folder's name (else the workspace's title) and 4 hex digits of the folder's path,
    /// so two projects called `app` never share a profile. Stable for a folder; at most `BrowserProfile.maxLength`.
    public static func name(folder: String?, title: String, home: String = NSHomeDirectory()) -> String {
        let path = folder.map { ($0 as NSString).standardizingPath }
        let base: String
        if let path, path != home, path != "/" {
            base = (path as NSString).lastPathComponent
        } else {
            base = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let cleaned = String(base.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(Character.init)).trimmingCharacters(in: .whitespaces)
        let key = path ?? "title:\(cleaned)"
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(2).map { String(format: "%02x", $0) }.joined()
        let suffix = " · \(hash)"
        let stem = cleaned.isEmpty ? "workspace" : String(cleaned.prefix(BrowserProfile.maxLength - suffix.count))
        return stem + suffix
    }
}

public enum SharedSignIn {
    public struct Site: Equatable, Sendable {
        public var name: String
        /// Registrable domains (a host matches itself or a subdomain).
        public var domains: [String]
        /// Cookies that exist only while signed in.
        public var cookies: Set<String>

        public init(name: String, domains: [String], cookies: Set<String>) {
            self.name = name
            self.domains = domains
            self.cookies = cookies
        }
    }

    public static let sites: [Site] = [
        Site(name: "X", domains: ["x.com", "twitter.com"], cookies: ["auth_token"]),
        Site(name: "Amazon", domains: ["amazon.co.jp", "amazon.com", "amazon.co.uk", "amazon.de", "amazon.fr", "amazon.ca"],
             cookies: ["at-main", "x-main", "sess-at-main", "at-acbjp", "x-acbjp", "sess-at-acbjp", "at-acbuk", "at-acbde"]),
        Site(name: "GitHub", domains: ["github.com"], cookies: ["user_session"]),
        Site(name: "Google", domains: ["google.com", "google.co.jp", "youtube.com"], cookies: ["SID", "__Secure-1PSID"]),
        Site(name: "note", domains: ["note.com"], cookies: ["_note_session_v5"]),
        Site(name: "Facebook", domains: ["facebook.com"], cookies: ["c_user"]),
        Site(name: "Instagram", domains: ["instagram.com"], cookies: ["sessionid"]),
        Site(name: "LinkedIn", domains: ["linkedin.com"], cookies: ["li_at"]),
    ]

    /// The site `host` belongs to, if it is one of `sites` (or `extra`, tests).
    public static func site(forHost host: String?, extra: [Site] = []) -> Site? {
        guard let host = host?.lowercased() else { return nil }
        return (sites + extra).first { site in site.domains.contains { host == $0 || host.hasSuffix("." + $0) } }
    }

    /// Signed in to `site`: one of its sign-in cookies, set for one of its domains, is there (`cookies`: name, domain).
    public static func isSignedIn(_ site: Site, cookies: [(name: String, domain: String)]) -> Bool {
        cookies.contains { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return site.cookies.contains(cookie.name) && site.domains.contains { domain == $0 || domain.hasSuffix("." + $0) }
        }
    }
}
