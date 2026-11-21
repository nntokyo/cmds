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
          .filter(l => /(^|\\s)(icon|apple-touch-icon|apple-touch-icon-precomposed)(\\s|$)/i.test(l.getAttribute('rel')))
          .filter(l => l.href.length <= 1500000)  // a huge data: URL never leaves the page
          .slice(0, 20)
          .map(l => ({ href: l.href, rel: (l.getAttribute('rel') || '').toLowerCase(),
                       sizes: l.getAttribute('sizes'), type: l.getAttribute('type') }));
        """

    /// An icon the app cannot download itself (App Transport Security refuses plain `http` to names other than local
    /// ones), which the page fetches instead (`fetchScript`): plain `http`, the page's own site, not a local address.
    public static func fetchedByPage(_ url: URL, page: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", page.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(), host == page.host?.lowercased(), url.port == page.port else { return false }
        let local = host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.allSatisfy { $0.isNumber || $0 == "." } || host.contains(":")
        return !local
    }

    /// `callAsyncJavaScript` body: the icon at `url` (the page's own site) as base64, at most `maxBytes`, without
    /// cookies; null when it is missing, larger or not an image.
    public static let fetchScript = """
        const response = await fetch(url, { credentials: 'omit', cache: 'force-cache', redirect: 'error' });
        if (!response.ok || !/^image\\//i.test(response.headers.get('content-type') || 'image/x-icon')) return null;
        const reader = response.body.getReader();
        const chunks = []; let size = 0;
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          size += value.length;
          if (size > maxBytes) { try { reader.cancel(); } catch (e) {} return null; }
          chunks.push(value);
        }
        let binary = '';
        for (const chunk of chunks) for (let i = 0; i < chunk.length; i += 0x8000) binary += String.fromCharCode(...chunk.subarray(i, i + 0x8000));
        return { data: btoa(binary) };
        """

    /// The icon URLs to try for `page`, best first: an icon of the wanted size or just above, an SVG, any other icon,
    /// Apple touch icons, then `/favicon.ico`. Only http, https and data URLs (no `file:` from a remote page); an icon
    /// on another site only on the web's usual ports (80, 443), so a page cannot make cmds knock on other services.
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
        func origin(_ url: URL) -> String { "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? -1)" }
        func allowed(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return true }
            if origin(url) == origin(page) { return true }
            return url.port == nil || url.port == 80 || url.port == 443
        }
        var seen = Set<String>()
        var result: [URL] = []
        for candidate in candidates.sorted(by: { score($0) < score($1) }) {
            guard let url = URL(string: candidate.href, relativeTo: page)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "data"].contains(scheme) || (local && scheme == "file"), allowed(url),
                  seen.insert(url.absoluteString).inserted else { continue }
            result.append(url)
        }
        // Built from the page's own parts, so IPv6 hosts (`[::1]`) keep their brackets.
        if let scheme = page.scheme?.lowercased(), ["http", "https"].contains(scheme),
           var parts = URLComponents(url: page, resolvingAgainstBaseURL: false) {
            parts.path = "/favicon.ico"
            parts.query = nil
            parts.fragment = nil
            parts.user = nil
            parts.password = nil
            if let fallback = parts.url, seen.insert(fallback.absoluteString).inserted { result.append(fallback) }
        }
        return result
    }
}
