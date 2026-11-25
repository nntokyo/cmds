import Foundation

/// When a failed background update check is tried again (the app's `Updater`). Sparkle counts a failed check as the
/// day's check: one that falls on a moment without a network (a wake of a few seconds while the Mac sleeps, a router
/// restart) would leave the next one a day away, and a Mac whose daily check keeps falling on such a moment would
/// never update.
public enum UpdateCheckRetry {
    /// Between a failed check and the next try.
    public static let delay: TimeInterval = 15 * 60
    /// Tries after one failed daily check; the next daily check starts over.
    public static let maxAttempts = 8

    /// How long to wait before trying again after a background check failed with `error` (`attempt` tries were made
    /// since the daily check, 0 = it was the daily check itself); nil = no retry. Only when the network failed: an
    /// error in the feed or in the update itself is the same on the next try.
    public static func retryDelay(after error: Error, attempt: Int) -> TimeInterval? {
        guard attempt < maxAttempts, isNetworkFailure(error) else { return nil }
        return delay
    }

    /// `error` or an error under it is a URL loading failure.
    public static func isNetworkFailure(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        for _ in 0..<8 {
            guard let error = current else { return false }
            if error.domain == NSURLErrorDomain { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
