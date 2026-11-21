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

    /// Loads the page remembered by `deferLoad` (or `suspend`), once.
    func loadIfPending() {
        guard let url = pendingURL else { return }
        pendingURL = nil
        suspendedTitle = nil
        loadingFromPending = true
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// After `loadIfPending` started the page for a command: waits until it has loaded (at most 20 s), so scripts and
    /// snapshots see the page, not the blank document before it.
    func waitForPendingLoad() async {
        guard loadingFromPending else { return }
        let deadline = Date(timeIntervalSinceNow: 20)
        while Date() < deadline, webView.isLoading || webView.url == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        loadingFromPending = false
    }

    /// Whether the tab may be suspended now, apart from its idle time and the page's answer: nothing loading or failed,
    /// no pop-up open, not a form's answer, not already suspended.
    var canSuspend: Bool {
        pendingURL == nil && loadFailure == nil && !webView.isLoading && !loadedFromForm && !pageDelegate.hasPopups
            && webView.url != nil
    }

    /// Unloads the page to save memory (a background tab unused for a while, #375): the web view and its process are
    /// replaced by an empty one, and the page loads again when shown or asked for. Back / forward history and the
    /// page's state are lost, so only pages without unsaved input are suspended.
    func suspend() {
        guard canSuspend, let url = webView.url else { return }
        let title = webView.title
        replaceWebView()
        suspendedTitle = title
        pendingURL = url
        stateDidChange()
    }

    var isSuspended: Bool { pendingURL != nil && suspendedTitle != nil }

    // MARK: - Favicon

    /// The site an icon belongs to: scheme, host and port (`http://localhost:5173`), or a local page's folder.
    static func faviconSite(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "file" { return "file://" + url.deletingLastPathComponent().path }
        guard let host = url.host?.lowercased() else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    /// Looks up the page's icon after a load (its `<link rel="icon">`s, then `/favicon.ico`), from the cache when known.
    func refreshFavicon() {
        guard pendingURL == nil else { return }  // suspended: the blank page has no icon, keep the page's
        guard let page = webView.url, let scheme = page.scheme?.lowercased(), ["http", "https", "file"].contains(scheme),
              let site = Self.faviconSite(page) else {
            setFavicon(nil, site: nil)
            return
        }
        // Another site: its known icon, else none until found (never the previous site's).
        if site != faviconHost { setFavicon(FaviconCache.shared.image(forSite: site), site: site) }
        faviconTask?.cancel()
        faviconTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // A background tab's page may run scripts late: after 3 s go on with `/favicon.ico`.
            let candidates = (try? await self.runPageScript(Favicon.script, [:], until: Date(timeIntervalSinceNow: 3)))
                .flatMap { try? $0.decode([Favicon.Candidate].self) } ?? []
            for url in Favicon.urls(candidates, page: page) {
                guard !Task.isCancelled else { return }
                // Plain http on the page's own site: the page fetches it (the app may not).
                if Favicon.fetchedByPage(url, page: page) {
                    let result = try? await self.runPageScript(Favicon.fetchScript, ["url": url.absoluteString,
                                                                                    "maxBytes": Favicon.maxBytes],
                                                               until: Date(timeIntervalSinceNow: 5))
                    guard !Task.isCancelled else { return }
                    if let base64 = result?["data"]?.stringValue, let data = Data(base64Encoded: base64),
                       let image = FaviconCache.decode(data), self.webView.url.flatMap(Self.faviconSite) == site {
                        FaviconCache.shared.remember(image, forSite: site)
                        self.setFavicon(image, site: site)
                        return
                    }
                    continue
                }
                if let image = await FaviconCache.shared.image(for: url) {
                    guard !Task.isCancelled, self.webView.url.flatMap(Self.faviconSite) == site else { return }
                    FaviconCache.shared.remember(image, forSite: site)
                    self.setFavicon(image, site: site)
                    return
                }
            }
        }
    }

    private func setFavicon(_ image: NSImage?, site: String?) {
        faviconHost = site
        guard image !== favicon else { return }
        favicon = image
        onFaviconChange?()
    }
}

