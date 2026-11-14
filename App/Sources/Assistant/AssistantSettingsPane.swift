import AppKit
import AVFoundation
import CmdsCore

/// Settings › Assistant (#243, macOS 26 and later): on / off, the name it answers to, the HUD's style, the voice and
/// its rate, muting, the listen shortcut; the beta note (free for now, #244) and privacy notes.
@MainActor
final class AssistantSettingsPane: NSObject, NSTextFieldDelegate, NSMenuDelegate {
    private let settings = AppSettings.shared
    private let enabledCheckbox = NSButton(checkboxWithTitle: String(localized: "Turn on the assistant", comment: "Settings › Assistant"),
                                           target: nil, action: nil)
    private let namesField = NSTextField()
    private let stylePopup = NSPopUpButton()
    private let waitingCheckbox = NSButton(checkboxWithTitle: String(localized: "Show while waiting", comment: "Settings › Assistant: a small orb shows while the assistant waits for its name"),
                                           target: nil, action: nil)
    private let orbSizePopup = NSPopUpButton()
    private let voicePopup = NSPopUpButton()
    private let rateSlider = NSSlider()
    private let mutedCheckbox = NSButton(checkboxWithTitle: String(localized: "Show answers without speaking", comment: "Settings › Assistant"),
                                         target: nil, action: nil)
    private let webCheckbox = NSButton(checkboxWithTitle: String(localized: "Use Claude for web questions", comment: "Settings › Assistant: weather, news, “search…” go to claude -p with web search"),
                                       target: nil, action: nil)
    private let interpreterCheckbox = NSButton(checkboxWithTitle: String(localized: "Use Claude to understand free commands", comment: "Settings › Assistant: commands in free words are interpreted by claude -p without tools"),
                                               target: nil, action: nil)
    private let reportTasksCheckbox = NSButton(checkboxWithTitle: String(localized: "Report on tasks I gave", comment: "Settings › Assistant: say when a session the assistant started or instructed is done or needs you"),
                                               target: nil, action: nil)
    private let shareCheckbox = NSButton(checkboxWithTitle: String(localized: "Pause while another app uses the microphone", comment: "Settings › Assistant: stop listening during a call in another app"),
                                         target: nil, action: nil)
    /// The apps that never pause it (#295: "Don't Pause for …" in the menu bar), with a Remove menu (one app or all,
    /// #305); hidden while none.
    private let ignoredNote = NSTextField(wrappingLabelWithString: "")
    private let removeIgnoredPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private lazy var ignoredRow: NSStackView = {
        let row = NSStackView(views: [ignoredNote, removeIgnoredPopup])
        row.spacing = 8
        row.alignment = .firstBaseline
        return row
    }()
    private let foldersField = NSTextField()
    private let hotkeyPopup = NSPopUpButton()
    private let listeningPopup = NSPopUpButton()
    private let microphonePopup = NSPopUpButton()
    /// The microphone list is rebuilt when the connected devices change.
    private var microphoneListKey = ""
    private let statusNote = NSTextField(wrappingLabelWithString: "")
    private let personalButton = NSButton(title: String(localized: "Use my Personal Voice…", comment: "Settings › Assistant: asks macOS whether cmds may use the user's Personal Voice"),
                                          target: nil, action: nil)
    private let personalSettingsButton = NSButton(title: String(localized: "Personal Voice Settings…", comment: "Settings › Assistant: opens System Settings › Accessibility › Personal Voice"),
                                                  target: nil, action: nil)
    private let personalNote = NSTextField(wrappingLabelWithString: "")
    /// The voice list is rebuilt when the language or the Personal Voices change.
    private var voiceListKey = ""

