import AppKit
import WebKit
import CmdsCore

// Point at Element (docs/guide/workspaces-and-panes.md "Point at an element"; scripts and the prompt in CmdsCore,
// ElementPoint.swift): the toolbar's scope button or View › Developer › Point at Element (⇧⌘C) outlines the element
// under the pointer; a click picks it (the page never gets that click) and the composer at the bottom of the pane asks
// what is wrong. Return sends the comment, the element's facts, where its code is and a screenshot with it outlined to
// the coding agent in the terminal (`AppController.deliverElementPoint`). Esc, the button again or another page gives up.

/// A report for the agent: what the user wrote about the element.
struct ElementPointReport {
    var element: PointedElement
    var comment: String
    /// PNG of the page with the element outlined (nil: the snapshot failed).
    var screenshot: Data?
    var url: String?
    var title: String?
}

/// Where a report went.
enum ElementPointDelivery {
    /// Typed into the terminal named so.
    case sent(to: String)
    /// No terminal could take it: the prompt is on the clipboard; `reason` says why.
    case copied(reason: String)
}

extension BrowserPane {
    static let pointTitle = String(localized: "Point at Element",
                                   comment: "Browser toolbar and View › Developer: pick an element of the page and tell the agent what is wrong with it")

    var isPointing: Bool { pointToken != nil }

    @objc func pointButtonClicked(_ sender: NSButton) { togglePointing() }

    func togglePointing() {
        if isPointing { endPointing() } else { startPointing() }
    }

    /// Lets the user pick an element (nothing for a page that is not a web page, or with the responsive view on: its
    /// frames are separate pages).
    func startPointing() {
        guard responsiveView == nil, loadFailure == nil, pendingURL == nil, Self.isWebPage(webView.url) else {
            return NSSound.beep()
        }
        let token = UUID().uuidString
        pointToken = token
        pointURL = webView.url
        updatePointButton()
        onFocus?()
        window?.makeFirstResponder(webView)  // Esc in the page gives up
        Task { @MainActor [weak self] in
            guard let self else { return }
            let picked = try? await self.runPageScript(ElementPoint.pickScript, ["token": token],
                                                       until: Date(timeIntervalSinceNow: ElementPoint.pickTimeout))
            guard self.pointToken == token else { return }  // given up or started again meanwhile
            guard let picked, var element = try? picked.decode(PointedElement.self) else { return self.endPointing() }
            if let info = try? await self.runPageScript(ElementPoint.sourceScript, ["token": token],
                                                        until: Date(timeIntervalSinceNow: 3), in: .page) {
                element.merge(sourceInfo: info)
            }
            guard self.pointToken == token else { return }
            self.showPointComposer(for: element)
        }
    }

    /// Gives up: removes the outline and the composer (the page keeps the keyboard if the composer had it).
    func endPointing() {
        guard pointToken != nil else { return }
        pointToken = nil
        pointURL = nil
        pointedElement = nil
        if let composer = pointComposer {
            let hadKeyboard = (window?.firstResponder as? NSView)?.isDescendant(of: composer) == true
            composer.removeFromSuperview()
            pointComposer = nil
            if hadKeyboard { window?.makeFirstResponder(webView) }
        }
        updatePointButton()
        Task { [weak self] in
            _ = try? await self?.runPageScript(ElementPoint.clearScript, [:], until: Date(timeIntervalSinceNow: 2))
        }
    }

    func updatePointButton() {
        pointButton.contentTintColor = isPointing ? .controlAccentColor : nil
    }

