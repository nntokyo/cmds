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

/// What the phone can load of a browser pane's URL. The Mac's own pages (localhost, file://) are not reachable from
/// the phone.
enum BrowserPaneURL {
    enum Result: Equatable {
        case load(URL)
        /// Only on the Mac (localhost, a file) or not a web address.
        case macOnly
    }

    static func resolve(_ raw: String?) -> Result {
        guard let raw, let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host?.lowercased() else { return .macOnly }
        if host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1"
            || host == "[::1]" || host == "0.0.0.0" {
            return .macOnly
        }
        return .load(url)
    }
}

/// A Mac browser pane on the phone: the same page in a web view, loaded by the phone itself (its own network and
/// cookies, not the Mac's). Pages served by the Mac (localhost) cannot be reached from the phone.
struct BrowserPaneView: View {
    let pane: PaneInfo
    @State private var reloadToken = 0
    @State private var loading = false

    private var title: String { pane.title.isEmpty ? String(localized: "Browser") : DefaultTitle.localized(pane.title) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "globe").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let url = pane.url {
                        Text(url).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                if case .load(let url) = BrowserPaneURL.resolve(pane.url) {
                    Button { reloadToken += 1 } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Reload")
                    Link(destination: url) { Image(systemName: "safari") }
                        .accessibilityLabel("Open in Safari")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            switch BrowserPaneURL.resolve(pane.url) {
            case .load(let url):
                WebPageView(content: .url(url), reloadToken: reloadToken) { loading = $0 }
                    .overlay { if loading { ProgressView().controlSize(.large) } }
            case .macOnly:
                ContentUnavailableView {
                    Label(title, systemImage: "globe")
                } description: {
                    Text("This page is served by the Mac (localhost or a file) and cannot be opened on the phone.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
