import Foundation

/// Pairing helpers for the Mac side (code generation, token issue, constant-time checks).
public enum PairingToken {
    /// New random 6-digit code (leading zeros kept), e.g. "042917".
    public static func generateCode() -> String {
        var rng = SystemRandomNumberGenerator()
        let n = UInt32.random(in: 0..<1_000_000, using: &rng)
        return String(format: "%06u", n)
    }

    /// New random token: 32 bytes, base64url without padding (43 chars).
    public static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Compares two secrets in time independent of where they differ.
    /// (Length is not hidden; codes and tokens have fixed lengths.)
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(truncatingIfNeeded: x.count ^ y.count)
        let n = max(x.count, y.count)
        for i in 0..<n {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            diff |= l ^ r
        }
        return diff == 0 && x.count == y.count
    }

    /// True if `candidate` equals any of `known`; checks every entry (no early exit).
    public static func matchesAny(_ candidate: String, in known: [String]) -> Bool {
        var found = false
        for token in known where constantTimeEquals(candidate, token) { found = true }
        return found
    }

    /// Whether a string looks like a pairing code (exactly 6 ASCII digits).
    public static func isWellFormedCode(_ code: String) -> Bool {
        code.utf8.count == SyncProtocol.pairingCodeLength && code.utf8.allSatisfy { (0x30...0x39).contains($0) }
    }
}

/// Mac-side decision for a `hello`. Pure: the caller owns code lifetime, token storage and rate limiting.
///
///     switch PairingAuthenticator.evaluate(hello, currentCode: code, knownTokens: store.tokens) {
///     case .accepted(let token, let isNew): if isNew { store.add(token, for: hello.deviceName) }; send(.welcome(...token))
///     case .rejected(let err): send(.error(err)); close()
///     }
public enum PairingAuthenticator {
    public enum Outcome: Equatable, Sendable {
        /// `isNewToken` = paired with the code now; persist the token and invalidate the code.
        case accepted(token: String, isNewToken: Bool)
        case rejected(ServerMessage.ErrorInfo)
    }

    /// - Parameters:
    ///   - currentCode: code currently shown on the Mac, or nil when pairing is not open.
    ///   - knownTokens: tokens issued earlier and not revoked.
    ///   - newToken: generator for fresh tokens (injectable for tests).
    public static func evaluate(_ hello: ClientMessage.Hello, currentCode: String?, knownTokens: [String],
                                newToken: () -> String = PairingToken.generate) -> Outcome {
        guard hello.protocolVersion == SyncProtocol.version else {
            return .rejected(.init(code: .unsupportedVersion,
                                   message: "protocol \(hello.protocolVersion) not supported (Mac speaks \(SyncProtocol.version))"))
        }
        if let token = hello.token, !token.isEmpty {
            if PairingToken.matchesAny(token, in: knownTokens) { return .accepted(token: token, isNewToken: false) }
            // Fall through to the code if both were sent; otherwise the token is stale.
            if hello.pairingCode == nil {
                return .rejected(.init(code: .invalidToken, message: "this device is no longer paired; enter a new code"))
            }
        }
        guard let code = hello.pairingCode else {
            return .rejected(.init(code: .pairingRequired, message: "enter the pairing code shown on the Mac"))
        }
        guard let expected = currentCode, PairingToken.isWellFormedCode(code),
              PairingToken.constantTimeEquals(code, expected) else {
            return .rejected(.init(code: .invalidPairingCode, message: "wrong or expired pairing code"))
        }
        return .accepted(token: newToken(), isNewToken: true)
    }
}

/// Exponential reconnect backoff with jitter (phone side).
public struct SyncBackoff: Sendable {
    public var base: TimeInterval
    public var cap: TimeInterval
    /// 0...1, fraction of the delay randomised.
    public var jitter: Double
    public private(set) var attempt = 0

    public init(base: TimeInterval = 0.5, cap: TimeInterval = 30, jitter: Double = 0.2) {
        self.base = base
        self.cap = cap
        self.jitter = jitter
    }

    /// Delay before the next attempt; advances the attempt counter.
    public mutating func nextDelay(random: Double = Double.random(in: 0...1)) -> TimeInterval {
        let raw = min(cap, base * pow(2, Double(min(attempt, 30))))
        attempt += 1
        return raw * (1 - jitter + 2 * jitter * random)
    }

    public mutating func reset() { attempt = 0 }
}
