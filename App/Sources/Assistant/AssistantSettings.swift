import AppKit
import Carbon.HIToolbox
import CmdsCore

/// How the HUD looks (Settings › Assistant).
enum AssistantStyle: String, CaseIterable {
    /// The orb with its rings, waveform and the workspaces' status rings.
    case jarvis
    /// A plain panel with the text only.
    case quiet

    var title: String {
        switch self {
        case .jarvis: return String(localized: "JARVIS (animated)", comment: "Settings › Assistant › Style")
        case .quiet: return String(localized: "Quiet (text only)", comment: "Settings › Assistant › Style")
        }
    }
}

extension AssistantPresence.Size {
    var title: String {
        switch self {
        case .small: return String(localized: "Small (56 pt)", comment: "Settings › Assistant › Orb size")
        case .medium: return String(localized: "Medium (72 pt)", comment: "Settings › Assistant › Orb size")
        }
    }
}

/// The global shortcut that makes the assistant listen for one command (Settings › Assistant). A few fixed choices:
/// each is a Carbon hot key, which needs no Accessibility permission.
enum AssistantHotkey: String, CaseIterable {
    case optionCommandJ
    case controlOptionSpace
    case optionCommandSpace
    case off

    var title: String {
        switch self {
        case .optionCommandJ: return "⌥⌘J"
        case .controlOptionSpace: return "⌃⌥Space"
        case .optionCommandSpace: return "⌥⌘Space"
        case .off: return String(localized: "None", comment: "Settings › Assistant › Shortcut: no shortcut")
        }
    }

    /// Carbon key code and modifiers; nil for `off`.
    var carbon: (keyCode: UInt32, modifiers: UInt32)? {
        switch self {
        case .optionCommandJ: return (UInt32(kVK_ANSI_J), UInt32(optionKey | cmdKey))
        case .controlOptionSpace: return (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .optionCommandSpace: return (UInt32(kVK_Space), UInt32(optionKey | cmdKey))
        case .off: return nil
        }
    }
}

extension AppSettings {
    static let assistantEnabledKey = "AssistantEnabled"
    static let assistantNamesKey = "AssistantNames"
    static let assistantStyleKey = "AssistantStyle"
    static let assistantVoiceKey = "AssistantVoice"
    static let assistantRateKey = "AssistantRate"
    static let assistantMutedKey = "AssistantMuted"
    static let assistantHotkeyKey = "AssistantHotkey"
    static let assistantWebKey = "AssistantWeb"
    static let assistantInterpreterKey = "AssistantInterpreter"
    static let assistantReportTasksKey = "AssistantReportTasks"
    static let assistantProjectFoldersKey = "AssistantProjectFolders"
    static let assistantShowWhileWaitingKey = "AssistantShowWhileWaiting"
    static let assistantOrbSizeKey = "AssistantOrbSize"
    /// Where the user dragged the waiting orb ("x,y", its centre in screen points). Not observed: dragging it is no
    /// settings change.
    static let assistantOrbCenterKey = "AssistantOrbCenter"
    static let assistantKeys = [assistantEnabledKey, assistantNamesKey, assistantStyleKey, assistantVoiceKey, assistantRateKey,
                                assistantMutedKey, assistantHotkeyKey, assistantWebKey, assistantInterpreterKey,
                                assistantReportTasksKey, assistantProjectFoldersKey, assistantShowWhileWaitingKey,
                                assistantOrbSizeKey]

    /// The rates the voice may take (AVSpeechUtterance rates; 0.5 is the system default).
    static let assistantRateRange: ClosedRange<Double> = 0.35...0.65

    /// The assistant listens (#243). Off until the user turns it on; then remembered across launches.
    var assistantEnabled: Bool {
        get { defaults.bool(forKey: Self.assistantEnabledKey) }
        set { set(newValue ? true : nil, forKey: Self.assistantEnabledKey) }
    }

    /// The names it answers to, comma separated; empty: ジャービス and Jarvis.
    var assistantNames: String {
        get { defaults.string(forKey: Self.assistantNamesKey) ?? "" }
        set { set(newValue.trimmingCharacters(in: .whitespaces).isEmpty ? nil : newValue, forKey: Self.assistantNamesKey) }
    }

    var assistantStyle: AssistantStyle {
        get { defaults.string(forKey: Self.assistantStyleKey).flatMap(AssistantStyle.init(rawValue:)) ?? .jarvis }
        set { set(newValue == .jarvis ? nil : newValue.rawValue, forKey: Self.assistantStyleKey) }
    }

