import Foundation

/// The English (source) strings behind localized UI titles, so the command palette also finds `Split Right` by
/// "split" when the menus are in Japanese (#186). Built from the app's localized strings table: key = the English
/// source string, value = its translation.
public struct SourceTitles: Sendable {
    private let sources: [String: [String]]

    /// - Parameter table: key → localized value. Keys with format specifiers (`%@`) and untranslated entries are skipped.
    public init(table: [String: String]) {
        var sources: [String: [String]] = [:]
        for (key, value) in table where !value.isEmpty && key != value && !key.contains("%") {
            sources[value, default: []].append(key)
        }
        self.sources = sources.mapValues { $0.sorted() }
    }

    /// The English strings translated as `localized` (several when they share a translation); empty when there is
    /// none, e.g. in an English UI or for a name that is not translated.
    public func english(for localized: String) -> [String] {
        sources[localized] ?? []
    }

    /// `localized` in English, or itself: its first source string. For alternate texts made of several titles.
    public func englishOrSame(_ localized: String) -> String {
        english(for: localized).first ?? localized
    }
}
