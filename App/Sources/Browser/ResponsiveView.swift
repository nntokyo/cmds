import AppKit
import WebKit
import CmdsCore

/// The responsive view of a browser pane (#170; docs/guide/workspaces-and-panes.md "Responsive view"): the pane's
/// page in 2–4 frames side by side, each a web view of its device size, all scaled by one factor to fit the pane.
///
/// The pane's own web view is the first frame (so `browser.eval`, the address bar and the iPhone keep using it); the
/// others are web views of their own (each its own WebContent process), freed by `close()`.
/// - Navigation: when a frame's URL changes and it was not loading a URL this view gave it, the other frames load
///   that URL. A frame loading a URL from here ignores its own URL changes until a second after that load finished,
///   so per-device redirects (`m.` sites) do not bounce between frames.
/// - Scrolling: a script in cmds' content world reports the fraction of the scrollable height a frame is at, and
///   the others scroll to the same fraction of theirs (pages of different widths have different heights).
/// - Reload reloads every frame; a `file://` page reloads when the file changes.
@MainActor
final class ResponsiveView: NSView {
    /// Space between frames, in CSS pixels (scaled with them).
    static let gap: CGFloat = 24
    static let margin: CGFloat = 8
    static let labelHeight: CGFloat = 18
    /// How long a frame we navigated ignores its own URL changes after its load finished.
    static let settleTime: TimeInterval = 1
    static let scrollHandlerName = "cmdsResponsiveScroll"
    /// How long a file:// page waits after a change before every frame reloads (saves come in bursts).
    static let fileReloadDelay: TimeInterval = 0.2

    private final class Frame {
        let webView: WKWebView
        let target: BrowserSnapshotRequest.Target
        let label = NSTextField(labelWithString: "")
        /// Loading a URL this view gave it.
        var loadingFromSync = false
        var settledAt = Date.distantPast
        var observations: [NSKeyValueObservation] = []

        init(webView: WKWebView, target: BrowserSnapshotRequest.Target) {
            self.webView = webView
            self.target = target
        }

        var settling: Bool { loadingFromSync || Date().timeIntervalSince(settledAt) < ResponsiveView.settleTime }
    }

    private(set) var settings: BrowserResponsive
    private let host = ViewportHostView()
    private var frames: [Frame] = []
    private let primary: WKWebView
    /// The primary's user agent before the view (given back by `close()`).
    private let primaryUserAgent: String?
    /// The URL the frames show.
    private var syncedURL: URL?
    private var watcher: FileWatcher?
    private var reloadWork: DispatchWorkItem?
    private lazy var scrollHandler = WeakScriptHandler(self)

    var webViews: [WKWebView] { frames.map(\.webView) }
    var targets: [BrowserSnapshotRequest.Target] { frames.map(\.target) }

    init(primary: WKWebView, settings: BrowserResponsive) throws {
        let targets = try settings.targets()
        self.settings = settings
        self.primary = primary
        primaryUserAgent = primary.customUserAgent
        syncedURL = primary.url
        super.init(frame: .zero)
        host.onLayout = { [weak self] in self?.layoutFrames() }
        addSubview(host)
        for (index, target) in targets.enumerated() {
            let webView: WKWebView
            if index == 0 {
                webView = primary
                webView.setUserAgent(target.preset?.userAgent ?? primaryUserAgent)
            } else {
                let configuration = BrowserPane.webViewConfiguration(websiteDataStore: primary.configuration.websiteDataStore)
                webView = WKWebView(frame: .zero, configuration: configuration)
                webView.customUserAgent = target.preset?.userAgent ?? primaryUserAgent
                webView.appearance = primary.appearance
            }
            let frame = Frame(webView: webView, target: target)
            frame.label.stringValue = [target.preset?.name, target.size.description].compactMap { $0 }.joined(separator: "  ")
            frame.label.font = .systemFont(ofSize: 11)
            frame.label.textColor = .secondaryLabelColor
            frame.label.alignment = .center
            frame.label.lineBreakMode = .byTruncatingTail
            addSubview(frame.label)
            host.addSubview(webView)
            webView.translatesAutoresizingMaskIntoConstraints = true
            attachScrollScript(webView)
            observe(frame)
            frames.append(frame)
            if index > 0, let url = syncedURL, BrowserPane.isWebPage(url) { load(url, in: frame) }
        }
        watchFile()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: - Settings

    func setSyncScroll(_ on: Bool) {
        settings.syncScroll = on ? nil : false
    }

    func setAppearance(_ appearance: NSAppearance?) {
        for frame in frames.dropFirst() where frame.webView.appearance?.name != appearance?.name {
            frame.webView.appearance = appearance
        }
    }

    func reloadAll() {
        for frame in frames { frame.webView.reload() }
    }

    /// Takes the extra frames down (their WebContent processes end) and gives the primary back as it was.
    func close() {
        watcher?.cancel()
        watcher = nil
        reloadWork?.cancel()
        for (index, frame) in frames.enumerated() {
            frame.observations.removeAll()
            let controller = frame.webView.configuration.userContentController
            controller.removeScriptMessageHandler(forName: Self.scrollHandlerName, contentWorld: .defaultClient)
            // The scroll script stays (WebKit cannot remove one user script; the pane's console capture is another):
            // without its handler it posts nothing, and turning the view on again does not add it twice.
            frame.label.removeFromSuperview()
            frame.webView.removeFromSuperview()
            if index > 0 {
                frame.webView.stopLoading()
                frame.webView.navigationDelegate = nil
            }
        }
        primary.setUserAgent(primaryUserAgent)
        frames.removeAll()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let area = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        host.frame = NSRect(x: area.minX, y: area.minY + Self.labelHeight, width: max(area.width, 1),
                            height: max(area.height - Self.labelHeight, 1))
        host.needsLayout = true
    }

    /// One scale for all frames, so their sizes compare; side by side, top-aligned, centred.
    private func layoutFrames() {
        let sizes = frames.map(\.target.size)
        guard !sizes.isEmpty, host.frame.width >= 1, host.frame.height >= 1 else { return }
        let totalWidth = sizes.reduce(0) { $0 + CGFloat($1.width) } + Self.gap * CGFloat(sizes.count - 1)
        let tallest = CGFloat(sizes.map(\.height).max() ?? 1)
        let scale = min(1, host.frame.width / totalWidth, host.frame.height / tallest)
        host.scale(to: scale)
        var x = ((host.bounds.width - totalWidth) / 2).rounded(.down)
        for frame in frames {
            let size = frame.target.size
            frame.webView.frame = NSRect(x: x, y: 0, width: CGFloat(size.width), height: CGFloat(size.height))
            if frame.webView.pageZoom != 1 { frame.webView.pageZoom = 1 }
            frame.label.frame = NSRect(x: host.frame.minX + x * scale, y: Self.margin,
                                       width: CGFloat(size.width) * scale, height: Self.labelHeight - 2)
            x += CGFloat(size.width) + Self.gap
        }
    }

    // MARK: - Navigation sync

    private func load(_ url: URL, in frame: Frame) {
        frame.loadingFromSync = true
        if url.isFileURL {
            frame.webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            frame.webView.load(URLRequest(url: url))
        }
    }

    private func observe(_ frame: Frame) {
        frame.observations = [
            frame.webView.observe(\.url) { [weak self, weak frame] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, let frame else { return }
                    self.urlChanged(webView.url, in: frame)
                }
            },
            frame.webView.observe(\.isLoading) { [weak frame] webView, _ in
                MainActor.assumeIsolated {
                    guard let frame, !webView.isLoading, frame.loadingFromSync else { return }
                    frame.loadingFromSync = false
                    frame.settledAt = Date()
                }
            },
        ]
    }

