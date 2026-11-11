import AppKit
import WebKit
import CmdsCore

/// A page's pop-up (`window.open`, #235): a small window with the web view WebKit asked for, centred over the window it
/// came from. The title is the page's title, the subtitle its host (what the page cannot fake). It belongs to the pane
/// that opened it (`BrowserPageDelegate`): closed with it, by `window.close()` in the page, or by the user (⌘W).
/// Closing frees the web view, so the opener sees `closed`.
@MainActor
final class BrowserPopupWindow: NSWindow, NSWindowDelegate {
    let webView: WKWebView
    var onClose: ((BrowserPopupWindow) -> Void)?
    private var observations: [NSKeyValueObservation] = []
    /// The smallest the user can make the page (the page's own request is `BrowserPopupSize`).
    static let minimumContentSize = NSSize(width: 200, height: 150)
    /// The most a pop-up sits above the middle of its parent window.
    static let maximumRaise: CGFloat = 80

    init(webView: WKWebView, contentSize: CGSize, over parent: NSWindow?) {
        self.webView = webView
        super.init(contentRect: NSRect(origin: .zero, size: contentSize),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isRestorable = false
        tabbingMode = .disallowed
        // Over the main window also in full screen.
        collectionBehavior = [.fullScreenAuxiliary]
        contentMinSize = Self.minimumContentSize
        contentView = webView
        delegate = self
        setAccessibilityIdentifier("cmds.browserPopup")
        place(over: parent)
        observations = [
            webView.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateTitle() } },
            webView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateTitle() } },
        ]
        updateTitle()
    }

    private func place(over parent: NSWindow?) {
        guard let parent else { return center() }
        let size = frame.size
        var origin = NSPoint(x: parent.frame.midX - size.width / 2, y: parent.frame.midY - size.height / 2)
        // A little higher than the middle, as alerts sit.
        origin.y += min(parent.frame.height / 8, Self.maximumRaise)
        setFrame(constrainFrameRect(NSRect(origin: origin, size: size), to: parent.screen), display: false)
    }

    private func updateTitle() {
        let url = webView.url
        let host = url?.host ?? ""
        let pageTitle = webView.title ?? ""
        title = pageTitle.isEmpty ? (host.isEmpty ? String(localized: "Pop-up") : host) : pageTitle
        subtitle = url.flatMap { BrowserDialogOrigin.label(scheme: $0.scheme ?? "", host: $0.host ?? "",
                                                           port: $0.port ?? 0) } ?? host
    }

    /// ⌘W closes the pop-up, not the focused pane (the main menu's Close Pane has an explicit target).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func windowWillClose(_ notification: Notification) {
        observations.removeAll()
        webView.stopLoading()
        BrowserPageDelegate.detach(webView)
        let onClose = onClose
        self.onClose = nil
        // Frees the web view once nothing holds it: the opener's `popup.closed` becomes true.
        contentView = nil
        onClose?(self)
    }
}