    /// The grid rows and which of them are section headers (#264: Spoken Answers, Claude Code, Privacy and Safety, so the
    /// long tab reads in parts; Settings scrolls it).
    func rows(label: (String) -> NSTextField, note: (String) -> NSTextField,
              header: (String) -> NSTextField) -> (rows: [[NSView]], headers: [Int]) {
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
        waitingCheckbox.target = self
        waitingCheckbox.action = #selector(waitingToggled)
        for size in AssistantPresence.Size.allCases {
            orbSizePopup.addItem(withTitle: size.title)
            orbSizePopup.lastItem?.representedObject = size.rawValue
        }
        orbSizePopup.target = self
        orbSizePopup.action = #selector(orbSizeChanged)
        orbSizePopup.setAccessibilityLabel(String(localized: "Orb size", comment: "Settings › Assistant: the size of the orb shown while waiting (VoiceOver)"))
        voicePopup.target = self
        voicePopup.action = #selector(voiceChanged)
        for button in [personalButton, personalSettingsButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.target = self
        }
        personalButton.action = #selector(personalVoiceClicked)
        personalSettingsButton.action = #selector(personalVoiceSettingsClicked)
        personalNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        personalNote.textColor = .secondaryLabelColor
        personalNote.preferredMaxLayoutWidth = 300
        let personalButtons = NSStackView(views: [personalButton, personalSettingsButton])
        personalButtons.spacing = 8
        rateSlider.minValue = AppSettings.assistantRateRange.lowerBound
        rateSlider.maxValue = AppSettings.assistantRateRange.upperBound
        rateSlider.target = self
        rateSlider.action = #selector(rateChanged)
        rateSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        rateSlider.setAccessibilityLabel(String(localized: "Speaking rate", comment: "Settings › Assistant"))
        mutedCheckbox.target = self
        mutedCheckbox.action = #selector(mutedToggled)
        webCheckbox.target = self
        webCheckbox.action = #selector(webToggled)
        interpreterCheckbox.target = self
        interpreterCheckbox.action = #selector(interpreterToggled)
        reportTasksCheckbox.target = self
        reportTasksCheckbox.action = #selector(reportTasksToggled)
        shareCheckbox.target = self
        shareCheckbox.action = #selector(shareToggled)
        ignoredNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        ignoredNote.textColor = .secondaryLabelColor
        ignoredNote.preferredMaxLayoutWidth = 230
        removeIgnoredPopup.controlSize = .small
        removeIgnoredPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        foldersField.placeholderString = AssistantPlaces.defaultRoots.joined(separator: ", ")
        foldersField.delegate = self
        foldersField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        foldersField.setAccessibilityLabel(String(localized: "Project folders", comment: "Settings › Assistant"))
        for hotkey in AssistantHotkey.allCases {
            hotkeyPopup.addItem(withTitle: hotkey.title)
            hotkeyPopup.lastItem?.representedObject = hotkey.rawValue
        }
        hotkeyPopup.target = self
        hotkeyPopup.action = #selector(hotkeyChanged)
        for mode in AssistantListening.allCases {
            listeningPopup.addItem(withTitle: mode.title)
            listeningPopup.lastItem?.representedObject = mode.rawValue
        }
        listeningPopup.target = self
        listeningPopup.action = #selector(listeningChanged)
        microphonePopup.target = self
        microphonePopup.action = #selector(microphoneChanged)
        microphonePopup.menu?.delegate = self
        statusNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusNote.textColor = .systemOrange
        statusNote.preferredMaxLayoutWidth = 300

        let names = AssistantAddressing.defaultNames
        var headers: [NSView] = []
        func section(_ title: String) -> [NSView] {
            let view = header(title)
            headers.append(view)
            return [view, NSGridCell.emptyContentView]
        }
        let rows: [[NSView]] = [
            [NSGridCell.emptyContentView, enabledCheckbox],
            [NSGridCell.emptyContentView, note(String(localized: "Beta: free for now. The assistant will later be part of a cmds subscription.", comment: "Settings › Assistant: the assistant is in a free beta (#244)"))],
            [NSGridCell.emptyContentView, statusNote],
            [label(String(localized: "Name:", comment: "Settings › Assistant: the name it answers to")), namesField],
            [NSGridCell.emptyContentView, note(String(localized: "It answers only when you start with its name (\(names[0]) or \(names[1]) unless you set others, separated by commas), or right after it spoke. Everything else is dropped at once; nothing heard is stored.", comment: "Settings › Assistant"))],
            [label(String(localized: "Shortcut:", comment: "Settings › Assistant: listen for one command")), hotkeyPopup],
            [label(String(localized: "Listening:", comment: "Settings › Assistant: automatic / with noise reduction / push to talk")), listeningPopup],
            [NSGridCell.emptyContentView, note(String(localized: "Noise reduction suppresses the noise around you (a café, a station) and its own voice. Push to talk hears only while you hold the shortcut, without its name; letting go ends what you said at once. Best in very loud places.", comment: "Settings › Assistant: under Listening"))],
            [label(String(localized: "Microphone:", comment: "Settings › Assistant: which input it listens to")), microphonePopup],
            [NSGridCell.emptyContentView, note(String(localized: "Automatic uses a headset such as AirPods when one is connected: it is close to your mouth and hears much less of a loud room.", comment: "Settings › Assistant: under Microphone"))],
            [NSGridCell.emptyContentView, shareCheckbox],
            [NSGridCell.emptyContentView, note(String(localized: "During a call or a recording in another app it stops listening, and listens again when that ends. Resume Listening in the menu bar during the call keeps it on until the call ends.", comment: "Settings › Assistant: under Pause while another app uses the microphone"))],
            [NSGridCell.emptyContentView, ignoredRow],
            [label(String(localized: "Style:", comment: "Settings › Assistant")), stylePopup],
            [NSGridCell.emptyContentView, waitingCheckbox],
            [label(String(localized: "Orb size:", comment: "Settings › Assistant: the size of the orb shown while waiting")), orbSizePopup],
            [NSGridCell.emptyContentView, note(String(localized: "A small orb at the bottom right while it waits for its name: dim while paused, orange when a workspace needs you. It grows into the HUD when you speak to it. Click it for the last answer; drag it anywhere.", comment: "Settings › Assistant: under Show while waiting"))],
            section(String(localized: "Spoken Answers", comment: "Settings › Assistant: section header (the voice, its rate, muting)")),
            [label(String(localized: "Voice:", comment: "Settings › Assistant")), voicePopup],
            [NSGridCell.emptyContentView, personalButtons],
            [NSGridCell.emptyContentView, personalNote],
            [label(String(localized: "Rate:", comment: "Settings › Assistant: speaking rate")), rateSlider],
            [NSGridCell.emptyContentView, mutedCheckbox],
            section(String(localized: "Claude Code", comment: "Settings › Assistant: section header (what the assistant asks Claude Code)")),
            [NSGridCell.emptyContentView, webCheckbox],
            [NSGridCell.emptyContentView, note(String(localized: "Weather, news, prices and “search…” go to Claude Code (claude -p) with web search only. This uses your Claude Code usage.", comment: "Settings › Assistant: under Use Claude for web questions"))],
            [NSGridCell.emptyContentView, interpreterCheckbox],
            [NSGridCell.emptyContentView, note(String(localized: "Instructions in your own words (“tell api's Claude to write the login tests”) are worked out by Claude Code without any tools, from your words and the workspaces' names only, and shown on a card before anything is sent. This uses your Claude Code usage.", comment: "Settings › Assistant: under Use Claude to understand free commands"))],
            [label(String(localized: "Project folders:", comment: "Settings › Assistant: where folders said by name are looked for")), foldersField],
            [NSGridCell.emptyContentView, note(String(localized: "“Start Claude in cmds and have it write the login tests”: a workspace of that name, else a folder of that name up to three levels inside these folders (comma separated; repositories first). The card shows the folder and the first prompt before anything starts.", comment: "Settings › Assistant: under Project folders"))],
            [NSGridCell.emptyContentView, reportTasksCheckbox],
            [NSGridCell.emptyContentView, note(String(localized: "Says in one sentence when a session it started with a task, or gave an instruction to, is done or asks you something. Other sessions are not announced.", comment: "Settings › Assistant: under Report on tasks I gave"))],
            section(String(localized: "Privacy and Safety", comment: "Settings › Assistant: section header (what is heard, where answers come from, confirmations)")),
            [NSGridCell.emptyContentView, note(String(localized: "Speech is recognised on this Mac in the app's language (cmds › Language). Answers come from the workspaces and Apple's on-device model; a detailed summary and web questions ask Claude Code (claude -p). Anything that types into a pane or starts a session is shown first and runs only after you say yes or press Return; deletes, pushes, deploys and SSH panes need Return or a click.", comment: "Settings › Assistant"))],
        ]
        return (rows, rows.indices.filter { index in headers.contains { $0 === rows[index][0] } })
    }

