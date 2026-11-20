import AppKit
import WebKit
import CoreServices
import CmdsCore

/// In-app browser pane: compact toolbar + WKWebView. Also the scripting surface for `browser.*` socket methods.
@MainActor
final class BrowserPane: NSView {
    /// Title or URL changed.
    var onStateChange: (() -> Void)?
    /// The user clicked into the page or the address field.
    var onFocus: (() -> Void)?

    /// Replaced only when its page stopped responding (`replaceStuckWebView`).
    private(set) var webView: WKWebView
    private let addressField = AddressField()
    private let backButton = BrowserPane.toolbarButton("chevron.left", label: String(localized: "Back"))
    private let forwardButton = BrowserPane.toolbarButton("chevron.right", label: String(localized: "Forward"))
    private let reloadButton = BrowserPane.toolbarButton("arrow.clockwise", label: String(localized: "Reload"))
    private var observations: [NSKeyValueObservation] = []
    /// Settings default the page zoom was last set to.
    private var appliedDefaultZoom = AppSettings.shared.browserZoom

    // Device sizes, user agent and color scheme (BrowserPane+Device.swift, #168).
    /// Settings changed by the user or the API (the session saves them).
    var onEmulationChange: (() -> Void)?
    var emulation: BrowserEmulation
    /// Page zoom while the page fills the pane; a device size scales the page to fit instead.
    var fillZoom = AppSettings.shared.browserZoom
    /// Holds the web view: the whole area, or a device-sized frame scaled to fit.
    let viewportHost = ViewportHostView()
    /// CSS width, breakpoint range and scale.
    let breakpointLabel = NSTextField(labelWithString: "")
    let deviceButton = BrowserPane.toolbarButton("ipad.and.iphone", label: String(localized: "Device Size"))
    var breakpointRefresh: DispatchWorkItem?
    /// The responsive view while it is on (BrowserPane+Responsive.swift, #170); `webView` is then its first frame.
    var responsiveView: ResponsiveView?
    /// Console messages and errors of the page (BrowserPane+DevTools.swift, #167).
    var consoleBuffer = ConsoleBuffer()
    /// The DOM event the page-world console hook hands messages over with (random, so pages cannot fake it).
    let consoleEventName = "cmds-console-" + UUID().uuidString
    let passkeyEventName = "cmds-passkey-" + UUID().uuidString
    // Pop-ups, `_blank` links, dialogs, uploads and downloads (BrowserPageDelegate.swift, #235).
    /// Opens a `target="_blank"` link in a new browser pane beside this one; false: none could be opened.
    var onOpenInNewPane: ((URL) -> Bool)?
    /// Opens a page in a new tab beside this pane, in the background (a ⌘-click on a Chrome bookmark).
    var onOpenInNewTab: ((URL) -> Void)?
    /// Chrome's bookmarks under the toolbar (Settings › General).
    let bookmarksBar = ChromeBookmarksBarView()
    private var bookmarksBarHeight: NSLayoutConstraint?
    let pageDelegate = BrowserPageDelegate()
    private var noticeBanner: BrowserNoticeView?
    private var noticeHide: DispatchWorkItem?
    // Reload on file changes (BrowserPane+Watch.swift, #252).
    /// The folder watched and whether remote pages reload too; nil: off.
    var watch: BrowserWatch?
    /// Running while the pane is in a window and its page may reload.
    var directoryWatcher: DirectoryWatcher?
    /// Why the watcher wanted on screen is not watching (FSEvents did not start, or the folder is gone).
    var watchProblem: BrowserWatch.Problem?
    /// When the watcher stopped for the pane going off screen: what changed since is replayed when it is back.
    var watchEventID: FSEventStreamEventId?
    var watchDebounce = WatchDebounce()
    var watchReload: DispatchWorkItem?
    let watchButton = BrowserPane.toolbarButton("eye", label: BrowserPane.watchTitle)
    /// The folder watching starts with: the workspace's folder (set by the pane's owner).
    var defaultWatchFolder: (() -> String?)?
    #if DEBUG
    /// Reloads the watcher made (`debug.browser`).
    var watchReloadCount = 0
    /// The paths of the last changes that were not ignored (`debug.browser`).
    var watchCountedPaths: [String] = []
    #endif
    /// How long a finished download's notice stays.
    static let noticeTime: TimeInterval = 10
    /// Space between the notice and the page area's edges.
    static let noticeInset: CGFloat = 8

