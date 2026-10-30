import Foundation

/// A status line that is both shown in the UI (localized) and reported over the socket API / `cmds sync status`
/// (English, stable for scripts). Built from one catalog key: the English text is the key itself, looked up in a
/// table that does not exist, so it never picks up a translation.
struct LocalizedStatus: Equatable, Sendable {
    let english: String
    let localized: String

    init(_ value: String.LocalizationValue) {
        english = String(localized: value, table: "NotLocalized")
        localized = String(localized: value)
    }
}
