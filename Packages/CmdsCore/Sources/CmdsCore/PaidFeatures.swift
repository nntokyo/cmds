import Foundation

/// Features of the official cmds build that need a licence (#244). cmds is GPL-3.0: anyone may build it without this
/// check; the licence is for the signed build from cmds.n-n.tokyo and supports its development.
public enum PaidFeature: String, CaseIterable, Sendable {
    /// The voice assistant ("JARVIS", #243).
    case assistant
}

/// Says whether a licence covers a feature. The app installs one at launch (`PaidFeatures.provider`).
public protocol LicenceProvider: Sendable {
    func isUnlocked(_ feature: PaidFeature) -> Bool
}

/// The provider of release builds until licences exist: everything stays locked.
/// TODO(#244): replace with the offline-verified signed licence (Ed25519 public key in the app, licence entered in
/// Settings), issued the same way to the developer. No other way to unlock may be added here.
public struct NoLicenceProvider: LicenceProvider {
    public init() {}
    public func isUnlocked(_ feature: PaidFeature) -> Bool { false }
}

/// The one check every paid feature goes through: `PaidFeatures.isUnlocked(.assistant)`.
///
/// Unlocked when the build is a development build (Debug, bundle `tokyo.n-n.cmds.dev`: the app sets
/// `developmentBuild` only under `#if DEBUG`, so a release binary never does) or when the licence provider says so.
/// There is deliberately no other switch: no environment variable, user default or hard-coded account.
public enum PaidFeatures {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _provider: LicenceProvider = NoLicenceProvider()
    nonisolated(unsafe) private static var _developmentBuild = false

    /// Set once at launch by the app.
    public static var provider: LicenceProvider {
        get { lock.withLock { _provider } }
        set { lock.withLock { _provider = newValue } }
    }

    /// True only in Debug builds of the app (`#if DEBUG`).
    public static var developmentBuild: Bool {
        get { lock.withLock { _developmentBuild } }
        set { lock.withLock { _developmentBuild = newValue } }
    }

    public static func isUnlocked(_ feature: PaidFeature) -> Bool {
        isUnlocked(feature, developmentBuild: developmentBuild, provider: provider)
    }

    public static func isUnlocked(_ feature: PaidFeature, developmentBuild: Bool, provider: LicenceProvider) -> Bool {
        developmentBuild || provider.isUnlocked(feature)
    }
}