    /// An `AVSpeechSynthesisVoice` identifier; nil: the system's voice for the language.
    var assistantVoice: String? {
        get { defaults.string(forKey: Self.assistantVoiceKey).flatMap { $0.isEmpty ? nil : $0 } }
        set { set(newValue, forKey: Self.assistantVoiceKey) }
    }

    var assistantRate: Double {
        get {
            guard let value = (defaults.object(forKey: Self.assistantRateKey) as? NSNumber)?.doubleValue, value.isFinite else { return 0.5 }
            return min(max(value, Self.assistantRateRange.lowerBound), Self.assistantRateRange.upperBound)
        }
        set { set(newValue == 0.5 ? nil : newValue, forKey: Self.assistantRateKey) }
    }

    /// Answers are only shown, not spoken.
    var assistantMuted: Bool {
        get { defaults.bool(forKey: Self.assistantMutedKey) }
        set { set(newValue ? true : nil, forKey: Self.assistantMutedKey) }
    }

    /// Questions that need the web (weather, news, "search…") go to Claude Code with web search (`AssistantWeb`). On
    /// unless the user turns it off.
    var assistantWeb: Bool {
        get { defaults.object(forKey: Self.assistantWebKey) == nil ? true : defaults.bool(forKey: Self.assistantWebKey) }
        set { set(newValue ? nil : false, forKey: Self.assistantWebKey) }
    }

    /// Commands in free words ("api の Claude にテストを書くよう指示して") are interpreted by Claude Code without tools
    /// (`AssistantInterpretation`). On unless the user turns it off.
    var assistantInterpreter: Bool {
        get { defaults.object(forKey: Self.assistantInterpreterKey) == nil ? true : defaults.bool(forKey: Self.assistantInterpreterKey) }
        set { set(newValue ? nil : false, forKey: Self.assistantInterpreterKey) }
    }

    /// Say when a session the assistant started with a task, or gave an instruction to, is done or needs the user
    /// (`AssistantTaskWatch`). On unless the user turns it off; other sessions are never announced.
    var assistantReportTasks: Bool {
        get { defaults.object(forKey: Self.assistantReportTasksKey) == nil ? true : defaults.bool(forKey: Self.assistantReportTasksKey) }
        set { set(newValue ? nil : false, forKey: Self.assistantReportTasksKey) }
    }

    /// Where a folder said by name is looked for when an agent is started there (`AssistantPlaces`), comma separated;
    /// empty: ~/Source, ~/Developer, ~/Projects and ~/src.
    var assistantProjectFolders: String {
        get { defaults.string(forKey: Self.assistantProjectFoldersKey) ?? "" }
        set { set(newValue.trimmingCharacters(in: .whitespaces).isEmpty ? nil : newValue, forKey: Self.assistantProjectFoldersKey) }
    }

    /// The small orb shows while the assistant waits for its name (`AssistantPresence`). On unless the user turns it
    /// off.
    var assistantShowWhileWaiting: Bool {
        get { defaults.object(forKey: Self.assistantShowWhileWaitingKey) == nil ? true : defaults.bool(forKey: Self.assistantShowWhileWaitingKey) }
        set { set(newValue ? nil : false, forKey: Self.assistantShowWhileWaitingKey) }
    }

    var assistantOrbSize: AssistantPresence.Size {
        get { defaults.string(forKey: Self.assistantOrbSizeKey).flatMap(AssistantPresence.Size.init(rawValue:)) ?? .small }
        set { set(newValue == .small ? nil : newValue.rawValue, forKey: Self.assistantOrbSizeKey) }
    }

    /// nil: the default place, bottom right above the Dock.
    var assistantOrbCenter: CGPoint? {
        get { AssistantPresence.parse(defaults.string(forKey: Self.assistantOrbCenterKey)) }
        set { set(newValue.map(AssistantPresence.format), forKey: Self.assistantOrbCenterKey) }
    }

    var assistantHotkey: AssistantHotkey {
        get { defaults.string(forKey: Self.assistantHotkeyKey).flatMap(AssistantHotkey.init(rawValue:)) ?? .optionCommandJ }
        set { set(newValue == .optionCommandJ ? nil : newValue.rawValue, forKey: Self.assistantHotkeyKey) }
    }
}
