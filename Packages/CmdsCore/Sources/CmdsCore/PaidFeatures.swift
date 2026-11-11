import Foundation

/// Features of the official cmds build that will need a subscription (#244). cmds is GPL-3.0: anyone may build it
/// without this check; the subscription is for the signed build from cmds.n-n.tokyo and supports its development.
public enum PaidFeature: String, CaseIterable, Sendable {
    /// The voice assistant ("JARVIS", #243).
    case assistant
}

/// Says whether a licence (later: the subscription) covers a feature. The app installs one at launch
/// (`PaidFeatures.provider`).
public protocol LicenceProvider: Sendable {
    func isUnlocked(_ feature: PaidFeature) -> Bool
}

/// No licence: covers nothing. The provider until subscriptions exist (#244: an offline-verified signed licence, the
/// developer's issued the same way as everyone's).
public struct NoLicenceProvider: LicenceProvider {
    public init() {}
    public func isUnlocked(_ feature: PaidFeature) -> Bool { false }
}

/// The one check every paid feature goes through: `PaidFeatures.isUnlocked(.assistant)`.
///
/// A feature is unlocked while it is in its free beta (`betaFree`, the one place to end it), in development builds
/// (the app sets `developmentBuild` only under `#if DEBUG`, so a release binary never does), or when the licence
/// provider says so. There is deliberately no other switch: no environment variable, user default or hard-coded
/// account.
public enum PaidFeatures {
    /// Why a feature is unlocked.
    public enum Unlock: String, Equatable, Sendable {
        /// Free for everyone during its beta.
        case beta
        case developmentBuild
        case licence
    }

    /// Features free for everyone while in beta (#244, user decision 2026-11-11: the assistant is free during the
    /// beta). Remove a feature here when its subscription starts.
    public static let betaFree: Set<PaidFeature> = [.assistant]

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

    public static func isUnlocked(_ feature: PaidFeature) -> Bool { unlock(feature) != nil }

    /// Why `feature` is unlocked; nil when it is locked.
    public static func unlock(_ feature: PaidFeature) -> Unlock? {
        unlock(feature, betaFree: betaFree, developmentBuild: developmentBuild, provider: provider)
    }

    public static func unlock(_ feature: PaidFeature, betaFree: Set<PaidFeature>, developmentBuild: Bool,
                              provider: LicenceProvider) -> Unlock? {
        if provider.isUnlocked(feature) { return .licence }
        if betaFree.contains(feature) { return .beta }
        if developmentBuild { return .developmentBuild }
        return nil
    }
}
