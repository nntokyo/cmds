import AppKit

/// The notice at the bottom of a browser pane: a download (BrowserDownloads.swift) or a passkey request (#336). Same
/// look as the agent banners; never takes the keyboard.
final class BrowserNoticeView: NSVisualEffectView {
    enum State {
        case downloading(name: String)
        case finished(name: String, file: URL)
        case failed(name: String, reason: String)
        /// The page asked for a passkey (#336): `page` opens in Safari.
        case passkey(host: String, page: URL)
        /// Point at Element: the report was typed into the agent's terminal named `target`.
        case pointSent(target: String)
        /// Point at Element: no terminal could take it; the prompt is on the clipboard.
        case pointCopied(reason: String)
        /// Point at Element: the agent `target` works on the report.
        case pointWorking(target: String)
        /// Point at Element: the agent asks a question while on the report.
        case pointAsking(target: String)
        /// Point at Element: the agent finished its turn; `summary` is the first line of its reply when known.
        case pointDone(target: String, summary: String?)
        /// `browser.point`: an agent waits for the user to click an element; `prompt` is what it asks for.
        case agentPointing(prompt: String?)
    }

    /// Point at Element notices: "Show Terminal" focuses the agent's terminal.
    var onShowTerminal: (() -> Void)?

    var onCancel: (() -> Void)?
    var onDismiss: (() -> Void)?
    let notice: State

    init(state: State) {
        self.notice = state
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        setAccessibilityIdentifier("cmds.browserDownloadBanner")

        let symbol: String
        let tint: NSColor
        let text: String
        var buttons: [NSButton] = []
        switch state {
        case .downloading(let name):
            symbol = "arrow.down.circle"
            tint = .controlAccentColor
            text = String(localized: "Downloading “\(name)”…")
            buttons.append(button(String(localized: "Cancel"), #selector(cancelClicked)))
        case .finished(let name, _):
            symbol = "checkmark.circle"
            tint = .systemGreen
            text = String(localized: "Downloaded “\(name)” to Downloads")
            buttons.append(button(String(localized: "Show in Finder"), #selector(showClicked), primary: true))
            buttons.append(button(String(localized: "Dismiss"), #selector(dismissClicked)))
        case .failed(let name, let reason):
            symbol = "exclamationmark.triangle"
            tint = .systemOrange
            text = name.isEmpty ? String(localized: "Download failed: \(reason)")
                : String(localized: "Download of “\(name)” failed: \(reason)")
            buttons.append(button(String(localized: "Dismiss"), #selector(dismissClicked)))
        case .passkey(let host, _):
            symbol = "person.badge.key"
            tint = .systemOrange
            text = String(localized: "\(host) asks for a passkey. Browser panes cannot use passkeys yet.",
                          comment: "browser pane notice; host is the site, e.g. github.com")
            buttons.append(button(String(localized: "Open in Safari"), #selector(openInSafariClicked), primary: true))
            buttons.append(button(String(localized: "Dismiss"), #selector(dismissClicked)))
        case .pointSent(let target):
            symbol = "paperplane"
            tint = .systemGreen
            text = String(localized: "Sent to \(target)", comment: "Point at Element notice; the argument is the terminal's name")
            buttons.append(button(String(localized: "Dismiss"), #selector(dismissClicked)))
        case .pointCopied(let reason):
            symbol = "doc.on.clipboard"
            tint = .systemOrange
            text = String(localized: "Copied the report: \(reason)",
                          comment: "Point at Element notice when no agent terminal took the report")
            buttons.append(button(String(localized: "Dismiss"), #selector(dismissClicked)))
        case .pointWorking(let target):
            symbol = "hammer"
            tint = .controlAccentColor
            text = String(localized: "\(target) is working on it…",
                          comment: "Point at Element notice while the agent works on the report; argument: the terminal's name")
            buttons.append(button(String(localized: "Show Terminal"), #selector(showTerminalClicked)))
            buttons.append(button(String(localized: "Dismiss"), #selector(dismissClicked)))
        case .pointAsking(let target):
            symbol = "questionmark.bubble"
            tint = .systemOrange
            text = String(localized: "\(target) asks you something",
                          comment: "Point at Element notice when the agent needs an answer; argument: the terminal's name")
            buttons.append(button(String(localized: "Show Terminal"), #selector(showTerminalClicked), primary: true))
            buttons.append(button(String(localized: "Dismiss"), #selector(dismissClicked)))
        case .pointDone(let target, let summary):
            symbol = "checkmark.circle"
            tint = .systemGreen
            text = summary.map { String(localized: "\(target) finished: \($0)",
                                        comment: "Point at Element notice; arguments: the terminal's name, the first line of its reply") }
                ?? String(localized: "\(target) finished", comment: "Point at Element notice; argument: the terminal's name")
            buttons.append(button(String(localized: "Show Terminal"), #selector(showTerminalClicked)))
            buttons.append(button(String(localized: "Dismiss"), #selector(dismissClicked)))
        case .agentPointing(let prompt):
            symbol = "scope"
            tint = .systemRed
            text = prompt.map { String(localized: "The agent asks: \($0) — click the element",
                                       comment: "browser.point notice; argument: the agent's request") }
                ?? String(localized: "The agent asks you to click an element",
                          comment: "browser.point notice without a request text")
            buttons.append(button(String(localized: "Cancel"), #selector(cancelClicked)))
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = tint
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolTip = text

        let stack = NSStackView(views: [icon, label] + buttons)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    private func button(_ title: String, _ action: Selector, primary: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.refusesFirstResponder = true
        if primary { button.bezelColor = .controlAccentColor }
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    @objc private func cancelClicked() { onCancel?() }

    @objc private func showTerminalClicked() {
        onShowTerminal?()
        onDismiss?()
    }
    @objc private func dismissClicked() { onDismiss?() }

    @objc private func openInSafariClicked() {
        if case .passkey(_, let page) = notice { Self.openInSafari(page) }
        onDismiss?()
    }

    /// Safari, else the default browser when it is not cmds itself (passkeys work there).
    static func openInSafari(_ url: URL) {
        let workspace = NSWorkspace.shared
        if let safari = workspace.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            workspace.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
        } else if let browser = workspace.urlForApplication(toOpen: url),
                  Bundle(url: browser)?.bundleIdentifier != Bundle.main.bundleIdentifier {
            workspace.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc private func showClicked() {
        if case .finished(_, let file) = notice { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        onDismiss?()
    }
}