    private func urlChanged(_ url: URL?, in source: Frame) {
        guard let url, BrowserPane.isWebPage(url), !source.settling, url != syncedURL else { return }
        syncedURL = url
        for frame in frames where frame !== source && frame.webView.url != url {
            load(url, in: frame)
        }
        watchFile()
    }

    // MARK: - Reload on file change

    private func watchFile() {
        let path = syncedURL?.isFileURL == true ? syncedURL?.path : nil
        guard watcher?.path != path else { return }
        watcher?.cancel()
        watcher = path.map { path in
            FileWatcher(path: path) { [weak self] in self?.scheduleReload() }
        }
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.watcher?.rearm()
                self?.reloadAll()
            }
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fileReloadDelay, execute: work)
    }

    // MARK: - Scroll sync

    private func attachScrollScript(_ webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.scrollHandlerName, contentWorld: .defaultClient)
        controller.add(scrollHandler, contentWorld: .defaultClient, name: Self.scrollHandlerName)
        if !controller.userScripts.contains(where: { $0.source == ResponsiveScroll.frameScript }) {
            controller.addUserScript(WKUserScript(source: ResponsiveScroll.frameScript, injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true, in: .defaultClient))
        }
        // The page already shown (the primary's) gets it now.
        webView.evaluateJavaScript(ResponsiveScroll.frameScript, in: nil, in: .defaultClient) { _ in }
    }

    fileprivate func scrolled(_ webView: WKWebView?, fraction: Double) {
        guard settings.scrollSynced, let source = frames.first(where: { $0.webView === webView }), !source.settling,
              fraction.isFinite else { return }
        for frame in frames where frame !== source && !frame.loadingFromSync {
            frame.webView.callAsyncJavaScript("if (window.__cmdsScrollTo) window.__cmdsScrollTo(fraction);",
                                              arguments: ["fraction": fraction], in: nil, in: .defaultClient) { _ in }
        }
    }

    // MARK: - Snapshots and tests

    /// The visible page of every frame at its device size.
    func snapshots() async throws -> [BrowserSnapshotImage] {
        var images: [BrowserSnapshotImage] = []
        for frame in frames {
            let configuration = WKSnapshotConfiguration()
            configuration.snapshotWidth = NSNumber(value: frame.target.size.width)
            let png = try await BrowserPane.png(of: frame.webView, configuration: configuration)
            images.append(BrowserSnapshotImage(device: frame.target.label, width: frame.target.size.width,
                                               height: frame.target.size.height, png: png))
        }
        return images
    }

    /// `debug.browser`: each frame's device, URL, title and size in the pane.
    var debugFrames: JSONValue {
        .array(frames.map { frame in
            let rect = convert(frame.webView.frame, from: host)
            return .object([
                "device": .string(frame.target.label),
                "url": frame.webView.url.map { .string($0.absoluteString) } ?? .null,
                "title": .string(frame.webView.title ?? ""),
                "frame": .array([rect.minX, rect.minY, rect.width, rect.height].map { .number(Double($0)) }),
            ])
        })
    }
}

/// The scroll handler without a retain cycle (the content controller keeps its handlers).
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var view: ResponsiveView?

    init(_ view: ResponsiveView) { self.view = view }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let fraction = (body["fraction"] as? NSNumber)?.doubleValue else {
            return
        }
        let webView = message.webView
        MainActor.assumeIsolated { view?.scrolled(webView, fraction: fraction) }
    }
}