    func refresh() {
        let unlocked = PaidFeatures.isUnlocked(.assistant)
        enabledCheckbox.state = settings.assistantEnabled ? .on : .off
        enabledCheckbox.isEnabled = unlocked
        if namesField.currentEditor() == nil { namesField.stringValue = settings.assistantNames }
        stylePopup.selectItem(at: stylePopup.indexOfItem(withRepresentedObject: settings.assistantStyle.rawValue))
        waitingCheckbox.state = settings.assistantShowWhileWaiting ? .on : .off
        orbSizePopup.selectItem(at: orbSizePopup.indexOfItem(withRepresentedObject: settings.assistantOrbSize.rawValue))
        orbSizePopup.isEnabled = settings.assistantShowWhileWaiting
        fillVoices()
        rateSlider.doubleValue = settings.assistantRate
        mutedCheckbox.state = settings.assistantMuted ? .on : .off
        webCheckbox.state = settings.assistantWeb ? .on : .off
        interpreterCheckbox.state = settings.assistantInterpreter ? .on : .off
        reportTasksCheckbox.state = settings.assistantReportTasks ? .on : .off
        shareCheckbox.state = settings.assistantShareMicrophone ? .on : .off
        refreshIgnored()
        if foldersField.currentEditor() == nil { foldersField.stringValue = settings.assistantProjectFolders }
        hotkeyPopup.selectItem(at: hotkeyPopup.indexOfItem(withRepresentedObject: settings.assistantHotkey.rawValue))
        listeningPopup.selectItem(at: listeningPopup.indexOfItem(withRepresentedObject: settings.assistantListening.rawValue))
        fillMicrophones()
        refreshProblem()
    }