    // Load failures, sign-in and WebContent crashes (BrowserPane+LoadErrors.swift, #338).
    /// The page that did not load (or whose WebContent process ended) while its notice covers the page.
    var loadFailure: BrowserLoadFailure?
    var loadFailureView: BrowserLoadFailureView?
    /// The last page committed in the pane: what a crashed page reloads.
    var lastCommittedURL: URL?
    /// When a crashed page was last reloaded by itself (once a minute at most).
    var lastCrashReload: Date?
    // Find in page (BrowserPane+Find.swift, #338).
    var findBar: TerminalFindBar?

    /// The page shown, or the one that failed to load (the address bar and `browser.get_url` keep it).
    var currentURL: URL? { loadFailure?.url ?? webView.url }
    var pageTitle: String { loadFailure != nil ? "" : (webView.title ?? "") }

    init(emulation: BrowserEmulation = BrowserEmulation()) {
        webView = Self.makeWebView(configuration: Self.webViewConfiguration(websiteDataStore: .default()))
        self.emulation = emulation
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        pageDelegate.pane = self
        pageDelegate.attach(webView)
        buildLayout()
        observe()
        observeZoomSetting()
        startEmulation()
        startDevTools()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public API

    /// Loads `input`: a URL (scheme optional), a file path or, for anything else, a web search
    /// (`BrowserAddress.url(fromUserInput:)`). `mailto:`, `tel:` and the like go to the app that handles them.
    /// Throws for input with nothing to load (empty, or a URL that does not parse).
    func navigate(to input: String) throws {
        guard let url = Self.url(fromUserInput: input) else {
            throw RPCError.invalidParams("cannot load \"\(input.prefix(200))\": not a valid URL")
        }
        if BrowserAddress.opensExternally(url) {
            NSWorkspace.shared.open(url)
            return
        }
        webView.load(URLRequest(url: url))
        addressField.stringValue = url.absoluteString
    }

    func showStartPage() {
        webView.loadHTMLString("""
            <html><body style="background:#1c1c1e;color:#8e8e93;font:14px -apple-system;display:flex;\
            align-items:center;justify-content:center;height:90vh">\(String(localized: "Type a URL or search term (⌘L)"))</body></html>
            """, baseURL: nil)
        addressField.stringValue = ""
    }

    func reload() {
        if loadFailure != nil { return retryFailedLoad() }
        if let responsiveView { responsiveView.reloadAll() } else { webView.reload() }
    }
    func goBack() {
        // The page before the one that failed is still loaded under the notice: back shows it.
        if loadFailure?.crashed == false { return clearLoadFailure() }
        webView.goBack()
    }
    func goForward() { webView.goForward() }

    func focusAddressBar() {
        window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    func focus() {
        if webView.url == nil || addressField.stringValue.isEmpty { focusAddressBar() } else { window?.makeFirstResponder(webView) }
    }

    /// `userInfo` key of the message of a JavaScript exception in WebKit errors ("Error: …").
    static let javaScriptExceptionMessageKey = "WKJavaScriptExceptionMessage"
    /// Script ending of both evaluation paths: `value` as JSON text, null for undefined.
    private static let returnValueAsJSON = "return value === undefined ? null : JSON.stringify(value);"

    /// Runs `script` in the page and returns its JSON form (promises are awaited).
    /// An expression may use `await` (`await fetch("/api").then(r => r.json())`); a statement list keeps
    /// eval's completion value (`const a = 1; a + 1`), or, when it uses top-level `await`, runs as an async
    /// function body whose value is what it `return`s. Pages that refuse eval: `evaluateWithoutEval`.
    /// A script still running after `timeout` seconds gets a 408 error; a page that stopped responding (a script that
    /// never yields) is then loaded again in a new web view (`scriptTimedOut`, #338).
    func evaluateJavaScript(_ script: String,
                            timeout: TimeInterval = BrowserEval.defaultTimeout) async throws -> JSONValue {
        let deadline = Date(timeIntervalSinceNow: timeout)
        do {
            return try await evaluateJavaScript(script, until: deadline)
        } catch is PageScriptTimeout {
            throw await scriptTimedOut(after: timeout)
        }
    }

    private func evaluateJavaScript(_ script: String, until deadline: Date) async throws -> JSONValue {
        // Parse checks use the Function constructors, which compile without running the script.
        let body = """
            try { new Function(""); } catch (e) { if (e instanceof EvalError) return { cmdsNoEval: true }; throw e; }
            const AsyncFunction = (async function () {}).constructor;
            const parses = (make) => {
              try { make(); return true; } catch (e) { if (e instanceof SyntaxError) return false; throw e; }
            };
            const src = __cmdsScript;
            const asExpression = "return (" + src + "\\n);";
            let value;
            if (parses(() => new AsyncFunction(asExpression))) {
              value = await new AsyncFunction(asExpression)();
            } else if (parses(() => new Function(src))) {
              // A top-level `return` fails eval at parse time (nothing has run), so retry it as a function body.
              try {
                value = await (0, eval)(src);
              } catch (e) {
                if (!(e instanceof SyntaxError && /Return statements are only valid inside functions/.test(e.message))) throw e;
                value = await new Function(src)();
              }
            } else {
              value = await new AsyncFunction(src)();
            }
            \(Self.returnValueAsJSON)
            """
        // The page's eval check comes first, so nothing of the script has run when it falls back.
        let result = try await webView.callScript(body, arguments: ["__cmdsScript": script], in: .page, until: deadline)
        if let refused = result as? [String: Any], refused["cmdsNoEval"] as? Bool == true {
            return try await evaluateWithoutEval(script, until: deadline)
        }
        return Self.decodeEvaluation(result)
    }

    /// How long a page whose script timed out has to answer a trivial script before it counts as stuck.
    static let responsiveCheckTime: TimeInterval = 2

    /// The error for a script past its deadline. When the page does not answer a trivial script either, its script
    /// never yields and its WebContent process is busy for good (WebKit has no public way to stop it): the pane gets a
    /// new web view and loads the page again.
    func scriptTimedOut(after seconds: TimeInterval) async -> RPCError {
        let stuck = webView
        let answers: Bool
        do {
            _ = try await stuck.callScript("return 1;", in: .defaultClient,
                                           until: Date(timeIntervalSinceNow: Self.responsiveCheckTime))
            answers = true
        } catch {
            answers = !(error is PageScriptTimeout)
        }
        if !answers, webView === stuck { replaceStuckWebView() }
        return RPCError(code: 408, message: BrowserEval.timeoutMessage(seconds: seconds, reloaded: webView !== stuck))
    }

    /// Gives the pane a new web view (its own WebContent process) with the same scripts, settings and data store, and
    /// loads the page again; back/forward history starts over. The stuck web view is freed and its process ended
    /// (`endWebContentProcess`). For a page that stopped responding (`scriptTimedOut`). The old web view's delegate
    /// is detached before its process is killed, so the crash handling (`webContentProcessDidTerminate`) does not
    /// reload the page a second time or show its notice.
    private func replaceStuckWebView() {
        let old = webView
        let url = old.url ?? lastCommittedURL
        let responsiveSettings = responsive
        if responsiveSettings != nil { setResponsive(nil) }
        pageDelegate.tearDown()  // pop-ups share the stuck process
        observations.removeAll()
        breakpointRefresh?.cancel()
        old.stopLoading()
        BrowserPageDelegate.detach(old)
        old.removeFromSuperview()
        Self.endWebContentProcess(of: old)

        let configuration = Self.webViewConfiguration(websiteDataStore: old.configuration.websiteDataStore)
        configuration.userContentController = old.configuration.userContentController  // console and passkey capture
        webView = Self.makeWebView(configuration: configuration)
        webView.customUserAgent = emulation.userAgent
        pageDelegate.attach(webView)
        viewportHost.addSubview(webView)
        observe()
        applyColorScheme()
        applyInspectable()
        layoutWebView()
        if let responsiveSettings { setResponsive(responsiveSettings) }
        clearLoadFailure()
        if let url, url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else if let url, Self.isWebPage(url) {
            webView.load(URLRequest(url: url))
        } else {
            showStartPage()
        }
        stateDidChange()
    }

    /// For pages whose Content Security Policy refuses eval and the Function constructors (no 'unsafe-eval', #88):
    /// WebKit compiles the script itself, which the page's policy does not cover. The script runs as an expression,
    /// else as an async function body whose value is what it `return`s (a statement list's last value is not kept).
    /// Only a failure to parse moves on to the body form; what the script throws is its result, so it runs once.
    private func evaluateWithoutEval(_ script: String, until deadline: Date) async throws -> JSONValue {
        /// The value, or the message of what the script threw. WebKit throws only when the source does not parse.
        func run(_ value: String) async throws -> Result<JSONValue, NSError> {
            let result = try await webView.callScript("""
                let value;
                try { value = \(value); } catch (e) { return { cmdsThrew: String(e) }; }
                \(Self.returnValueAsJSON)
                """, in: .page, until: deadline)
            if let thrown = result as? [String: Any], let message = thrown["cmdsThrew"] as? String {
                return .failure(NSError(domain: WKError.errorDomain, code: WKError.javaScriptExceptionOccurred.rawValue,
                                        userInfo: [Self.javaScriptExceptionMessageKey: message]))
            }
            return .success(Self.decodeEvaluation(result))
        }
        /// While on, the console hook ignores the error event of the expression form's failure to parse (#201).
        /// Turning it off again gets a little time even after the deadline.
        func quietConsole(_ on: Bool) async {
            _ = try? await webView.callScript(
                "document.dispatchEvent(new CustomEvent(name, { detail: on }));",
                arguments: ["name": consoleEventName + "-quiet", "on": on], in: .page,
                until: on ? deadline : max(deadline, Date(timeIntervalSinceNow: Self.responsiveCheckTime)))
        }
        await quietConsole(true)
        let expression: Result<Result<JSONValue, NSError>, Error>
        do { expression = .success(try await run("await (\n\(script)\n)")) } catch { expression = .failure(error) }
        await quietConsole(false)
        let result: Result<JSONValue, NSError>
        switch expression {
        case .success(let value):
            result = value
        case .failure(let error as WKError) where error.code == .javaScriptExceptionOccurred
                && (error.userInfo[Self.javaScriptExceptionMessageKey] as? String)?.hasPrefix("SyntaxError") == true:
            result = try await run("await (async () => {\n\(script)\n})()")
        case .failure(let error):
            throw error
        }
        return try result.get()
    }

    private static func decodeEvaluation(_ result: Any?) -> JSONValue {
        guard let json = result as? String, let data = json.data(using: .utf8) else { return .null }
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .string(json)
    }

    /// PNG of the visible page; with a device size, at that size (not scaled down to the pane).
    func snapshot() async throws -> Data {
        // A pane of a workspace that is not shown has no window; render it off screen meanwhile.
        try await OffscreenRenderHost.rendering(webView) {
            let configuration = WKSnapshotConfiguration()
            if let size = emulation.size { configuration.snapshotWidth = NSNumber(value: size.width) }
            return try await Self.png(of: webView, configuration: configuration)
        }
    }

    /// PNG of `configuration`'s part of `webView` (its rect may reach beyond the visible page: WebKit paints the
    /// document for it).
    static func png(of webView: WKWebView, configuration: WKSnapshotConfiguration) async throws -> Data {
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let image { continuation.resume(returning: image) } else {
                    continuation.resume(throwing: error ?? RPCError(code: 500, message: "snapshot failed"))
                }
            }
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RPCError(code: 500, message: "PNG encoding failed")
        }
        return png
    }

