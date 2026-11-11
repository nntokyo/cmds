import AppKit
import AVFoundation
import CmdsCore

/// Settings › Assistant (#243, macOS 26 and later): on / off, the name it answers to, the HUD's style, the voice and
/// its rate, muting, the listen shortcut; the beta note (free for now, #244) and privacy notes.
@MainActor
final class AssistantSettingsPane: NSObject, NSTextFieldDelegate {
    private let settings = AppSettings.shared
    private let enabledCheckbox = NSButton(checkboxWithTitle: String(localized: "Turn on the assistant", comment: "Settings › Assistant"),
                                           target: nil, action: nil)
    private let namesField = NSTextField()
    private let stylePopup = NSPopUpButton()
    private let voicePopup = NSPopUpButton()
    private let rateSlider = NSSlider()
    private let mutedCheckbox = NSButton(checkboxWithTitle: String(localized: "Show answers without speaking", comment: "Settings › Assistant"),
                                         target: nil, action: nil)
    private let hotkeyPopup = NSPopUpButton()
    private let statusNote = NSTextField(wrappingLabelWithString: "")
    private var voiceLanguage = ""

    /// The grid rows; `header` rows are none.
    func rows(label: (String) -> NSTextField, note: (String) -> NSTextField) -> [[NSView]] {
        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(enabledToggled)
        namesField.placeholderString = AssistantAddressing.defaultNames.joined(separator: ", ")
        namesField.delegate = self
        namesField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        namesField.setAccessibilityLabel(String(localized: "Name", comment: "Settings › Assistant"))
        for style in AssistantStyle.allCases {
            stylePopup.addItem(withTitle: style.title)
            stylePopup.lastItem?.representedObject = style.rawValue
        }
        stylePopup.target = self
        stylePopup.action = #selector(styleChanged)
        voicePopup.target = self
        voicePopup.action = #selector(voiceChanged)
        rateSlider.minValue = AppSettings.assistantRateRange.lowerBound
        rateSlider.maxValue = AppSettings.assistantRateRange.upperBound
        rateSlider.target = self
        rateSlider.action = #selector(rateChanged)
        rateSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        rateSlider.setAccessibilityLabel(String(localized: "Speaking rate", comment: "Settings › Assistant"))
        mutedCheckbox.target = self
        mutedCheckbox.action = #selector(mutedToggled)
        for hotkey in AssistantHotkey.allCases {
            hotkeyPopup.addItem(withTitle: hotkey.title)
            hotkeyPopup.lastItem?.representedObject = hotkey.rawValue
        }
        hotkeyPopup.target = self
        hotkeyPopup.action = #selector(hotkeyChanged)
        statusNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusNote.textColor = .systemOrange
        statusNote.preferredMaxLayoutWidth = 300

        let names = AssistantAddressing.defaultNames
        return [
            [NSGridCell.emptyContentView, enabledCheckbox],
            [NSGridCell.emptyContentView, note(String(localized: "Beta: free for now. The assistant will later be part of a cmds subscription.", comment: "Settings › Assistant: the assistant is in a free beta (#244)"))],
            [NSGridCell.emptyContentView, statusNote],
            [label(String(localized: "Name:", comment: "Settings › Assistant: the name it answers to")), namesField],
            [NSGridCell.emptyContentView, note(String(localized: "It answers only when you start with its name (\(names[0]) or \(names[1]) unless you set others, separated by commas), or right after it spoke. Everything else is dropped at once; nothing heard is stored.", comment: "Settings › Assistant"))],
            [label(String(localized: "Shortcut:", comment: "Settings › Assistant: listen for one command")), hotkeyPopup],
            [label(String(localized: "Style:", comment: "Settings › Assistant")), stylePopup],
            [label(String(localized: "Voice:", comment: "Settings › Assistant")), voicePopup],
            [label(String(localized: "Rate:", comment: "Settings › Assistant: speaking rate")), rateSlider],
            [NSGridCell.emptyContentView, mutedCheckbox],
            [NSGridCell.emptyContentView, note(String(localized: "Speech is recognised on this Mac in the app's language (cmds › Language). Answers come from the workspaces and Apple's on-device model; a detailed summary asks Claude Code (claude -p). Anything that types into a pane or starts a session is shown first and runs only after you say yes or press Return; deletes, pushes, deploys and SSH panes need Return or a click.", comment: "Settings › Assistant"))],
        ]
    }

    func refresh() {
        let unlocked = PaidFeatures.isUnlocked(.assistant)
        enabledCheckbox.state = settings.assistantEnabled ? .on : .off
        enabledCheckbox.isEnabled = unlocked
        if namesField.currentEditor() == nil { namesField.stringValue = settings.assistantNames }
        stylePopup.selectItem(at: stylePopup.indexOfItem(withRepresentedObject: settings.assistantStyle.rawValue))
        fillVoices()
        rateSlider.doubleValue = settings.assistantRate
        mutedCheckbox.state = settings.assistantMuted ? .on : .off
        hotkeyPopup.selectItem(at: hotkeyPopup.indexOfItem(withRepresentedObject: settings.assistantHotkey.rawValue))
        var problem: String?
        if #available(macOS 26.0, *) { problem = AssistantController.shared?.problem }
        statusNote.stringValue = problem ?? ""
        statusNote.isHidden = problem == nil
    }

    /// The voices for the app's language, rebuilt when the language changes.
    private func fillVoices() {
        let language = AssistantLanguage.current.voiceLanguage
        if language != voiceLanguage {
            voiceLanguage = language
            voicePopup.removeAllItems()
            voicePopup.addItem(withTitle: String(localized: "System Voice", comment: "Settings › Assistant › Voice"))
            voicePopup.lastItem?.representedObject = nil
            for voice in AssistantVoice.voices(language: language) {
                let quality = voice.quality == .premium ? " (Premium)" : voice.quality == .enhanced ? " (Enhanced)" : ""
                voicePopup.addItem(withTitle: voice.name + quality)
                voicePopup.lastItem?.representedObject = voice.identifier
            }
        }
        let index = settings.assistantVoice.map { voicePopup.indexOfItem(withRepresentedObject: $0) } ?? 0
        voicePopup.selectItem(at: max(index, 0))
    }

    @objc private func enabledToggled() {
        let on = enabledCheckbox.state == .on
        if #available(macOS 26.0, *), let assistant = AssistantController.shared {
            on ? assistant.turnOn() : assistant.turnOff()
        } else {
            settings.assistantEnabled = on
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        settings.assistantNames = namesField.stringValue
    }

    @objc private func styleChanged() {
        settings.assistantStyle = (stylePopup.selectedItem?.representedObject as? String).flatMap(AssistantStyle.init(rawValue:)) ?? .jarvis
    }

    @objc private func voiceChanged() {
        settings.assistantVoice = voicePopup.selectedItem?.representedObject as? String
    }

    @objc private func rateChanged() {
        settings.assistantRate = (rateSlider.doubleValue * 100).rounded() / 100
    }

    @objc private func mutedToggled() {
        settings.assistantMuted = mutedCheckbox.state == .on
    }

    @objc private func hotkeyChanged() {
        settings.assistantHotkey = (hotkeyPopup.selectedItem?.representedObject as? String).flatMap(AssistantHotkey.init(rawValue:)) ?? .optionCommandJ
    }
}