    /// Automatic, System Default and the connected inputs (#270); a chosen one that is not connected stays listed.
    private func fillMicrophones() {
        let devices = AssistantAudioDevices.inputs()
        let chosen = settings.assistantMicrophone
        let missing = AssistantInputDevice.isDevice(chosen) && !devices.contains { $0.uid == chosen }
        let key = (devices.map { $0.uid + $0.name } + [missing ? chosen : ""]).joined(separator: "|")
        if key != microphoneListKey {
            microphoneListKey = key
            microphonePopup.removeAllItems()
            addMicrophone(String(localized: "Automatic (headset when connected)", comment: "Settings › Assistant › Microphone"),
                          setting: AssistantInputDevice.automatic)
            addMicrophone(String(localized: "System Default", comment: "Settings › Assistant › Microphone: the input chosen in System Settings › Sound"),
                          setting: AssistantInputDevice.systemDefault)
            microphonePopup.menu?.addItem(.separator())
            for device in devices {
                addMicrophone(device.name, setting: device.uid)
            }
            if missing {
                addMicrophone(String(localized: "Not connected", comment: "Settings › Assistant › Microphone: the chosen microphone is not connected now"),
                              setting: chosen)
            }
        }
        microphonePopup.selectItem(at: max(0, microphonePopup.indexOfItem(withRepresentedObject: chosen)))
    }

    /// An item of the Microphone menu for a value of `AppSettings.assistantMicrophone`.
    private func addMicrophone(_ title: String, setting: String) {
        microphonePopup.addItem(withTitle: title)
        microphonePopup.lastItem?.representedObject = setting
    }