    func tearDown() {
        responsiveView?.close()  // frees the extra frames' WebContent processes
        responsiveView = nil
        pageDelegate.tearDown()  // answers open dialogs, closes pop-ups
        stopWatching()
        noticeHide?.cancel()
        observations.removeAll()
        breakpointRefresh?.cancel()
        NotificationCenter.default.removeObserver(self)
        webView.stopLoading()
        BrowserPageDelegate.detach(webView)
        // The content controller keeps its handlers; the callbacks are the owner's. Neither may keep the pane (#338).
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        onStateChange = nil
        onFocus = nil
        onEmulationChange = nil
        onOpenInNewPane = nil
        onOpenInNewTab = nil
        defaultWatchFolder = nil
    }

    #if DEBUG
    /// The text of the notice shown (`debug.browser`).
    var noticeText: String? { noticeBanner?.toolTip }
    #endif

    /// The notice at the bottom of the page area: a download or a passkey request (nil: removes it; the top would cover
    /// the address bar).
    /// `onCancel` stops a running download.
    func showNotice(_ state: BrowserNoticeView.State?, onCancel: (() -> Void)? = nil) {
        noticeHide?.cancel()
        noticeHide = nil
        noticeBanner?.removeFromSuperview()
        noticeBanner = nil
        guard let state else { return }
        let banner = BrowserNoticeView(state: state)
        banner.onDismiss = { [weak self, weak banner] in self?.removeNotice(banner) }
        banner.onCancel = { [weak self, weak banner] in
            onCancel?()
            self?.removeNotice(banner)
        }
        noticeBanner = banner
        banner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(banner)  // above the page and the responsive view
        let inset = Self.noticeInset
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: viewportHost.leadingAnchor, constant: inset),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: viewportHost.trailingAnchor, constant: -inset),
            banner.bottomAnchor.constraint(equalTo: viewportHost.bottomAnchor, constant: -inset),
        ])
        if case .finished = state {
            let hide = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.showNotice(nil) } }
            noticeHide = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.noticeTime, execute: hide)
        }
    }

    /// Removes `banner` when it is still the notice shown (a newer download's notice stays).
    private func removeNotice(_ banner: BrowserNoticeView?) {
        guard let banner, noticeBanner === banner else { return }
        showNotice(nil)
    }

    /// Ends the WebContent process of a web view whose page stopped responding. Freeing the web view is not enough:
    /// WebKit closes the page, but the process's main thread never gets to it and spins at 100 % CPU until the app
    /// quits (checked on macOS 27; WebKit's `_killWebContentProcess` did not end it either). WebKit has no public call
    /// for it, so this reads the process id WebKit's `_webProcessIdentifier` reports and kills it: every page in that
    /// process is frozen with it (they share its main thread). Without that property the pane still recovers (a new
    /// web view); only the old process stays.
    private static func endWebContentProcess(of webView: WKWebView) {
        let identifier = NSSelectorFromString("_webProcessIdentifier")
        guard webView.responds(to: identifier),
              let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value,
              pid > 1, pid != getpid() else { return }
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &name, UInt32(name.count)) > 0, String(cString: name).contains("WebContent") else {
            return
        }
        kill(pid, SIGKILL)
    }

    /// The pane's web view (also when a stuck one is replaced).
    private static func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        return webView
    }

    /// A browser pane's web view settings (also the responsive view's extra frames, with the pane's data store).
    static func webViewConfiguration(websiteDataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.preferences.isElementFullscreenEnabled = true
        return configuration
    }

    /// An http, https or file page (what can be loaded again elsewhere, and what a server or file gives).
    static func isWebPage(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return ["http", "https", "file"].contains(scheme)
    }

    static func url(fromUserInput raw: String) -> URL? { BrowserAddress.url(fromUserInput: raw) }

    // MARK: - Layout

    static func toolbarButton(_ symbol: String, label: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = label
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    /// A toolbar button's menu (device, watch), opened just below the button.
    func popUpToolbarMenu(_ menu: NSMenu, below button: NSButton) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func buildLayout() {
        backButton.target = self
        backButton.action = #selector(backClicked)
        forwardButton.target = self
        forwardButton.action = #selector(forwardClicked)
        reloadButton.target = self
        reloadButton.action = #selector(reloadClicked)
        watchButton.target = self
        watchButton.action = #selector(watchButtonClicked(_:))
        updateWatchButton()

        addressField.placeholderString = String(localized: "Search or enter address")
        addressField.font = .systemFont(ofSize: 12)
        addressField.bezelStyle = .roundedBezel
        addressField.controlSize = .small
        addressField.lineBreakMode = .byTruncatingTail
        addressField.usesSingleLineMode = true
        addressField.target = self
        addressField.action = #selector(addressSubmitted)
        addressField.onFocus = { [weak self] in self?.onFocus?() }

        let toolbar = NSStackView(views: [backButton, forwardButton, reloadButton, watchButton, addressField, breakpointLabel, deviceButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        // A narrow pane drops the indicator before squeezing the address field.
        toolbar.setVisibilityPriority(.detachOnlyIfNecessary, for: breakpointLabel)
        buildDeviceControls()
        viewportHost.translatesAutoresizingMaskIntoConstraints = false
        viewportHost.addSubview(webView)
        bookmarksBar.translatesAutoresizingMaskIntoConstraints = false
        bookmarksBar.onOpen = { [weak self] url, newTab in
            guard let self else { return }
            if newTab, let open = self.onOpenInNewTab { open(url) } else { try? self.navigate(to: url.absoluteString) }
        }
        bookmarksBar.onVisibilityChange = { [weak self] in self?.updateBookmarksBar() }
        addSubview(toolbar)
        addSubview(bookmarksBar)
        addSubview(viewportHost)
        let barHeight = bookmarksBar.heightAnchor.constraint(equalToConstant: 0)
        bookmarksBarHeight = barHeight
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 30),
            bookmarksBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bookmarksBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bookmarksBar.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            barHeight,
            viewportHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            viewportHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            viewportHost.topAnchor.constraint(equalTo: bookmarksBar.bottomAnchor),
            viewportHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateBookmarksBar()
        updateButtons()
    }

    /// Shows the bookmarks bar when it has something to show (the store is empty while the setting is off).
    private func updateBookmarksBar() {
        let shown = bookmarksBar.hasContent
        bookmarksBar.isHidden = !shown
        bookmarksBarHeight?.constant = shown ? ChromeBookmarksBarView.height : 0
    }

    private func observe() {
        observations = [
            webView.observe(\.url) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.stateDidChange() }
            },
            webView.observe(\.title) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.stateDidChange() }
            },
            webView.observe(\.canGoBack) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateButtons() }
            },
            webView.observe(\.canGoForward) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateButtons() }
            },
            webView.observe(\.isLoading) { [weak self] webView, _ in
                MainActor.assumeIsolated { if !webView.isLoading { self?.scheduleBreakpointRefresh() } }
            },
            NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.applyColorScheme() }
            },
        ]
    }

    func stateDidChange() {
        if let url = webView.url, loadFailure == nil { lastCommittedURL = url }
        if window?.firstResponder !== addressField.currentEditor() {
            let url = currentURL
            addressField.stringValue = url?.scheme == "about" ? "" : (url?.absoluteString ?? "")
        }
        updateButtons()
        if watch != nil {
            updateWatcher()  // a page that does not reload (remote) pauses the watcher
            updateWatchButton()
        }
        onStateChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard watch != nil else { return }
        updateWatcher()  // only while on screen; a hidden workspace's panes have no window
        updateWatchButton()
    }

    private func updateButtons() {
        backButton.isEnabled = webView.canGoBack || loadFailure?.crashed == false  // back from a failed load
        forwardButton.isEnabled = webView.canGoForward
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }

    @objc private func backClicked() { goBack() }
    @objc private func forwardClicked() { goForward() }
    @objc private func reloadClicked() { reload() }

    @objc private func addressSubmitted() {
        guard (try? navigate(to: addressField.stringValue)) != nil else { return NSSound.beep() }
        window?.makeFirstResponder(webView)
    }
}

