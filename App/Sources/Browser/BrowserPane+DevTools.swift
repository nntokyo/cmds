import AppKit
import WebKit
import CmdsCore

// DevTools for agents (#167; docs/guide/ai-agents.md "Browser DevTools"): the console buffer, the page tree with refs,
// click / fill / wait_for, and Safari's Web Inspector. Scripts come from CmdsCore (BrowserDevTools.swift).
//
// Pages with a strict Content Security Policy: user scripts and `callAsyncJavaScript` are compiled by WebKit, not by
// the page, so its CSP does not block them (the same reason `browser.eval` falls back to them, #88).
extension BrowserPane {
    func startDevTools() {
        let controller = webView.configuration.userContentController
        controller.add(ConsoleMessageHandler(self), contentWorld: .defaultClient, name: ConsoleCapture.handlerName)
        controller.addUserScript(WKUserScript(source: ConsoleCapture.listener(eventName: consoleEventName),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        controller.addUserScript(WKUserScript(source: ConsoleCapture.hook(eventName: consoleEventName),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.add(PasskeyMessageHandler(self), contentWorld: .defaultClient, name: PasskeyRequestCapture.handlerName)
        controller.addUserScript(WKUserScript(source: PasskeyRequestCapture.listener(eventName: passkeyEventName),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        controller.addUserScript(WKUserScript(source: PasskeyRequestCapture.hook(eventName: passkeyEventName),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        applyInspectable()
        NotificationCenter.default.addObserver(self, selector: #selector(inspectableSettingChanged),
                                               name: AppSettings.didChange, object: nil)
    }

    @objc private func inspectableSettingChanged() { applyInspectable() }

    func applyInspectable() {
        let on = AppSettings.shared.browserInspectable
        if webView.isInspectable != on { webView.isInspectable = on }
        for frame in responsiveView?.webViews.dropFirst() ?? [] where frame.isInspectable != on { frame.isInspectable = on }
    }

    /// The page asked for a passkey (#336): browser panes cannot answer it until #162; the notice offers Safari.
    func pageAskedForPasskey() {
        guard let page = webView.url, let host = page.host(), !host.isEmpty else { return }
        showNotice(.passkey(host: host, page: page))
    }

    func receiveConsole(_ messages: [[String: Any]]) {
        for message in messages {
            if let entry = ConsoleEntry(message: message) { consoleBuffer.append(entry) }
        }
        consoleDrawer?.setNeedsRefresh()
    }

    /// `browser.console`.
    func console(level: ConsoleEntry.Level?, since: Int?, limit: Int?, clear: Bool) -> JSONValue {
        let result = consoleBuffer.json(level: level, since: since, limit: limit)
        if clear {
            consoleBuffer.clear()
            consoleDrawer?.refresh()
        }
        return result
    }

    // MARK: - Page tree and actions

    /// `browser.snapshot_tree`: `{nodes, text, title, url, truncated, count}`.
    func pageTree(selector: String?, maxNodes: Int) async throws -> JSONValue {
        let result = try await runPageScript(PageScripts.tree, ["selector": selector ?? NSNull(), "maxNodes": maxNodes])
        guard case .object(var object) = result else { throw RPCError(code: 500, message: "the page gave no tree") }
        let nodes = (try? object["nodes"]?.decode([PageNode].self)) ?? []
        object["text"] = .string(PageNode.text(nodes))
        object["count"] = .number(Double(PageNode.count(nodes)))
        return .object(object)
    }

    /// `browser.click`.
    func click(_ target: ElementTarget) async throws -> JSONValue {
        try await runPageScript(PageScripts.click, Self.arguments(target))
    }

    /// `browser.fill`.
    func fill(_ target: ElementTarget, value: String) async throws -> JSONValue {
        var arguments = Self.arguments(target)
        arguments["value"] = value
        return try await runPageScript(PageScripts.fill, arguments)
    }

    /// `browser.wait_for`: `{found: true, ref, elapsed}`, or a 408 error after `timeout` seconds (0: checks once).
    /// The page is asked in short rounds with a deadline of their own: a round lost with its document (the page
    /// navigated) is given up and the next one waits on the new page, so the reply always comes in time (#338).
    func waitFor(selector: String?, text: String?, timeout: Double) async throws -> JSONValue {
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        repeat {
            let round = min(Self.waitRound, max(0, deadline.timeIntervalSinceNow))
            let arguments: [String: Any] = ["selector": selector ?? NSNull(), "text": text ?? NSNull(),
                                            "timeout": round * 1000]
            do {
                let result = try await runPageScript(PageScripts.waitFor, arguments,
                                                     until: Date(timeIntervalSinceNow: round + Self.waitRoundGrace))
                if result["found"]?.boolValue == true, case .object(var object) = result {
                    object["elapsed"] = .number((Date().timeIntervalSince(started) * 1000).rounded())
                    return .object(object)
                }
            } catch is PageScriptTimeout {
                // Lost with its document, or a page busy for a while: the next round asks again.
            }
        } while deadline.timeIntervalSinceNow > 0
        let what = selector.map { "selector \($0)" } ?? "text \"\(text ?? "")\""
        throw RPCError(code: 408, message: "timed out after \(BrowserEval.format(timeout)) s waiting for \(what)")
    }

    /// How long one round of `waitFor` polls in the page.
    static let waitRound: TimeInterval = 1
    /// How much longer than its round the page has to answer before the round counts as lost.
    static let waitRoundGrace: TimeInterval = 0.5

    private static func arguments(_ target: ElementTarget) -> [String: Any] {
        switch target {
        case .ref(let ref): ["ref": ref, "selector": NSNull()]
        case .selector(let selector): ["ref": NSNull(), "selector": selector]
        }
    }

    /// Runs a CmdsCore page script as an async function body in cmds' content world and returns its JSON value. Errors
    /// it throws become clean API errors (404 for a missing element or ref, else invalid params). Without `deadline`,
    /// a page that has not answered after `BrowserEval.defaultTimeout` gets a 408 error, and a stuck one is reloaded
    /// (`scriptTimedOut`); with one, `PageScriptTimeout` is thrown.
    func runPageScript(_ body: String, _ arguments: [String: Any],
                               until deadline: Date? = nil) async throws -> JSONValue {
        // `value` is an argument of fill, so the result has another name.
        let wrapped = "const __cmdsResult = await (async () => {\n\(body)\n})();\n"
            + "return __cmdsResult === undefined ? null : JSON.stringify(__cmdsResult);"
        let raw: Any?
        do {
            let until = deadline ?? Date(timeIntervalSinceNow: BrowserEval.defaultTimeout)
            raw = try await webView.callScript(wrapped, arguments: arguments, in: .defaultClient, until: until)
        } catch is PageScriptTimeout {
            if deadline != nil { throw PageScriptTimeout() }
            throw await scriptTimedOut(after: BrowserEval.defaultTimeout)
        } catch let error as NSError {
            guard let message = error.userInfo[Self.javaScriptExceptionMessageKey] as? String else { throw error }
            let text = message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message
            if text.hasPrefix("no element") || text.contains(" is gone") { throw RPCError.notFound(text) }
            throw RPCError.invalidParams(text)
        }
        guard let json = raw as? String, let data = json.data(using: .utf8) else { return .null }
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }
}

/// Receives the console listener's batches without the content controller keeping the pane alive.
private final class ConsoleMessageHandler: NSObject, WKScriptMessageHandler {
    weak var pane: BrowserPane?

    init(_ pane: BrowserPane) { self.pane = pane }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let batch = message.body as? [[String: Any]] else { return }
        MainActor.assumeIsolated { pane?.receiveConsole(batch) }
    }
}

/// A passkey request of the page (#336): the pane shows its notice.
private final class PasskeyMessageHandler: NSObject, WKScriptMessageHandler {
    weak var pane: BrowserPane?

    init(_ pane: BrowserPane) { self.pane = pane }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        MainActor.assumeIsolated { pane?.pageAskedForPasskey() }
    }
}
