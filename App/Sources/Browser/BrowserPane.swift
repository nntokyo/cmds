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

    var currentURL: URL? { webView.url }
    var pageTitle: String { webView.title ?? "" }

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        buildLayout()
        observe()
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

    func reload() { webView.reload() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func focusAddressBar() {
        window?.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    func focus() {
        if webView.url == nil || addressField.stringValue.isEmpty { focusAddressBar() } else { window?.makeFirstResponder(webView) }
    }

    /// Runs `script` in the page and returns its JSON form (promises are awaited).
    /// An expression may use `await` (`await fetch("/api").then(r => r.json())`); a statement list keeps
    /// eval's completion value (`const a = 1; a + 1`), or, when it uses top-level `await`, runs as an async
    /// function body whose value is what it `return`s.
    func evaluateJavaScript(_ script: String) async throws -> JSONValue {
        // Parse checks use the Function constructors, which compile without running the script.
        let body = """
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
            return value === undefined ? null : JSON.stringify(value);
            """
        let result = try await webView.callAsyncJavaScript(body, arguments: ["__cmdsScript": script],
                                                          in: nil, contentWorld: .page)
        guard let json = result as? String, let data = json.data(using: .utf8) else { return .null }
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .string(json)
    }

    /// PNG of the visible page.
    func snapshot() async throws -> Data {
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, error in
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
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
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

        let toolbar = NSStackView(views: [backButton, forwardButton, reloadButton, addressField])
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbar)
        addSubview(webView)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 30),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
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

/// Address field that reports when it gains keyboard focus.
private final class AddressField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}
