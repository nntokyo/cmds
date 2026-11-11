import AppKit
import WebKit
import CmdsCore

/// What a browser pane's pages may ask of the app (#235; docs/guide/workspaces-and-panes.md "Pop-ups, dialogs and
/// downloads"): new windows, JavaScript dialogs, file uploads and downloads. One per pane; the UI and navigation
/// delegate of the pane's web view, the responsive view's other frames and the pane's pop-ups.
///
/// - New windows (`BrowserNewWindow.decide`): a link to `_blank` opens a browser pane beside this one; `window.open`
///   gets a `BrowserPopupWindow` whose web view is made from the configuration WebKit passes, so `window.opener` and
///   `postMessage` work (sign-in pop-ups). A pane that is not on screen (a hidden workspace, an off-screen snapshot)
///   opens no window.
/// - Dialogs and the open panel are sheets on the window of the web view that asked, never on an off-screen
///   `RenderOnlyWindow`; without such a window, and for a responsive frame loading what another frame navigated to (the
///   same dialog would come once per frame), they get WebKit's answer for no UI (OK, false, nil). WebKit raises an
///   exception for a completion handler that is never called, so `tearDown()` answers whatever is still open.
/// - Downloads go to `BrowserDownloads`, which outlives the pane.
@MainActor
final class BrowserPageDelegate: NSObject, WKUIDelegate, WKNavigationDelegate {
    weak var pane: BrowserPane?
    private var popups: [BrowserPopupWindow] = []
    private var sheets: [PendingSheet] = []

    func attach(_ webView: WKWebView) {
        webView.uiDelegate = self
        webView.navigationDelegate = self
    }

    static func detach(_ webView: WKWebView) {
        webView.uiDelegate = nil
        webView.navigationDelegate = nil
    }

    /// The pane closes: dialogs answered, pop-ups closed.
    func tearDown() {
        for sheet in sheets { sheet.cancel() }
        sheets.removeAll()
        for popup in popups { popup.close() }
        popups.removeAll()
    }

    /// A window the user sees: not off screen for a snapshot, not hidden.
    static func isOnScreen(_ window: NSWindow?) -> Bool {
        guard let window, !(window is RenderOnlyWindow) else { return false }
        return window.isVisible
    }

    // MARK: - New windows

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let features: [NSNumber?] = [windowFeatures.width, windowFeatures.height, windowFeatures.x, windowFeatures.y,
                                     windowFeatures.menuBarVisibility, windowFeatures.statusBarVisibility,
                                     windowFeatures.toolbarsVisibility, windowFeatures.allowsResizing]
        let decision = BrowserNewWindow.decide(isLinkActivation: navigationAction.navigationType == .linkActivated,
                                               hasWindowFeatures: features.contains { $0 != nil },
                                               url: navigationAction.request.url,
                                               paneOnScreen: Self.isOnScreen(webView.window),
                                               canOpenPane: pane?.onOpenInNewPane != nil)
        switch decision {
        case .newPane(let url):
            if pane?.onOpenInNewPane?(url) != true { webView.load(navigationAction.request) }
            return nil
        case .samePane:
            webView.load(navigationAction.request)
            return nil
        case .refuse:
            return nil
        case .popup:
            return openPopup(configuration: configuration, features: windowFeatures, from: webView)
        }
    }

    private func openPopup(configuration: WKWebViewConfiguration, features: WKWindowFeatures,
                           from opener: WKWebView) -> WKWebView {
        let screen = (opener.window?.screen ?? NSScreen.main)?.visibleFrame.size ?? BrowserPopupSize.maximum
        let size = BrowserPopupSize.clamped(width: features.width?.doubleValue, height: features.height?.doubleValue,
                                            available: screen)
        // WebKit requires the configuration it passes (it links the new page to its opener).
        let child = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        child.customUserAgent = opener.customUserAgent
        child.appearance = opener.appearance
        child.allowsMagnification = true
        child.isInspectable = AppSettings.shared.browserInspectable
        attach(child)
        let popup = BrowserPopupWindow(webView: child, contentSize: size, over: opener.window)
        popup.onClose = { [weak self] popup in self?.popups.removeAll { $0 === popup } }
        popups.append(popup)
        popup.makeKeyAndOrderFront(nil)
        return child
    }

    /// `window.close()` in a pop-up.
    func webViewDidClose(_ webView: WKWebView) {
        popups.first { $0.webView === webView }?.close()
    }

    // MARK: - JavaScript dialogs

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = dialog(message: message, frame: frame)
        alert.addButton(withTitle: String(localized: "OK"))
        present(alert, for: webView) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = dialog(message: message, frame: frame)
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert, for: webView) { response in completionHandler(response == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        let alert = dialog(message: prompt, frame: frame)
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 22)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        present(alert, for: webView) { response in
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    /// The page's host as the title (pages cannot pass their text off as the app's), its text below.
    private func dialog(message: String, frame: WKFrameInfo) -> NSAlert {
        let origin = frame.securityOrigin
        let alert = NSAlert()
        if let host = BrowserDialogOrigin.label(scheme: origin.protocol, host: origin.host, port: origin.port) {
            alert.messageText = String(localized: "\(host) says:")
        } else {
            alert.messageText = String(localized: "This page says:")
        }
        alert.informativeText = message
        return alert
    }

    /// `alert` as a sheet on `webView`'s window; `answer` gets nil when nothing could be shown or the pane closed.
    private func present(_ alert: NSAlert, for webView: WKWebView,
                         answer: @escaping (NSApplication.ModalResponse?) -> Void) {
        guard let window = sheetWindow(for: webView) else { return answer(nil) }
        let pending = PendingSheet(window: window, sheet: alert.window, answer: answer)
        pending.alert = alert
        sheets.append(pending)
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                pending.finish(response)
                self?.sheets.removeAll { $0 === pending }
            }
        }
    }

    private func sheetWindow(for webView: WKWebView) -> NSWindow? {
        guard Self.isOnScreen(webView.window), pane?.responsiveView?.isFollowing(webView) != true else { return nil }
        return webView.window
    }

    // MARK: - File uploads

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        guard let window = sheetWindow(for: webView) else { return completionHandler(nil) }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.prompt = String(localized: "Choose")
        if let host = BrowserDialogOrigin.label(scheme: frame.securityOrigin.protocol, host: frame.securityOrigin.host,
                                                port: frame.securityOrigin.port) {
            panel.message = String(localized: "Choose files to upload to \(host)")
        }
        let pending = PendingSheet(window: window, sheet: panel) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
        pending.chooseFiles = { completionHandler($0) }
        sheets.append(pending)
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                pending.finish(response)
                self?.sheets.removeAll { $0 === pending }
            }
        }
    }

    // MARK: - Downloads

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        let save = !navigationResponse.canShowMIMEType || BrowserDownloadName.isAttachment(contentDisposition: disposition)
        decisionHandler(save ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        BrowserDownloads.shared.start(download, for: pane)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        BrowserDownloads.shared.start(download, for: pane)
    }
}