/// A page script gave no answer by its deadline (`WKWebView.callScript`).
struct PageScriptTimeout: Error {}

extension WKWebView {
    /// `callAsyncJavaScript` in the main frame that gives up at `deadline` (nil: waits) with `PageScriptTimeout`.
    /// Unlike WebKit's async form it does not keep the web view while it waits: a page that never answers (a script
    /// that never yields, a document gone with a navigation) would keep it, and its WebContent process, for good
    /// (#338).
    func callScript(_ body: String, arguments: [String: Any] = [:], in world: WKContentWorld,
                    until deadline: Date?) async throws -> Any? {
        let answer = ScriptAnswer()
        return try await withCheckedThrowingContinuation { continuation in
            answer.continuation = continuation
            callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
                MainActor.assumeIsolated { answer.finish(result.map { $0 as Any? }) }
            }
            if let deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow)) {
                    MainActor.assumeIsolated { answer.finish(.failure(PageScriptTimeout())) }
                }
            }
        }
    }

    /// Sends `agent` from now on (nil: WebKit's own). A web page shown is reloaded: servers see a new user agent only
    /// with a new request.
    func setUserAgent(_ agent: String?) {
        guard customUserAgent != agent else { return }
        customUserAgent = agent
        if BrowserPane.isWebPage(url) { reload() }
    }
}

