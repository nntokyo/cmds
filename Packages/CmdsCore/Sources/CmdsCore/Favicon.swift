import Foundation

/// The icon of a browser pane's page for its tab (and the bookmarks bar): the page's `<link rel="icon">` candidates,
/// best first, then `/favicon.ico`.
public enum Favicon {
    /// One `<link rel~="icon">` (also `apple-touch-icon`, `mask-icon`) of the page.
    public struct Candidate: Codable, Equatable, Sendable {
        public var href: String
        public var rel: String
        public var sizes: String?
        public var type: String?

        public init(href: String, rel: String, sizes: String? = nil, type: String? = nil) {
            self.href = href
            self.rel = rel
            self.sizes = sizes
            self.type = type
        }
    }

    /// Icons larger than this are not read.
    public static let maxBytes = 1 << 20
    /// The size a tab shows (points × 2 for Retina).
    public static let wantedPixels = 32

    /// `callAsyncJavaScript` body: the page's icon links (at most 20).
    public static let script = """
        return [...document.querySelectorAll('link[rel][href]')]
          .filter(l => /(^|\\\\s)(icon|apple-touch-icon|apple-touch-icon-precomposed)(\\\\s|$)/i.test(l.getAttribute('rel')))
          .slice(0, 20)
          .map(l => ({ href: l.href, rel: (l.getAttribute('rel') || '').toLowerCase(),
                       sizes: l.getAttribute('sizes'), type: l.getAttribute('type') }));
        """

    /// The icon URLs to try for `page`, best first: an icon of the wanted size or just above, an SVG, any other icon,
    /// Apple touch icons, then `/favicon.ico`. Only http, https and data URLs (no `file:` from a remote page).
    public static func urls(_ candidates: [Candidate], page: URL) -> [URL] {
        func score(_ candidate: Candidate) -> Int {
            let rel = candidate.rel
            let isTouch = rel.contains("apple-touch")
            let isSVG = candidate.type?.lowercased().contains("svg") == true || candidate.href.lowercased().hasSuffix(".svg")
            let size = candidate.sizes.flatMap { sizes -> Int? in
                if sizes.lowercased() == "any" { return nil }
                return sizes.split(separator: " ").compactMap { Int($0.lowercased().split(separator: "x").first ?? "") }.max()
            }
            var value = isTouch ? 100 : 0
            if let size {
                value += size >= wantedPixels ? size - wantedPixels : (wantedPixels - size) * 4 + 40
            } else {
                value += isSVG ? 5 : 20
            }
            return value
        }
        let local = page.scheme?.lowercased() == "file"
        var seen = Set<String>()
        var result: [URL] = []
        for candidate in candidates.sorted(by: { score($0) < score($1) }) {
            guard let url = URL(string: candidate.href, relativeTo: page)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "data"].contains(scheme) || (local && scheme == "file"),
                  seen.insert(url.absoluteString).inserted else { continue }
            result.append(url)
        }
        if let scheme = page.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = page.host,
           let fallback = URL(string: "\(scheme)://\(host)\(page.port.map { ":\($0)" } ?? "")/favicon.ico"),
           seen.insert(fallback.absoluteString).inserted {
            result.append(fallback)
        }
        return result
    }
}
