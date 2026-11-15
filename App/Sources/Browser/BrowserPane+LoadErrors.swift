import AppKit
import WebKit
import CmdsCore

// Pages that do not load and WebContent processes that end (#338; docs/guide/workspaces-and-panes.md "Browser panes").
//
// - A failed navigation of the pane's page (connection refused, server not found, an untrusted certificate, too many
//   redirects…) covers the page area with a notice: the failed URL, the system's reason and Reload. The address bar and
//   `browser.get_url` keep the failed URL (`error`: the reason in English) until another page commits. Back shows the
//   page before it again (still loaded under the notice).
// - An untrusted certificate is refused. Continue Anyway on the notice trusts that host and port for the rest of the
//   session (`BrowserPageDelegate.trustedHosts`, never saved); there is no API for it.
// - A WebContent process that ends reloads its page by itself once a minute at most; another crash within the minute
//   leaves the notice with Reload. The URL stays in the address bar and `browser.get_url` meanwhile.

/// Why the pane's page is not shown.
struct BrowserLoadFailure {
    /// The page that failed (nil: unknown).
    let url: URL?
    /// For the API, in English (`BrowserLoadError.reason`).
    let reason: String
    /// For the notice, in the app's language.
    let message: String
    /// The server's certificate is not trusted: the notice offers Continue Anyway.
    let untrustedHost: String?
    /// The WebContent process ended (no page is loaded under the notice).
    let crashed: Bool
}

extension BrowserPane {
    /// A navigation of `webView` failed (`BrowserPageDelegate`): the notice, unless it was only replaced or cancelled.
    func loadDidFail(in webView: WKWebView, error: Error, url pendingURL: URL?) {
        guard webView === self.webView else { return }
        let nsError = error as NSError
        guard !BrowserLoadError.isIgnored(domain: nsError.domain, code: nsError.code) else { return }
        let url = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
            ?? pendingURL
        let certificate = BrowserLoadError.isCertificateError(domain: nsError.domain, code: nsError.code)
        var message = nsError.localizedDescription
        if certificate {
            message += "\n" + String(localized: "Continue only if you know this server, such as a development server with a self-signed certificate.")
        }
        showLoadFailure(BrowserLoadFailure(
            url: url, reason: BrowserLoadError.reason(domain: nsError.domain, code: nsError.code), message: message,
            untrustedHost: certificate ? url.flatMap(BrowserPageDelegate.trustKey) : nil, crashed: false))
    }

    /// The WebContent process of `webView` ended: reload once, else the notice with Reload.
    func webContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else {
            webView.reload()  // a responsive view's other frame
            return
        }
        let url = loadFailure?.url ?? webView.url ?? lastCommittedURL
        let now = Date()
        if let url, lastCrashReload.map({ now.timeIntervalSince($0) > 60 }) ?? true {
            lastCrashReload = now
            clearLoadFailure()
            load(url)
            return
        }
        let message = String(localized: "Its web content process ended unexpectedly. Reload to open it again.")
        showLoadFailure(BrowserLoadFailure(url: url, reason: BrowserLoadError.processTerminated, message: message,
                                           untrustedHost: nil, crashed: true))
    }

    /// Another page started loading or committed: the notice goes.
    func pageDidStartLoading(in webView: WKWebView) {
        guard webView === self.webView, loadFailure != nil else { return }
        clearLoadFailure()
    }

    func showLoadFailure(_ failure: BrowserLoadFailure) {
        loadFailure = failure
        loadFailureView?.removeFromSuperview()
        let view = BrowserLoadFailureView(failure: failure)
        view.onReload = { [weak self] in self?.retryFailedLoad() }
        view.onContinue = { [weak self] in self?.continueAnyway() }
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .above, relativeTo: viewportHost)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: viewportHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: viewportHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: viewportHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: viewportHost.bottomAnchor),
        ])
        loadFailureView = view
        stateDidChange()  // the address bar and the pane title show the failed URL
    }

    func clearLoadFailure() {
        guard loadFailure != nil || loadFailureView != nil else { return }
        loadFailure = nil
        loadFailureView?.removeFromSuperview()
        loadFailureView = nil
        stateDidChange()
    }

    /// Reload on the notice (and the toolbar's while it shows): loads the failed URL again.
    func retryFailedLoad() {
        guard let url = loadFailure?.url else { return clearLoadFailure() }
        load(url)
    }

    /// Continue Anyway: trust the host's certificate for this session, then load the page again.
    func continueAnyway() {
        guard let host = loadFailure?.untrustedHost else { return }
        BrowserPageDelegate.trustedHosts.insert(host)
        retryFailedLoad()
    }

    /// As `navigate(to:)` loads it.
    private func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }
}