    private func showPointComposer(for element: PointedElement) {
        pointedElement = element
        pointComposer?.removeFromSuperview()
        let composer = ElementComposerBar(element: element.summary, target: pointTargetName?())
        composer.onSend = { [weak self] text in self?.sendPoint(text) }
        composer.onCancel = { [weak self] in self?.endPointing() }
        composer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(composer)  // above the page: never in its screenshot
        let inset = Self.noticeInset
        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: viewportHost.leadingAnchor, constant: inset),
            composer.trailingAnchor.constraint(equalTo: viewportHost.trailingAnchor, constant: -inset),
            composer.bottomAnchor.constraint(equalTo: viewportHost.bottomAnchor, constant: -inset),
        ])
        pointComposer = composer
        window?.makeFirstResponder(composer.field)
    }

    /// Takes the screenshot (the outline is in the page, the composer is not), then hands the report to the owner.
    func sendPoint(_ text: String) {
        let comment = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let element = pointedElement, let token = pointToken else { return }
        guard !comment.isEmpty else { return NSSound.beep() }
        pointComposer?.isEnabled = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            let png = try? await self.snapshot()
            guard self.pointToken == token else { return }
            let report = ElementPointReport(element: element, comment: comment, screenshot: png,
                                            url: self.currentURL?.absoluteString, title: self.pageTitle)
            let delivery = self.onPointAtElement?(report) ?? .copied(reason: String(localized: "no terminal"))
            self.endPointing()
            switch delivery {
            case .sent(let target): self.showNotice(.pointSent(target: target))
            case .copied(let reason): self.showNotice(.pointCopied(reason: reason))
            }
        }
    }
}

/// The composer at the bottom of a browser pane: which element was picked and a field for what is wrong with it.
/// Return sends, Esc or × gives up.
@MainActor
final class ElementComposerBar: NSVisualEffectView, NSTextFieldDelegate {
    let field = NSTextField()
    var onSend: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private let sendButton: NSButton

    var isEnabled = true {
        didSet {
            field.isEnabled = isEnabled
            sendButton.isEnabled = isEnabled
        }
    }

    init(element: String, target: String?) {
        sendButton = NSButton(title: String(localized: "Send", comment: "Point at Element composer: send to the agent"),
                              target: nil, action: nil)
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.6).cgColor
        setAccessibilityIdentifier("cmds.browserPointComposer")

        let icon = NSImageView(image: NSImage(systemSymbolName: "scope", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = .systemRed
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = NSTextField(labelWithString: element)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        label.toolTip = element

        field.placeholderString = target.map {
            String(localized: "What is wrong? Return sends it to \($0)",
                   comment: "Point at Element composer placeholder; the argument is the terminal's name")
        } ?? String(localized: "What is wrong? Return copies it (no agent in this workspace)",
                    comment: "Point at Element composer placeholder without an agent terminal")
        field.font = .systemFont(ofSize: 12)
        field.bezelStyle = .roundedBezel
        field.controlSize = .small
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        field.setAccessibilityIdentifier("cmds.browserPointField")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        sendButton.bezelStyle = .rounded
        sendButton.controlSize = .small
        sendButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sendButton.bezelColor = .controlAccentColor
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        let close = BrowserPane.toolbarButton("xmark", label: String(localized: "Cancel"))
        close.target = self
        close.action = #selector(cancelClicked)

        let stack = NSStackView(views: [icon, label, field, sendButton, close])
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

    @objc private func sendClicked() { onSend?(field.stringValue) }
    @objc private func cancelClicked() { onCancel?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSend?(field.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }
}

#if DEBUG
extension BrowserPane {
    /// `debug.point` (tests only): `action` `start` / `cancel` / `send` (with `text`), then the state: pointing, the
    /// picked element, the composer's placeholder and the notice shown.
    func debugPoint(action: String?, text: String?) -> JSONValue {
        switch action {
        case "start": startPointing()
        case "cancel": endPointing()
        case "send": sendPoint(text ?? "")
        default: break
        }
        var state: [String: JSONValue] = ["pointing": .bool(isPointing),
                                          "composer": pointComposer.map { .string($0.field.placeholderString ?? "") } ?? .null,
                                          "notice": noticeText.map(JSONValue.string) ?? .null]
        if let element = pointedElement, let data = try? JSONEncoder().encode(element),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            state["element"] = value
        }
        return .object(state)
    }
}
#endif
