import AppKit
import CmdsCore

/// What the HUD shows; built by `AssistantController` from its state machine.
struct AssistantHUDContent: Equatable {
    var phase: AssistantMachine.Phase
    /// A workspace needs the user (the orb turns orange).
    var attention: Bool
    var transcript: String?
    var answer: String?
    var pending: AssistantAction?
    /// The user said yes to an action that needs Return or a click.
    var needsKey: Bool
    var rings: [AssistantRingsView.Ring]
    var style: AssistantStyle
}

/// The assistant's HUD (#243): a floating, non-activating panel at the top right of the screen that never takes the
/// keyboard from the terminal (as the menu bar's reply panel, but it does not even become key): the orb, the input
/// level, what was heard, the answer, the workspaces' status rings and, when an action waits, the confirmation card
/// with the target workspace and pane and the exact text. Its buttons take clicks without activating cmds; Return and
/// Esc reach it through `AssistantHotkeys` while the card shows.
@MainActor
final class AssistantHUD: NSObject {
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    let panel = HUDWindow(contentRect: NSRect(x: 0, y: 0, width: AssistantHUD.width, height: 200),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let background = NSVisualEffectView()
    private let orb = AssistantOrbView()
    private let wave = AssistantWaveView()
    private let rings = AssistantRingsView()
    private let phaseLabel = NSTextField(labelWithString: "")
    private let transcriptLabel = NSTextField(wrappingLabelWithString: "")
    private let answerLabel = NSTextField(wrappingLabelWithString: "")
    private let card = NSStackView()
    private let targetLabel = NSTextField(labelWithString: "")
    private let textBox = NSTextField(wrappingLabelWithString: "")
    private let reasonLabel = NSTextField(wrappingLabelWithString: "")
    private let confirmButton = NSButton()
    private let cancelButton = NSButton()
    private(set) var content: AssistantHUDContent?

    static let width: CGFloat = 460
    private static let margin: CGFloat = 16
    private static let textWidth: CGFloat = 300

    override init() {
        super.init()
        build()
    }

    var isVisible: Bool { panel.isVisible }

    private func build() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.setAccessibilityLabel(String(localized: "Assistant", comment: "assistant HUD (VoiceOver)"))

        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = AssistantPalette.cyan.withAlphaComponent(0.35).cgColor
        panel.contentView = background

        phaseLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        phaseLabel.textColor = AssistantPalette.cyan
        transcriptLabel.font = .systemFont(ofSize: 12)
        transcriptLabel.textColor = .secondaryLabelColor
        answerLabel.font = .systemFont(ofSize: 14, weight: .medium)
        answerLabel.textColor = .white
        for label in [transcriptLabel, answerLabel] {
            label.preferredMaxLayoutWidth = Self.textWidth
            label.isSelectable = false
        }
        let texts = NSStackView(views: [phaseLabel, transcriptLabel, answerLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 5
        orb.translatesAutoresizingMaskIntoConstraints = false
        orb.widthAnchor.constraint(equalToConstant: 112).isActive = true
        orb.heightAnchor.constraint(equalToConstant: 112).isActive = true
        let top = NSStackView(views: [orb, texts])
        top.alignment = .centerY
        top.spacing = 14

        targetLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        targetLabel.textColor = AssistantPalette.amber
        textBox.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textBox.textColor = .white
        textBox.drawsBackground = true
        textBox.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        textBox.preferredMaxLayoutWidth = Self.width - 60
        textBox.isSelectable = true
        reasonLabel.font = .systemFont(ofSize: 11)
        reasonLabel.textColor = AssistantPalette.amber
        reasonLabel.preferredMaxLayoutWidth = Self.width - 60
        cancelButton.title = String(localized: "Cancel (esc)", comment: "assistant HUD: cancel the action")
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.setAccessibilityIdentifier("assistant.cancel")
        confirmButton.bezelStyle = .rounded
        confirmButton.keyEquivalent = ""
        confirmButton.bezelColor = AssistantPalette.amber
        confirmButton.target = self
        confirmButton.action = #selector(confirmClicked)
        confirmButton.setAccessibilityIdentifier("assistant.confirm")
        let buttons = NSStackView(views: [NSView(), cancelButton, confirmButton])
        buttons.spacing = 8
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 6
        card.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.borderColor = AssistantPalette.amber.withAlphaComponent(0.6).cgColor
        card.layer?.backgroundColor = AssistantPalette.amber.withAlphaComponent(0.08).cgColor
        for view in [targetLabel, textBox, reasonLabel, buttons] { card.addArrangedSubview(view) }
        buttons.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -24).isActive = true

        let root = NSStackView(views: [top, wave, rings, card])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(root)
        for view in [wave, rings, card] {
            view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        }
        wave.heightAnchor.constraint(equalToConstant: 22).isActive = true
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            root.topAnchor.constraint(equalTo: background.topAnchor),
            root.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }

    // MARK: Content

    func show(_ content: AssistantHUDContent) {
        if content != self.content { apply(content) }
        if !panel.isVisible {
            place()
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel.orderOut(nil)
        wave.clear()
    }

    func level(_ value: Float) {
        guard content?.style == .jarvis else { return }
        orb.level(value)
        wave.push(value)
    }

    private func apply(_ content: AssistantHUDContent) {
        self.content = content
        let jarvis = content.style == .jarvis
        orb.isHidden = !jarvis
        wave.isHidden = !jarvis
        rings.isHidden = !jarvis || content.rings.isEmpty
        orb.update(phase: content.phase, attention: content.attention)
        let color = AssistantPalette.color(content.phase, attention: content.attention)
        wave.color = color.withAlphaComponent(0.8)
        phaseLabel.textColor = color
        background.layer?.borderColor = color.withAlphaComponent(0.4).cgColor
        phaseLabel.stringValue = Self.phaseTitle(content.phase).uppercased()
        transcriptLabel.stringValue = content.transcript.map { "“\($0)”" } ?? ""
        transcriptLabel.isHidden = content.transcript == nil
        answerLabel.stringValue = content.answer ?? ""
        answerLabel.isHidden = content.answer == nil
        rings.rings = content.rings
        if let action = content.pending {
            card.isHidden = false
            targetLabel.stringValue = Self.target(action)
            textBox.stringValue = action.label.map { "\(action.text)  — \($0)" } ?? action.text
            let reasons = action.reasons.map(Self.reasonText)
            if action.confirmation == .keyOrClick {
                let lead = content.needsKey
                    ? String(localized: "A spoken yes is not enough here: press Return or click.", comment: "assistant HUD")
                    : String(localized: "Needs Return or a click:", comment: "assistant HUD: before the reasons")
                reasonLabel.stringValue = ([lead] + reasons).joined(separator: " ")
            } else {
                reasonLabel.stringValue = String(localized: "Say “yes” or press Return. “No” or Esc cancels.", comment: "assistant HUD")
            }
            confirmButton.title = Self.confirmTitle(action)
        } else {
            card.isHidden = true
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        place()
    }

    /// Top right of the screen with the menu bar, below it; the top stays put as the content grows.
    private func place() {
        guard let content = panel.contentView else { return }
        let size = content.fittingSize
        let visible = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: visible.maxX - size.width - Self.margin, y: visible.maxY - size.height - Self.margin,
                              width: size.width, height: size.height), display: true)
    }

    @objc private func confirmClicked() { onConfirm?() }
    @objc private func cancelClicked() { onCancel?() }

    // MARK: Text

    static func phaseTitle(_ phase: AssistantMachine.Phase) -> String {
        switch phase {
        case .off: return String(localized: "Off", comment: "assistant state")
        case .paused: return String(localized: "Paused", comment: "assistant state")
        case .idle: return String(localized: "Standing by", comment: "assistant state: listening for its name")
        case .listening: return String(localized: "Listening", comment: "assistant state")
        case .thinking: return String(localized: "Thinking", comment: "assistant state")
        case .speaking: return String(localized: "Speaking", comment: "assistant state")
        case .confirming: return String(localized: "Waiting for your OK", comment: "assistant state: an action waits for confirmation")
        }
    }

    static func target(_ action: AssistantAction) -> String {
        switch action.kind {
        case .startAgent:
            return String(localized: "New workspace in \(action.workspaceTitle)", comment: "assistant HUD: where a new session starts")
        case .reply, .choose:
            let pane = [action.paneTitle, action.paneID.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
            return "\(action.workspaceTitle) › \(pane)"
        }
    }

    static func confirmTitle(_ action: AssistantAction) -> String {
        switch action.kind {
        case .reply: return String(localized: "Send ⏎", comment: "assistant HUD: confirm button")
        case .choose: return String(localized: "Choose ⏎", comment: "assistant HUD: confirm button")
        case .startAgent: return String(localized: "Start ⏎", comment: "assistant HUD: confirm button")
        }
    }

    static func reasonText(_ reason: AssistantSafety.Reason) -> String {
        switch reason {
        case .destructive: return String(localized: "it may delete things.", comment: "assistant HUD: why a click is needed")
        case .publish: return String(localized: "it may push or publish.", comment: "assistant HUD: why a click is needed")
        case .deploy: return String(localized: "it may deploy.", comment: "assistant HUD: why a click is needed")
        case .permissions: return String(localized: "it widens permissions.", comment: "assistant HUD: why a click is needed")
        case .sshPane: return String(localized: "the pane is an SSH session.", comment: "assistant HUD: why a click is needed")
        }
    }

    #if DEBUG
    var debugTexts: [String: String] {
        ["phase": phaseLabel.stringValue, "transcript": transcriptLabel.stringValue, "answer": answerLabel.stringValue,
         "target": card.isHidden ? "" : targetLabel.stringValue, "text": card.isHidden ? "" : textBox.stringValue,
         "note": card.isHidden ? "" : reasonLabel.stringValue, "confirmButton": card.isHidden ? "" : confirmButton.title]
    }

    func debugClickConfirm() { confirmButton.performClick(nil) }
    func debugClickCancel() { cancelButton.performClick(nil) }
    #endif
}

/// Never key, never main: the terminal keeps the keyboard. Buttons still take clicks.
final class HUDWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
