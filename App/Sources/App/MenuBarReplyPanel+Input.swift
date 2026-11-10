import AppKit
import CmdsCore

/// What the menu bar reply panel sends to the pane (#213): the agent's options, the reply field, the key bar, and its
/// keyboard shortcuts (1–9, ⌘↑ / ⌘↓, Return, Esc).
extension MenuBarReplyPanel {
    /// Keys sent from the key bar.
    enum ReplyKey: Int, CaseIterable {
        case escape, up, down, enter, interrupt

        var title: String {
            switch self {
            case .escape: return "esc"
            case .up: return "↑"
            case .down: return "↓"
            case .enter: return "⏎"
            case .interrupt: return "^C"
            }
        }

        /// The bytes `typeText` turns into the key press (`GhosttySendText`).
        var bytes: String {
            switch self {
            case .escape: return "\u{1B}"
            case .up: return "\u{1B}[A"
            case .down: return "\u{1B}[B"
            case .enter: return "\r"
            case .interrupt: return "\u{03}"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .escape: return String(localized: "Send Escape", comment: "menu bar reply panel: key bar button (VoiceOver, tooltip)")
            case .up: return String(localized: "Send Up Arrow", comment: "menu bar reply panel: key bar button (VoiceOver, tooltip)")
            case .down: return String(localized: "Send Down Arrow", comment: "menu bar reply panel: key bar button (VoiceOver, tooltip)")
            case .enter: return String(localized: "Send Return", comment: "menu bar reply panel: key bar button (VoiceOver, tooltip)")
            case .interrupt: return String(localized: "Send Control-C", comment: "menu bar reply panel: key bar button (VoiceOver, tooltip)")
            }
        }
    }

    // Virtual key codes (US layout positions, as `kVK_…` in Carbon).
    private static let downArrowKeyCode: UInt16 = 125
    private static let upArrowKeyCode: UInt16 = 126
    /// How soon after sending the panel looks at the pane again (before the next regular refresh).
    private static let refreshAfterInput: TimeInterval = 0.1

    @objc func sendKey(_ sender: NSButton) {
        guard let key = ReplyKey(rawValue: sender.tag) else { return }
        send(key)
        panel.makeFirstResponder(field)
    }

    func send(_ key: ReplyKey) { type(key.bytes) }

    @objc func pickOption(_ sender: NSButton) {
        pick(sender.tag)
        panel.makeFirstResponder(field)
    }

    /// Types the option's digit. Claude Code picks an option on its number; Codex's approval list (`› 1. Yes,
    /// proceed (y)`) is believed to do the same (its selection lists accept digits), but this is not verified here —
    /// its own letter shortcuts (y, a) and ↑/↓ + Return from the key bar work either way.
    func pick(_ number: Int) {
        guard prompt?.options.contains(where: { $0.number == number }) == true else { return }
        type("\(number)")
    }

    /// The text as a paste (bracketed when the program asks for it), Return after `ScheduleRunTiming.enterDelay` (as
    /// a schedule's prompt: Return in the same burst would land in the paste); no text: Return only.
    func reply(_ text: String) {
        guard let paneID else { return }
        if text.isEmpty { return type("\r") }
        try? controller.sendText(paneID: paneID, text: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + ScheduleRunTiming.enterDelay) { [controller] in
            try? controller.typeText(paneID: paneID, text: "\r")
        }
        refreshSoon()
    }

    private func type(_ text: String) {
        guard let paneID else { return }
        try? controller.typeText(paneID: paneID, text: text)
        refreshSoon()
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.refreshAfterInput) { [weak self] in self?.refresh() }
    }

    @objc func openInMainWindow() {
        let workspaceID = workspaceID
        let paneID = paneID
        close()
        guard controller.workspace(id: workspaceID) != nil else { return }
        openInCmds(workspaceID, paneID)
    }

    /// ⌘↑ / ⌘↓, and 1–9 while the reply field is empty (not while an input method composes).
    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() == true { return false }
        if modifiers == .command, event.keyCode == Self.upArrowKeyCode || event.keyCode == Self.downArrowKeyCode {
            move(event.keyCode == Self.upArrowKeyCode ? -1 : 1)
            return true
        }
        if modifiers.isEmpty, field.stringValue.isEmpty, field.isEnabled, let characters = event.charactersIgnoringModifiers,
           let number = Int(characters), (1...9).contains(number),
           prompt?.options.contains(where: { $0.number == number }) == true {
            pick(number)
            return true
        }
        return false
    }
}

/// Return in the reply field sends it; Esc there closes the panel.
extension MenuBarReplyPanel: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            reply(field.stringValue)
            field.stringValue = ""
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }
}