/// A sheet a page waits for. `finish` answers once; `cancel` (the pane closed) also takes the sheet down.
@MainActor
private final class PendingSheet {
    private weak var window: NSWindow?
    private weak var sheet: NSWindow?
    private var answer: ((NSApplication.ModalResponse?) -> Void)?
    /// The JavaScript dialog shown (nil: the open panel).
    var alert: NSAlert?
    /// The open panel's answer with given files (`debug.browser`).
    var chooseFiles: (([URL]) -> Void)?

    init(window: NSWindow, sheet: NSWindow, answer: @escaping (NSApplication.ModalResponse?) -> Void) {
        self.window = window
        self.sheet = sheet
        self.answer = answer
    }

    func finish(_ response: NSApplication.ModalResponse?) {
        guard let answer else { return }
        self.answer = nil
        answer(response)
    }

    func cancel() {
        end(.cancel)
        finish(nil)
    }

    /// The open panel's answer with `files` instead of what the panel has (once, as `finish`).
    func answerWithFiles(_ files: [URL]) {
        guard answer != nil, let chooseFiles else { return }
        answer = nil
        chooseFiles(files)
    }

    /// Takes the sheet down as its button `response` would.
    func end(_ response: NSApplication.ModalResponse) {
        if let window, let sheet { window.endSheet(sheet, returnCode: response) }
    }
}

#if DEBUG
extension BrowserPageDelegate {
    /// `debug.browser`: the pop-ups and the sheet a page waits for; `answer` (`ok` / `cancel`) answers that sheet as
    /// its buttons do, with `text` typed into a prompt or, for the open panel, the path of the file chosen.
    func debugState(answer: String?, text: String?) -> [String: JSONValue] {
        var result: [String: JSONValue] = [
            "popups": .array(popups.map { popup in
                .object([
                    "title": .string(popup.title),
                    "subtitle": .string(popup.subtitle),
                    "url": popup.webView.url.map { .string($0.absoluteString) } ?? .null,
                    "size": .array([popup.webView.frame.width, popup.webView.frame.height].map { .number(Double($0)) }),
                    "key": .bool(popup.isKeyWindow),
                ])
            }),
        ]
        guard let sheet = sheets.first else { return result }
        if let alert = sheet.alert {
            result["sheet"] = .object([
                "title": .string(alert.messageText),
                "message": .string(alert.informativeText),
                "buttons": .array(alert.buttons.map { .string($0.title) }),
                "field": (alert.accessoryView as? NSTextField).map { .string($0.stringValue) } ?? .null,
            ])
        } else {
            result["sheet"] = .object(["openPanel": .bool(true)])
        }
        guard let answer else { return result }
        if let alert = sheet.alert {
            if let text, let field = alert.accessoryView as? NSTextField { field.stringValue = text }
            let cancel: NSApplication.ModalResponse = alert.buttons.count > 1 ? .alertSecondButtonReturn : .alertFirstButtonReturn
            sheet.end(answer == "ok" ? .alertFirstButtonReturn : cancel)
        } else if answer == "ok", let text {
            sheet.answerWithFiles([URL(fileURLWithPath: text)])
            sheet.end(.cancel)
        } else {
            sheet.end(.cancel)
        }
        result["answered"] = .string(answer)
        return result
    }
}
#endif
