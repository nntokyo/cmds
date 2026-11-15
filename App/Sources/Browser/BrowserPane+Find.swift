import AppKit
import WebKit
import CmdsCore

// Find in page (#338; docs/guide/workspaces-and-panes.md "Browser panes"): ⌘F opens the terminal's find bar
// (`TerminalFindBar`, without the regular-expression toggle) over the page's top-right corner; WebKit's find selects
// and scrolls to the match. Return / ⌘G: next (down the page), ⇧Return / ⇧⌘G: previous, Esc closes. Searches wrap.
// `browser.find` (`cmds browser find`) runs the same search without the bar.

extension BrowserPane {
    var isFindOpen: Bool { findBar != nil }

    /// Shows the find bar (or focuses it again) with its text selected.
    func openFind() {
        if findBar == nil {
            let bar = TerminalFindBar()
            bar.regexButton.isHidden = true
            bar.setAccessibilityIdentifier("browser-find-bar")
            bar.field.setAccessibilityIdentifier("browser-find-field")
            bar.onChange = { [weak self] in self?.findBarChanged() }
            bar.onNavigate = { [weak self] next in self?.findBarNavigate(forward: next) }
            bar.onClose = { [weak self] in self?.closeFind() }
            bar.onFocus = { [weak self] in self?.onFocus?() }
            bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bar)  // above the page, the responsive view and a load error's notice
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(greaterThanOrEqualTo: viewportHost.leadingAnchor, constant: 8),
                bar.trailingAnchor.constraint(equalTo: viewportHost.trailingAnchor, constant: -8),
                bar.topAnchor.constraint(equalTo: viewportHost.topAnchor, constant: 8),
            ])
            findBar = bar
        }
        guard let bar = findBar else { return }
        window?.makeFirstResponder(bar.field)
        bar.field.currentEditor()?.selectAll(nil)
    }

    /// Esc or the close button: the page takes the keyboard again; the match stays selected.
    func closeFind() {
        guard let bar = findBar else { return }
        let hadKeyboard = bar.fieldHasKeyboard
        bar.removeFromSuperview()
        findBar = nil
        if hadKeyboard { window?.makeFirstResponder(webView) }
    }

    /// ⌘G / ⇧⌘G and the bar's Return: the next / previous match of the bar's text.
    func findBarNavigate(forward: Bool) {
        guard let bar = findBar, !bar.field.stringValue.isEmpty else { return }
        let text = bar.field.stringValue
        Task { [weak self] in
            guard let self else { return }
            let found = await self.find(text, backwards: !forward, caseSensitive: bar.matchCase)
            self.showFindResult(found, for: text)
        }
    }

    /// The text or Match Case changed: the first match from where the current one starts.
    private func findBarChanged() {
        guard let bar = findBar else { return }
        let text = bar.field.stringValue
        guard !text.isEmpty else { return showFindResult(true, for: text) }
        Task { [weak self] in
            guard let self else { return }
            // Typing more of a word keeps the match it is on rather than moving past it.
            _ = try? await self.webView.callAsyncJavaScript(
                "const s = getSelection(); if (s && s.rangeCount) s.collapseToStart();",
                arguments: [:], in: nil, contentWorld: .defaultClient)
            let found = await self.find(text, backwards: false, caseSensitive: bar.matchCase)
            guard self.findBar?.field.stringValue == text else { return }  // typed on meanwhile
            self.showFindResult(found, for: text)
        }
    }

    private func showFindResult(_ found: Bool, for text: String) {
        guard let bar = findBar else { return }
        let notFound = !found && !text.isEmpty
        bar.countLabel.stringValue = notFound ? String(localized: "Not found") : ""
        bar.setInvalid(notFound)
    }

    /// WebKit's find from the current selection: selects and scrolls to the next (or previous) match, wrapping.
    func find(_ text: String, backwards: Bool = false, caseSensitive: Bool = false) async -> Bool {
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = caseSensitive
        configuration.wraps = true
        return await withCheckedContinuation { continuation in
            webView.find(text, configuration: configuration) { result in continuation.resume(returning: result.matchFound) }
        }
    }
}

#if DEBUG
extension BrowserPane {
    /// `debug.browser`: `findAction` `open` (with `findText` typed into the bar), `next`, `previous` or `close`, as ⌘F,
    /// typing, ⌘G, ⇧⌘G and Esc do.
    func debugFindAction(_ action: String?, text: String?) {
        switch action {
        case "open":
            openFind()
            if let text, let bar = findBar {
                bar.field.stringValue = text
                findBarChanged()
            }
        case "next": findBarNavigate(forward: true)
        case "previous": findBarNavigate(forward: false)
        case "close": closeFind()
        default: break
        }
    }

    /// `debug.browser`: the find bar's text and what it shows (nil: closed).
    var debugFind: JSONValue {
        guard let bar = findBar else { return .null }
        return .object(["text": .string(bar.field.stringValue), "status": .string(bar.countLabel.stringValue),
                        "keyboard": .bool(bar.fieldHasKeyboard)])
    }
}
#endif
