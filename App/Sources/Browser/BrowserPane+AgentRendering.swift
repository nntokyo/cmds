import AppKit
import ObjectiveC
import WebKit

/// While an agent works on a browser pane (`readyBrowser`: eval, click, fill, wait_for, the page tree, snapshots; and
/// navigate), the page keeps rendering although the pane is not on screen. Otherwise WebKit treats a page in a covered
/// window, a background workspace or a sleeping Mac's display as hidden: `document.visibilityState` is "hidden",
/// `requestAnimationFrame` stops and timers slow down, and pages such as X render nothing, so posting failed and agents
/// switched the shown workspace to get it drawn. For `AgentRendering.linger` after the last such call:
/// - the web view ignores its window being covered (WebKit's `_setWindowOcclusionDetectionEnabled:`, used only when
///   WebKit has it, like `_webProcessIdentifier`), and
/// - a pane in no window (its workspace not shown) is hosted in an off-screen window (`OffscreenRenderHost`).
/// Then WebKit's normal throttling returns, so panes nobody works on cost nothing.
@MainActor
final class AgentRendering {
    static let linger: TimeInterval = 20

    private weak var webView: WKWebView?
    private var host: OffscreenRenderHost?
    private var endTimer: Timer?
    private(set) var until: Date?

    var isActive: Bool { until.map { Date() < $0 } ?? false }

    /// Keeps `webView` rendering for `linger` from now. Returns true when it was put into an off-screen window just now
    /// (give it a moment to paint).
    @discardableResult
    func begin(_ webView: WKWebView) -> Bool {
        if self.webView !== webView { end() }
        self.webView = webView
        if until == nil { Self.setOcclusionDetection(webView, enabled: false) }
        var hosted = false
        if host == nil, webView.window == nil, let new = OffscreenRenderHost(hosting: webView) {
            host = new
            hosted = true
        }
        until = Date().addingTimeInterval(Self.linger)
        endTimer?.invalidate()
        endTimer = Timer.scheduledTimer(withTimeInterval: Self.linger, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
        return hosted
    }

    func end() {
        endTimer?.invalidate()
        endTimer = nil
        host?.release()
        host = nil
        if until != nil, let webView { Self.setOcclusionDetection(webView, enabled: true) }
        until = nil
    }

    /// WebKit's own switch; nothing happens when this WebKit does not have it.
    static func setOcclusionDetection(_ webView: WKWebView, enabled: Bool) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: selector), let method = class_getInstanceMethod(type(of: webView), selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(webView, selector, enabled)
        // WebKit reads it when the window's state changes: have it look again now.
        if webView.window != nil { webView.viewDidMoveToWindow() }
    }
}

extension BrowserPane {
    /// An agent works on this pane now (see `AgentRendering`). Waits a moment when the page was just put into an
    /// off-screen window, so it has painted before the agent looks.
    func keepRenderingForAgent() async {
        if agentRendering.begin(webView) { try? await Task.sleep(for: OffscreenRenderHost.paintDelay) }
    }
}