    /// The assistant's problem (microphone denied…) above the settings; also when it comes or goes while Settings is
    /// open (`AssistantController.didChange`). The scrolled page grows or shrinks with the row (#264).
    func refreshProblem() {
        var problem: String?
        if #available(macOS 26.0, *) { problem = AssistantController.shared?.problem }
        guard statusNote.stringValue != (problem ?? "") || statusNote.isHidden != (problem == nil) else { return }
        statusNote.stringValue = problem ?? ""
        statusNote.isHidden = problem == nil
        // The whole grid row, so no empty gap (with its row spacing) stays where the note would be.
        if let grid = statusNote.superview as? NSGridView { grid.cell(for: statusNote)?.row?.isHidden = problem == nil }
    }

    /// The voices for the app's language (the system's, then the user's Personal Voices that speak it), rebuilt when
    /// the language or the Personal Voices change; and the Personal Voice note.
    private func fillVoices() {
        let language = AssistantLanguage.current.voiceLanguage
        let voices = AssistantVoice.all
        let authorization = AssistantVoice.personalVoiceAuthorization
        let personal = AssistantVoices.personal(voices, language: language)
        let key = ([language, "\(authorization)"] + personal.map(\.identifier)).joined(separator: "|")
        if key != voiceListKey {
            voiceListKey = key
            voicePopup.removeAllItems()
            voicePopup.addItem(withTitle: String(localized: "System Voice", comment: "Settings › Assistant › Voice"))
            voicePopup.lastItem?.representedObject = nil
            for voice in AssistantVoices.system(voices, language: language) {
                let quality = voice.quality == AVSpeechSynthesisVoiceQuality.premium.rawValue ? " (Premium)"
                    : voice.quality == AVSpeechSynthesisVoiceQuality.enhanced.rawValue ? " (Enhanced)" : ""
                voicePopup.addItem(withTitle: voice.name + quality)
                voicePopup.lastItem?.representedObject = voice.identifier
            }
            if !personal.isEmpty { voicePopup.menu?.addItem(.separator()) }
            for voice in personal {
                voicePopup.addItem(withTitle: String(localized: "\(voice.name) (Personal Voice)", comment: "Settings › Assistant › Voice: the user's own Personal Voice"))
                voicePopup.lastItem?.representedObject = voice.identifier
            }
        }
        let index = settings.assistantVoice.map { voicePopup.indexOfItem(withRepresentedObject: $0) } ?? 0
        voicePopup.selectItem(at: max(index, 0))

        let state = AssistantVoices.personalVoiceState(authorization, voices: voices, language: language)
        personalButton.isHidden = state != .notRequested
        personalSettingsButton.isHidden = state == .unsupported
        personalNote.stringValue = Self.personalNote(state, chosenMissing: index < 0)
    }

    private static func personalNote(_ state: AssistantVoices.PersonalVoiceState, chosenMissing: Bool) -> String {
        var lines: [String] = []
        switch state {
        case .notRequested:
            lines.append(String(localized: "Your own Personal Voice can speak the answers. cmds asks macOS first; it never records or copies a voice.", comment: "Settings › Assistant: Personal Voice not asked yet"))
        case .denied:
            lines.append(String(localized: "cmds may not use your Personal Voice. Allow it in System Settings › Accessibility › Personal Voice.", comment: "Settings › Assistant: Personal Voice denied"))
        case .unsupported:
            lines.append(String(localized: "Personal Voice is not available on this Mac.", comment: "Settings › Assistant"))
        case .noneCreated:
            lines.append(String(localized: "You have no Personal Voice yet. Create one in System Settings › Accessibility › Personal Voice.", comment: "Settings › Assistant"))
        case .available:
            lines.append(String(localized: "Your Personal Voice is in the list above.", comment: "Settings › Assistant"))
        case .otherLanguagesOnly(let languages):
            let names = languages.map { Locale.current.localizedString(forIdentifier: $0) ?? $0 }
            lines.append(String(localized: "Your Personal Voice speaks \(AssistantLanguage.current.list(names)) only, so answers in this language use the system voice.", comment: "Settings › Assistant: the Personal Voice cannot speak the app's language"))
        }
        if chosenMissing {
            lines.append(String(localized: "The chosen voice is not available: the system voice speaks.", comment: "Settings › Assistant"))
        }
        return lines.joined(separator: AssistantLanguage.current.sentenceSeparator)
    }

