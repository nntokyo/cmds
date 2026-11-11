import AppKit
import WebKit
import CmdsCore

/// In-app browser pane: compact toolbar + WKWebView. Also the scripting surface for `browser.*` socket methods.
@MainActor
final class BrowserPane: NSView {
    /// Title or URL changed.
    var onStateChange: (() -> Void)?
    /// The user clicked into the page or the address field.
    var onFocus: (() -> Void)?

    let webView: WKWebView
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
    // Pop-ups, `_blank` links, dialogs, uploads and downloads (BrowserPageDelegate.swift, #235).
    /// Opens a `target="_blank"` link in a new browser pane beside this one; false: none could be opened.
    var onOpenInNewPane: ((URL) -> Bool)?
    let pageDelegate = BrowserPageDelegate()
    private var downloadBanner: BrowserDownloadBannerView?
    private var downloadBannerHide: DispatchWorkItem?
    /// How long a finished download's notice stays.
    static let downloadNoticeTime: TimeInterval = 10

    var currentURL: URL? { webView.url }
    var pageTitle: String { webView.title ?? "" }

    init(emulation: BrowserEmulation = BrowserEmulation()) {
        webView = WKWebView(frame: .zero, configuration: Self.webViewConfiguration(websiteDataStore: .default()))
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
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

    /// Loads `input`: a URL (scheme optional) or, for anything else, a web search.
    func navigate(to input: String) {
        guard let url = Self.url(fromUserInput: input) else { return }
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
        if let responsiveView { responsiveView.reloadAll() } else { webView.reload() }
    }
    func goBack() { webView.goBack() }
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
    func evaluateJavaScript(_ script: String) async throws -> JSONValue {
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
        let result = try await webView.callAsyncJavaScript(body, arguments: ["__cmdsScript": script], in: nil,
                                                           contentWorld: .page)
        if let refused = result as? [String: Any], refused["cmdsNoEval"] as? Bool == true {
            return try await evaluateWithoutEval(script)
        }
        return Self.decodeEvaluation(result)
    }

    /// For pages whose Content Security Policy refuses eval and the Function constructors (no 'unsafe-eval', #88):
    /// WebKit compiles the script itself, which the page's policy does not cover. The script runs as an expression,
    /// else as an async function body whose value is what it `return`s (a statement list's last value is not kept).
    /// Only a failure to parse moves on to the body form; what the script throws is its result, so it runs once.
    private func evaluateWithoutEval(_ script: String) async throws -> JSONValue {
        /// The value, or the message of what the script threw. WebKit throws only when the source does not parse.
        func run(_ value: String) async throws -> Result<JSONValue, NSError> {
            let result = try await webView.callAsyncJavaScript("""
                let value;
                try { value = \(value); } catch (e) { return { cmdsThrew: String(e) }; }
                \(Self.returnValueAsJSON)
                """, arguments: [:], in: nil, contentWorld: .page)
            if let thrown = result as? [String: Any], let message = thrown["cmdsThrew"] as? String {
                return .failure(NSError(domain: WKError.errorDomain, code: WKError.javaScriptExceptionOccurred.rawValue,
                                        userInfo: [Self.javaScriptExceptionMessageKey: message]))
            }
            return .success(Self.decodeEvaluation(result))
        }
        /// While on, the console hook ignores the error event of the expression form's failure to parse (#201).
        func quietConsole(_ on: Bool) async {
            _ = try? await webView.callAsyncJavaScript(
                "document.dispatchEvent(new CustomEvent(name, { detail: on }));",
                arguments: ["name": consoleEventName + "-quiet", "on": on], in: nil, contentWorld: .page)
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
        downloadBannerHide?.cancel()
        observations.removeAll()
        webView.stopLoading()
        BrowserPageDelegate.detach(webView)
    }

    /// The text of the download notice shown (`debug.browser`).
    var downloadNoticeText: String? { downloadBanner?.toolTip }

    /// A download's notice at the bottom of the page area (nil: removes it; the top would cover the address bar).
    /// `onCancel` stops a running download.
    func showDownload(_ state: BrowserDownloadBannerView.State?, onCancel: (() -> Void)? = nil) {
        downloadBannerHide?.cancel()
        downloadBannerHide = nil
        downloadBanner?.removeFromSuperview()
        downloadBanner = nil
        guard let state else { return }
        let banner = BrowserDownloadBannerView(state: state)
        banner.onDismiss = { [weak self, weak banner] in
            guard let self, let banner, self.downloadBanner === banner else { return }
            self.showDownload(nil)
        }
        banner.onCancel = { [weak self, weak banner] in
            onCancel?()
            guard let self, let banner, self.downloadBanner === banner else { return }
            self.showDownload(nil)
        }
        downloadBanner = banner
        banner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(banner)  // above the page and the responsive view
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: viewportHost.leadingAnchor, constant: 8),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: viewportHost.trailingAnchor, constant: -8),
            banner.bottomAnchor.constraint(equalTo: viewportHost.bottomAnchor, constant: -8),
        ])
        if case .finished = state {
            let hide = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.showDownload(nil) } }
            downloadBannerHide = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.downloadNoticeTime, execute: hide)
        }
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

    static func url(fromUserInput raw: String) -> URL? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if input.contains("://") || input.hasPrefix("about:") || input.hasPrefix("data:") {
            return URL(string: input)
        }
        let looksLocal = input.hasPrefix("localhost") || input.hasPrefix("127.0.0.1") || input.hasPrefix("[::1]")
            || input.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?(/.*)?$"#, options: .regularExpression) != nil
        if looksLocal { return URL(string: "http://" + input) }
        if !input.contains(" "), input.contains("."), let url = URL(string: "https://" + input), url.host != nil {
            return url
        }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: input)]
        return components.url
    }

    // MARK: - Layout

    private static func toolbarButton(_ symbol: String, label: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = label
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func buildLayout() {
        backButton.target = self
        backButton.action = #selector(backClicked)
        forwardButton.target = self
        forwardButton.action = #selector(forwardClicked)
        reloadButton.target = self
        reloadButton.action = #selector(reloadClicked)

        addressField.placeholderString = String(localized: "Search or enter address")
        addressField.font = .systemFont(ofSize: 12)
        addressField.bezelStyle = .roundedBezel
        addressField.controlSize = .small
        addressField.lineBreakMode = .byTruncatingTail
        addressField.usesSingleLineMode = true
        addressField.target = self
        addressField.action = #selector(addressSubmitted)
        addressField.onFocus = { [weak self] in self?.onFocus?() }

        let toolbar = NSStackView(views: [backButton, forwardButton, reloadButton, addressField, breakpointLabel, deviceButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        // A narrow pane drops the indicator before squeezing the address field.
        toolbar.setVisibilityPriority(.detachOnlyIfNecessary, for: breakpointLabel)
        buildDeviceControls()
        viewportHost.translatesAutoresizingMaskIntoConstraints = false
        viewportHost.addSubview(webView)
        addSubview(toolbar)
        addSubview(viewportHost)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 30),
            viewportHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            viewportHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            viewportHost.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            viewportHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateButtons()
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

    private func stateDidChange() {
        if window?.firstResponder !== addressField.currentEditor() {
            let url = webView.url
            addressField.stringValue = url?.scheme == "about" ? "" : (url?.absoluteString ?? "")
        }
        updateButtons()
        onStateChange?()
    }

    private func updateButtons() {
        backButton.isEnabled = webView.canGoBack
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
        navigate(to: addressField.stringValue)
        window?.makeFirstResponder(webView)
    }
}

extension WKWebView {
    /// Sends `agent` from now on (nil: WebKit's own). A web page shown is reloaded: servers see a new user agent only
    /// with a new request.
    func setUserAgent(_ agent: String?) {
        guard customUserAgent != agent else { return }
        customUserAgent = agent
        if BrowserPane.isWebPage(url) { reload() }
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