/// Icons downloaded for tabs, by URL and by site (`BrowserPane.faviconSite`; the bookmarks bar shows a visited site's
/// icon). In memory only. Downloads stop at `Favicon.maxBytes`; images are decoded off the main thread and scaled
/// down to 64 px, so a huge or hostile icon costs little.
@MainActor
final class FaviconCache {
    static let shared = FaviconCache()
    static let didChange = Notification.Name("FaviconCacheDidChange")
    /// Icons are kept at most this many pixels wide and high.
    static let pixels = 64

    private var byURL: [URL: NSImage] = [:]
    /// Icons that do not exist or cannot be decoded (not network errors or cancelled downloads: those are tried again).
    private var missing: Set<URL> = []
    private var bySite: [String: NSImage] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    func image(forSite site: String) -> NSImage? { bySite[site] }

    func remember(_ image: NSImage, forSite site: String) {
        guard bySite[site] !== image else { return }
        if bySite.count > 500 { bySite.removeAll() }
        bySite[site] = image
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private enum Outcome { case image(NSImage), missing, failed }

    /// The icon at `url` (downloaded once; an icon that does not exist is remembered too).
    func image(for url: URL) async -> NSImage? {
        if let image = byURL[url] { return image }
        if missing.contains(url) { return nil }
        let outcome = await Self.load(url, session: session)
        guard !Task.isCancelled else { return nil }
        // `data:` icons are part of the page: never kept by their (possibly huge) address.
        if url.scheme == "data" {
            if case .image(let image) = outcome { return image }
            return nil
        }
        switch outcome {
        case .image(let image):
            if byURL.count > 500 { byURL.removeAll() }
            byURL[url] = image
            return image
        case .missing:
            if missing.count > 2000 { missing.removeAll() }
            missing.insert(url)
            return nil
        case .failed:
            return nil
        }
    }

    /// Reads at most `Favicon.maxBytes` (a local file only when it is a regular file that small) and decodes off the
    /// main thread.
    nonisolated private static func load(_ url: URL, session: URLSession) async -> Outcome {
        var data = Data()
        if url.isFileURL {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.size] as? NSNumber)?.intValue ?? .max) <= Favicon.maxBytes,
                  let read = try? Data(contentsOf: url) else { return .missing }
            data = read
        } else if url.scheme == "data" {
            guard url.absoluteString.utf8.count <= Favicon.maxBytes * 2, let read = try? Data(contentsOf: url) else { return .missing }
            data = read
        } else {
            var request = URLRequest(url: url)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            do {
                let (bytes, response) = try await session.bytes(for: request, delegate: FaviconRedirects(from: url))
                guard let http = response as? HTTPURLResponse else { return .failed }
                guard (200..<300).contains(http.statusCode) else { return (400..<500).contains(http.statusCode) ? .missing : .failed }
                if http.expectedContentLength > Int64(Favicon.maxBytes) { return .missing }
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > Favicon.maxBytes { return .missing }
                }
            } catch {
                return .failed  // offline, a server not up yet, cancelled: tried again next time
            }
        }
        return decode(data).map(Outcome.image) ?? .missing
    }

    /// Follows a redirect to this Mac or the local network only from an icon there (`Favicon.isPrivateHost`).
    private final class FaviconRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        let fromPrivate: Bool
        init(from url: URL) { fromPrivate = Favicon.isPrivateHost(url.host) }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return fromPrivate || !Favicon.isPrivateHost(url.host) ? request : nil
        }
    }

    /// A thumbnail of at most `pixels` (ICO, PNG, JPEG, GIF, WebP through ImageIO; SVG through NSImage).
    nonisolated static func decode(_ data: Data) -> NSImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: pixels,
               kCGImageSourceCreateThumbnailWithTransform: true,
           ] as CFDictionary) {
            return NSImage(cgImage: image, size: NSSize(width: 16, height: 16))
        }
        // SVG (ImageIO does not read it): drawn once into a small bitmap.
        guard let text = String(data: data.prefix(512), encoding: .utf8), text.contains("<svg"),
              let svg = NSImage(data: data), svg.isValid else { return nil }
        let bitmap = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            svg.draw(in: rect)
            return true
        }
        guard let cgImage = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 16, height: 16))
    }
}