/// Covers the page area while the page did not load: an icon, the title, the failed URL, the reason and buttons.
final class BrowserLoadFailureView: NSView {
    var onReload: (() -> Void)?
    var onContinue: (() -> Void)?
    let titleLabel: NSTextField
    let messageLabel: NSTextField
    let buttons: [NSButton]

    init(failure: BrowserLoadFailure) {
        let title = failure.crashed ? String(localized: "This Page Stopped Working")
            : (failure.untrustedHost != nil ? String(localized: "This Connection Is Not Private")
                : String(localized: "Can’t Open the Page"))
        titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: 15)
        let urlLabel = NSTextField(labelWithString: failure.url?.absoluteString ?? "")
        urlLabel.font = .systemFont(ofSize: 12)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlLabel.isSelectable = true
        messageLabel = NSTextField(wrappingLabelWithString: failure.message)
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.alignment = .center
        messageLabel.isSelectable = true
        let reload = NSButton(title: String(localized: "Reload"), target: nil, action: nil)
        reload.keyEquivalent = "\r"
        var buttons = [reload]
        if failure.untrustedHost != nil {
            buttons.append(NSButton(title: String(localized: "Continue Anyway"), target: nil, action: nil))
        }
        self.buttons = buttons
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setAccessibilityIdentifier("browser-load-error")
        reload.target = self
        reload.action = #selector(reloadClicked)
        buttons.dropFirst().first?.target = self
        buttons.dropFirst().first?.action = #selector(continueClicked)

        let icon = NSImageView(image: NSImage(systemSymbolName: failure.crashed ? "exclamationmark.arrow.circlepath"
                                              : "exclamationmark.triangle", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 28, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        let buttonRow = NSStackView(views: buttons)
        buttonRow.spacing = 8
        let stack = NSStackView(views: [icon, titleLabel, urlLabel, messageLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(16, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            urlLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Clicks reach the buttons and labels, never the page below.
    override func mouseDown(with event: NSEvent) {}

    @objc private func reloadClicked() { onReload?() }
    @objc private func continueClicked() { onContinue?() }
}

#if DEBUG
extension BrowserPane {
    /// `debug.browser`: the notice shown (title, message, buttons); `loadErrorAction` presses one of its buttons
    /// (`reload` / `continue`), as a click would.
    func debugLoadFailure(action: String?) -> JSONValue {
        guard let failure = loadFailure, let view = loadFailureView else { return .null }
        let state: JSONValue = .object([
            "url": failure.url.map { .string($0.absoluteString) } ?? .null,
            "reason": .string(failure.reason),
            "title": .string(view.titleLabel.stringValue),
            "message": .string(view.messageLabel.stringValue),
            "buttons": .array(view.buttons.map { .string($0.title) }),
            "crashed": .bool(failure.crashed),
        ])
        switch action {
        case "reload": view.buttons.first?.performClick(nil)
        case "continue": view.buttons.dropFirst().first?.performClick(nil)
        default: break
        }
        return state
    }

    /// `debug.browser`: the pid of the page's WebContent process (tests end it to check the crash handling).
    var debugWebProcessID: JSONValue {
        (webView.value(forKey: "_webProcessIdentifier") as? NSNumber).map { .number($0.doubleValue) } ?? .null
    }
}
#endif
