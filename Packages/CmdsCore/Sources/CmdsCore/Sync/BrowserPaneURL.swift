import Foundation

/// What the phone can load of a browser pane's URL. The Mac's own pages (localhost, file://) are not reachable from
/// the phone.
public enum BrowserPaneURL {
    public enum Result: Equatable, Sendable {
        case load(URL)
        /// Only on the Mac (localhost, a file) or not a web address.
        case macOnly
    }

    public static func resolve(_ raw: String?) -> Result {
        guard let raw, let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host?.lowercased() else { return .macOnly }
        if host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1"
            || host == "[::1]" || host == "0.0.0.0" {
            return .macOnly
        }
        return .load(url)
    }
}
