import AppKit
import WebKit
import CmdsCore

// Tabs of browser panes: the page's icon for the tab bar, and background tabs restored with the session that load
// only when first shown (docs/guide/workspaces-and-panes.md "Tabs").
extension BrowserPane {
    // MARK: - Loading later

    /// Remembers `input` to load when the pane is first in a window (or a command asks for its page).
    func deferLoad(_ input: String) {
        guard let url = Self.url(fromUserInput: input), !BrowserAddress.opensExternally(url) else {
            showStartPage()
            return
        }
        pendingURL = url
        requestedURL = url
        stateDidChange()
    }

    /// Loads the page remembered by `deferLoad`, once.
    func loadIfPending() {
        guard let url = pendingURL else { return }
        pendingURL = nil
        webView.load(URLRequest(url: url))
    }

    // MARK: - Favicon

    /// Looks up the page's icon after a load (its `<link rel="icon">`s, then `/favicon.ico`), from the cache when known.
    func refreshFavicon() {
        guard let page = webView.url, let scheme = page.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else {
            setFavicon(nil, host: nil)
            return
        }
        let host = page.host ?? page.deletingLastPathComponent().path
        if host != faviconHost { setFavicon(FaviconCache.shared.image(forHost: host), host: host) }
        faviconTask?.cancel()
        faviconTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // A background tab's page may run scripts late: after 3 s go on with `/favicon.ico`.
            let candidates = (try? await self.runPageScript(Favicon.script, [:], until: Date(timeIntervalSinceNow: 3)))
                .flatMap { try? $0.decode([Favicon.Candidate].self) } ?? []
            for url in Favicon.urls(candidates, page: page) {
                guard !Task.isCancelled else { return }
                if let image = await FaviconCache.shared.image(for: url) {
                    guard !Task.isCancelled, self.webView.url?.host == page.host else { return }
                    FaviconCache.shared.remember(image, forHost: host)
                    self.setFavicon(image, host: host)
                    return
                }
            }
        }
    }

    private func setFavicon(_ image: NSImage?, host: String?) {
        faviconHost = host
        guard image !== favicon else { return }
        favicon = image
        onFaviconChange?()
    }
}

/// Icons downloaded for tabs, by URL and by site (the bookmarks bar shows a visited site's icon). In memory only.
@MainActor
final class FaviconCache {
    static let shared = FaviconCache()
    static let didChange = Notification.Name("FaviconCacheDidChange")

    private var byURL: [URL: NSImage] = [:]
    private var missing: Set<URL> = []
    private var byHost: [String: NSImage] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    func image(forHost host: String) -> NSImage? { byHost[host] }

    func remember(_ image: NSImage, forHost host: String) {
        guard byHost[host] !== image else { return }
        if byHost.count > 500 { byHost.removeAll() }
        byHost[host] = image
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// The icon at `url` (downloaded once; a failure is remembered too). At most `Favicon.maxBytes`.
    func image(for url: URL) async -> NSImage? {
        if let image = byURL[url] { return image }
        if missing.contains(url) { return nil }
        let data: Data?
        if url.isFileURL || url.scheme == "data" {
            data = try? Data(contentsOf: url, options: .mappedIfSafe)
        } else {
            var request = URLRequest(url: url)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            let result = try? await session.data(for: request)
            let ok = (result?.1 as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            data = ok ? result?.0 : nil
        }
        guard let data, data.count <= Favicon.maxBytes, let image = NSImage(data: data), image.isValid,
              image.size.width > 0, image.size.height > 0 else {
            if missing.count > 2000 { missing.removeAll() }
            missing.insert(url)
            return nil
        }
        if byURL.count > 500 { byURL.removeAll() }
        byURL[url] = image
        return image
    }
}
