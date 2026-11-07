import CmdsCore
import SwiftUI
import UIKit
import WebKit

/// A web page on the phone: a browser pane's URL, or the HTML a preview pane renders (Markdown, diffs).
struct WebPageView: UIViewRepresentable {
    enum Content: Equatable {
        /// A page from the network (browser panes). JavaScript on, links stay in the view.
        case url(URL)
        /// HTML made on the phone from a fetched file (preview). No JavaScript; links open in Safari.
        case html(String)
    }

    let content: Content
    /// Bumped to load the page again (Reload).
    var reloadToken = 0
    /// Told when a page starts and stops loading (the browser pane shows a spinner meanwhile).
    var onLoading: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if case .html = content {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        }
        // Nothing the Mac or a page leaves here outlives the app.
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "webPage"
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onLoading = onLoading
        guard coordinator.loaded != content || coordinator.reloadToken != reloadToken else { return }
        coordinator.loaded = content
        coordinator.reloadToken = reloadToken
        coordinator.isHTML = { if case .html = content { return true } else { return false } }()
        switch content {
        case .url(let url): view.load(URLRequest(url: url))
        case .html(let html): view.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: Content?
        var reloadToken = 0
        var isHTML = false
        var onLoading: (Bool) -> Void = { _ in }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { onLoading(true) }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onLoading(false) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onLoading(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) { onLoading(false) }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            // Rendered files: the page itself loads, a tapped link goes to Safari (never replaces the preview).
            if isHTML, action.navigationType == .linkActivated, let url = action.request.url {
                if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    UIApplication.shared.open(url)
                }
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }
    }
}
