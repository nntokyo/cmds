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

    /// The cookies and storage of every page view (browser panes): one store for the app's run, so a sign-in made on
    /// the phone stays while the user switches panes or workspaces (a store per view lost it each time, and the pane
    /// opened on the sign-in page again). Nothing the Mac or a page leaves here outlives the app.
    @MainActor static let dataStore = WKWebsiteDataStore.nonPersistent()

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if case .html = content {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        }
        // Rendered files keep a store of their own (they never see the sign-ins of browser panes).
        configuration.websiteDataStore = { if case .url = content { return Self.dataStore } else { return .nonPersistent() } }()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
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
        // Reload: the page the view shows now (after a sign-in, not the Mac's address, which may be the sign-in page).
        if coordinator.loaded == content, case .url = content, view.url != nil {
            coordinator.reloadToken = reloadToken
            view.reload()
            return
        }
        coordinator.loaded = content
        coordinator.reloadToken = reloadToken
        coordinator.isHTML = { if case .html = content { return true } else { return false } }()
        switch content {
        case .url(let url): view.load(URLRequest(url: url))
        case .html(let html): view.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
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

        /// A link or script that opens a new window (`target=_blank`, sign-in pages): the page opens in this view (the
        /// phone has no second one); without this WebKit drops it.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if !isHTML, action.targetFrame == nil, let url = action.request.url { webView.load(URLRequest(url: url)) }
            return nil
        }
    }
}