/// The first of a script's answer and its deadline (`WKWebView.callScript`).
@MainActor
private final class ScriptAnswer {
    var continuation: CheckedContinuation<Any?, Error>?

    func finish(_ result: Result<Any?, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// Address field that reports when it gains keyboard focus.
private final class AddressField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}

// MARK: - Page zoom (cmds › Settings… default; View › Bigger / Smaller / Actual Size for this pane)

extension BrowserPane: TextSizeActions {
    /// Starts at the default zoom and follows changes of it.
    func observeZoomSetting() {
        webView.pageZoom = AppSettings.shared.browserZoom
        NotificationCenter.default.addObserver(self, selector: #selector(zoomSettingChanged),
                                               name: AppSettings.didChange, object: nil)
    }

    @objc private func zoomSettingChanged() {
        let zoom = AppSettings.shared.browserZoom
        guard zoom != appliedDefaultZoom else { return }
        appliedDefaultZoom = zoom
        setFillZoom(zoom)
    }

    // With a device size the page is scaled to fit the pane, so the zoom applies once it fills the pane again.
    @objc func cmdsTextBigger(_ sender: Any?) { setFillZoom(PageZoomSteps.bigger(fillZoom)) }
    @objc func cmdsTextSmaller(_ sender: Any?) { setFillZoom(PageZoomSteps.smaller(fillZoom)) }
    @objc func cmdsTextActualSize(_ sender: Any?) { setFillZoom(AppSettings.shared.browserZoom) }

    private func setFillZoom(_ zoom: Double) {
        fillZoom = zoom
        layoutWebView()
    }
}
