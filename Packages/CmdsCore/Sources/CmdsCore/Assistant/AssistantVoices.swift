import Foundation

/// Which voice speaks the assistant's answers (#243): the system's voices for the app's language and the user's own
/// Personal Voice (Settings › Assistant). Plain values, so the choice and the fallback are tested without
/// `AVSpeechSynthesisVoice` or the Personal Voice permission.
public enum AssistantVoices {
    public struct Voice: Equatable, Sendable {
        public var identifier: String
        public var name: String
        /// BCP 47, `ja-JP`, `en-US`.
        public var language: String
        /// A Personal Voice the user recorded on this Mac (only listed once the user allowed cmds to use it).
        public var isPersonal: Bool
        /// Higher is better (`AVSpeechSynthesisVoiceQuality`'s raw value).
        public var quality: Int

        public init(identifier: String, name: String, language: String, isPersonal: Bool = false, quality: Int = 1) {
            self.identifier = identifier
            self.name = name
            self.language = language
            self.isPersonal = isPersonal
            self.quality = quality
        }

        /// Whether it speaks `language` (`ja-JP` speaks `ja`, `ja-JP`).
        public func speaks(_ language: String) -> Bool {
            Self.base(self.language) == Self.base(language)
        }

        static func base(_ language: String) -> String {
            String(language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
        }
    }

    /// The system voices for `language`, best quality first, without Personal Voices (listed apart).
    public static func system(_ voices: [Voice], language: String) -> [Voice] {
        voices.filter { !$0.isPersonal && $0.speaks(language) }
            .sorted { ($0.quality, $0.name) > ($1.quality, $1.name) }
    }

    /// The user's Personal Voices that speak `language`.
    public static func personal(_ voices: [Voice], language: String) -> [Voice] {
        voices.filter { $0.isPersonal && $0.speaks(language) }.sorted { $0.name < $1.name }
    }

    /// The voice to speak `language` with: the chosen one when it still exists and speaks the language; otherwise nil
    /// (the system voice for the language). `fellBack` tells that a chosen voice could not be used.
    public static func resolve(chosen identifier: String?, among voices: [Voice], language: String) -> (voice: Voice?, fellBack: Bool) {
        guard let identifier else { return (nil, false) }
        guard let voice = voices.first(where: { $0.identifier == identifier }), voice.speaks(language) else { return (nil, true) }
        return (voice, false)
    }

    /// Whether cmds may use the user's Personal Voice (`AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus`).
    public enum Authorization: Equatable, Sendable {
        case notDetermined
        case denied
        case unsupported
        case authorized
    }

    /// What Settings › Assistant says about Personal Voice.
    public enum PersonalVoiceState: Equatable, Sendable {
        /// Not asked yet: the "Use my Personal Voice…" button asks.
        case notRequested
        /// The user said no (System Settings › Privacy & Security › Personal Voice turns it on again).
        case denied
        /// This Mac cannot use Personal Voice.
        case unsupported
        /// Allowed, but no Personal Voice has been created (System Settings › Accessibility › Personal Voice).
        case noneCreated
        /// Allowed, and these speak the app's language: they are in the voice list.
        case available([Voice])
        /// Allowed, but none speaks the app's language: answers use the system voice. The languages it speaks.
        case otherLanguagesOnly([String])
    }

    public static func personalVoiceState(_ authorization: Authorization, voices: [Voice], language: String) -> PersonalVoiceState {
        switch authorization {
        case .notDetermined: return .notRequested
        case .denied: return .denied
        case .unsupported: return .unsupported
        case .authorized:
            let mine = voices.filter(\.isPersonal)
            guard !mine.isEmpty else { return .noneCreated }
            let speaking = personal(voices, language: language)
            if !speaking.isEmpty { return .available(speaking) }
            var languages: [String] = []
            for voice in mine where !languages.contains(voice.language) { languages.append(voice.language) }
            return .otherLanguagesOnly(languages)
        }
    }
}
