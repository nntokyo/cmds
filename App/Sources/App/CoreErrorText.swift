import CmdsCore
import Foundation

// UI text for CmdsCore errors whose `description` stays English for the socket API and the CLI
// (docs/internals/localization.md).

extension SSHLaunch.InvalidInput {
    var localizedText: String {
        switch reason {
        case .hostEmpty: return String(localized: "Enter a host.")
        case .hostStartsWithDash: return String(localized: "The host must not start with “-”.")
        case .hostTooLong: return String(localized: "The host is too long.")
        case .hostCharacters:
            let characters = ". _ - @ : [ ] % / +" // interpolated: a literal % in a catalog key reads as a format
            return String(localized: "The host may only contain letters, digits and \(characters)")
        case .directoryTooLong: return String(localized: "The remote directory is too long.")
        case .directoryCharacters:
            return String(localized: "The remote directory must not contain quotes, backslashes or control characters.")
        case .directoryNotAbsolute: return String(localized: "The remote directory must be an absolute path or start with ~/.")
        }
    }
}

extension LidSleepError {
    var localizedText: String {
        switch self {
        case .unavailable: return String(localized: "Not available in an isolated instance (CMDS_SUPPORT_DIR).")
        case .alreadyDisabledOutsideCmds: return String(localized: "Sleep is already disabled system-wide by something other than cmds.")
        case .cancelled: return String(localized: "Cancelled.")
        case .failed(let message): return message
        }
    }
}