    @objc private func personalVoiceClicked() {
        AssistantVoice.requestPersonalVoice { [weak self] in self?.refresh() }
    }

    @objc private func personalVoiceSettingsClicked() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
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
        if (notification.object as? NSTextField) === foldersField {
            settings.assistantProjectFolders = foldersField.stringValue
        } else {
            settings.assistantNames = namesField.stringValue
        }
    }

    @objc private func styleChanged() {
        settings.assistantStyle = (stylePopup.selectedItem?.representedObject as? String).flatMap(AssistantStyle.init(rawValue:)) ?? .jarvis
    }

    @objc private func waitingToggled() {
        settings.assistantShowWhileWaiting = waitingCheckbox.state == .on
    }

    @objc private func orbSizeChanged() {
        settings.assistantOrbSize = (orbSizePopup.selectedItem?.representedObject as? String).flatMap(AssistantPresence.Size.init(rawValue:)) ?? .small
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

    @objc private func webToggled() {
        settings.assistantWeb = webCheckbox.state == .on
    }

    @objc private func interpreterToggled() {
        settings.assistantInterpreter = interpreterCheckbox.state == .on
    }

    @objc private func reportTasksToggled() {
        settings.assistantReportTasks = reportTasksCheckbox.state == .on
    }

    @objc private func shareToggled() {
        settings.assistantShareMicrophone = shareCheckbox.state == .on
    }

    /// The apps that never pause it, by name (#295); the row is hidden while there are none.
    private func refreshIgnored() {
        let ignored = settings.assistantIgnoredRecorders
        var names = ignored
        if #available(macOS 26.0, *) { names = ignored.map(AssistantController.ignoredAppName(bundleID:)) }
        let list = names.formatted(.list(type: .and))
        ignoredNote.stringValue = String(localized: "Never pauses for \(list).", comment: "Settings › Assistant: apps chosen with Don't Pause for … in the menu bar")
        // The whole grid row, so no empty gap stays where the list would be.
        if let grid = ignoredRow.superview as? NSGridView { grid.cell(for: ignoredRow)?.row?.isHidden = ignored.isEmpty }
        ignoredRow.isHidden = ignored.isEmpty
        // Remove ▾: each app (#305), then Remove All. A pull-down's first item is its title.
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Remove", comment: "Settings › Assistant: pull-down to take apps off the list of apps that never pause the assistant"),
                     action: nil, keyEquivalent: "")
        for (id, name) in zip(ignored, names) {
            let item = NSMenuItem(title: name, action: #selector(removeIgnoredClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            menu.addItem(item)
        }
        if ignored.count > 1 {
            menu.addItem(.separator())
            let all = NSMenuItem(title: String(localized: "Remove All", comment: "Settings › Assistant: empties the list of apps that never pause the assistant"),
                                 action: #selector(removeIgnoredClicked(_:)), keyEquivalent: "")
            all.target = self
            menu.addItem(all)
        }
        removeIgnoredPopup.menu = menu
    }

    /// One app off the list, or all of them (no app: Remove All) (#305).
    @objc private func removeIgnoredClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else {
            settings.assistantIgnoredRecorders = []
            return
        }
        settings.assistantIgnoredRecorders.removeAll { $0 == id }
    }

    @objc private func listeningChanged() {
        settings.assistantListening = (listeningPopup.selectedItem?.representedObject as? String).flatMap(AssistantListening.init(rawValue:)) ?? .standard
    }

    @objc private func microphoneChanged() {
        settings.assistantMicrophone = microphonePopup.selectedItem?.representedObject as? String ?? AssistantInputDevice.automatic
    }

    /// The list is current when it opens (a headset connected while Settings was open).
    func menuNeedsUpdate(_ menu: NSMenu) {
        fillMicrophones()
    }

    @objc private func hotkeyChanged() {
        settings.assistantHotkey = (hotkeyPopup.selectedItem?.representedObject as? String).flatMap(AssistantHotkey.init(rawValue:)) ?? .optionCommandJ
    }
}
