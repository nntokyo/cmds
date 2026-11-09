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

    func receiveConsole(_ messages: [[String: Any]]) {
        for message in messages {
            if let entry = ConsoleEntry(message: message) { consoleBuffer.append(entry) }
        }
    }

    /// `browser.console`.
    func console(level: ConsoleEntry.Level?, since: Int?, limit: Int?, clear: Bool) -> JSONValue {
        let result = consoleBuffer.json(level: level, since: since, limit: limit)
        if clear { consoleBuffer.clear() }
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

    /// `browser.wait_for`: `{found: true, ref, elapsed}`, or a 408 error after `timeout` seconds.
    func waitFor(selector: String?, text: String?, timeout: Double) async throws -> JSONValue {
        let result = try await runPageScript(PageScripts.waitFor, [
            "selector": selector ?? NSNull(), "text": text ?? NSNull(), "timeout": timeout * 1000,
        ])
        guard result["found"]?.boolValue == true else {
            let what = selector.map { "selector \($0)" } ?? "text \"\(text ?? "")\""
            throw RPCError(code: 408, message: "timed out after \(Self.seconds(timeout)) s waiting for \(what)")
        }
        return result
    }

    private static func arguments(_ target: ElementTarget) -> [String: Any] {
        switch target {
        case .ref(let ref): ["ref": ref, "selector": NSNull()]
        case .selector(let selector): ["ref": NSNull(), "selector": selector]
        }
    }

    private static func seconds(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// Runs a CmdsCore page script as an async function body in cmds' content world and returns its JSON value. Errors
    /// it throws become clean API errors (404 for a missing element or ref, else invalid params).
    private func runPageScript(_ body: String, _ arguments: [String: Any]) async throws -> JSONValue {
        // `value` is an argument of fill, so the result has another name.
        let wrapped = "const __cmdsResult = await (async () => {\n\(body)\n})();\n"
            + "return __cmdsResult === undefined ? null : JSON.stringify(__cmdsResult);"
        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(wrapped, arguments: arguments, in: nil, contentWorld: .defaultClient)
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
