import CmdsCore
import CmdsSSH
import Foundation

// UI text for errors whose `description`/`message` comes from CmdsCore/CmdsSSH or the Mac and stays English
// (protocol, logs; docs/internals/localization.md).

extension SSHTunnelError {
    var localizedText: String {
        switch self {
        case .unknownHostKey: return String(localized: "The relay host's key is not confirmed yet.")
        case .hostKeyMismatch(let presented):
            let fingerprint = SSHKeys.fingerprint(openSSHPublicKey: presented) ?? "?"
            return String(localized: "The relay host presented a different host key (\(fingerprint)). Nothing was sent.")
        case .authenticationFailed:
            return String(localized: "The relay host did not accept this device's SSH key. Add it to authorized_keys.")
        case .forwardRefused(let detail):
            return String(localized: "The relay host could not reach the Mac's forwarded port. Is remote access on and the Mac online? (\(detail))")
        case .connectionFailed(let detail): return String(localized: "Could not reach the relay host: \(detail)")
        case .timedOut: return String(localized: "The relay host did not answer in time.")
        case .closed: return String(localized: "The SSH connection was closed.")
        }
    }
}

extension ServerMessage.ErrorInfo {
    /// The Mac's message is English (protocol); known codes get the app's text.
    var localizedMessage: String {
        switch code {
        case .invalidToken: return String(localized: "This device is no longer paired. Enter a new pairing code.")
        case .pairingRequired:
            return message.contains("local network")
                ? String(localized: "Pair on the local network first; remote access via SSH only reuses a pairing.")
                : String(localized: "Enter the pairing code shown on the Mac.")
        case .invalidPairingCode: return String(localized: "Wrong or expired pairing code.")
        case .unsupportedVersion:
            return String(localized: "The Mac runs a cmds version that does not work with this app. Update both.")
        case .rateLimited:
            return message.contains("input") ? String(localized: "Too much input. Slow down.")
                                             : String(localized: "Too many attempts. Try again in a moment.")
        default: return message
        }
    }
}
