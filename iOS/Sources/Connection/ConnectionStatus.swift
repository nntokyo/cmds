import CmdsCore
import Foundation

/// State of `CompanionClient`'s connection to the current Mac, as shown to the user.
enum ConnectionStatus: Equatable {
    case idle
    case connecting
    case authenticating
    case connected
    case reconnecting(in: TimeInterval, reason: String?)
    /// Not paired with this Mac (or it asked for a new pairing): scan its QR code or pair manually.
    case pairingRequired(message: String?)
    /// Manual pairing: reading the identity the Mac presents. Nothing is sent to it.
    case checkingIdentity
    /// Manual pairing: the user compares this with the identity shown in the Mac's pairing window.
    case confirmIdentity(SyncFingerprint)
    /// The Mac's identity is pinned for this pairing; the 6-digit code is needed (or was wrong).
    case enterCode(message: String?)
    /// The Mac presented a certificate other than the pinned one. Nothing was sent; never retried
    /// automatically and never falls back to anything weaker.
    case identityMismatch(message: String)
    /// Gave up (protocol mismatch, rate limited...). User must act.
    case failed(message: String)

    var label: String {
        switch self {
        case .idle: return String(localized: "Not connected")
        case .connecting: return String(localized: "Connecting…")
        case .authenticating: return String(localized: "Authenticating…")
        case .connected: return String(localized: "Connected")
        case .reconnecting(let s, _):
            let seconds = Int(s.rounded(.up))
            return String(localized: "Reconnecting in \(seconds)s")
        case .pairingRequired, .checkingIdentity, .confirmIdentity, .enterCode: return String(localized: "Pairing required")
        case .identityMismatch: return String(localized: "Mac identity changed")
        case .failed: return String(localized: "Disconnected")
        }
    }

    var isLive: Bool { self == .connected }

    /// States in which the pairing sheet is shown.
    var needsPairing: Bool {
        switch self {
        case .pairingRequired, .checkingIdentity, .confirmIdentity, .enterCode, .identityMismatch: return true
        default: return false
        }
    }
}
