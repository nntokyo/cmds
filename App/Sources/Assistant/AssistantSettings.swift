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
    static let assistantKeys = [assistantEnabledKey, assistantNamesKey, assistantStyleKey, assistantVoiceKey, assistantRateKey,
                                assistantMutedKey, assistantHotkeyKey, assistantWebKey, assistantInterpreterKey]

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

    var assistantHotkey: AssistantHotkey {
        get { defaults.string(forKey: Self.assistantHotkeyKey).flatMap(AssistantHotkey.init(rawValue:)) ?? .optionCommandJ }
        set { set(newValue == .optionCommandJ ? nil : newValue.rawValue, forKey: Self.assistantHotkeyKey) }
    }
}
