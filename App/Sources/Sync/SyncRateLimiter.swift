import Foundation

/// Limits failed pairing attempts per remote host and globally (sliding one-minute window).
/// Exceeding a limit locks that host (or everyone, for the global limit) out for a while.
/// A valid token bypasses the limiter (256-bit secret); only 6-digit codes need throttling.
@MainActor
final class SyncRateLimiter {
    var perHostLimit = 5
    var globalLimit = 20
    var window: TimeInterval = 60
    var hostLockout: TimeInterval = 5 * 60
    var globalLockout: TimeInterval = 60

    private var failures: [String: [Date]] = [:]
    private var lockedUntil: [String: Date] = [:]
    private var globalFailures: [Date] = []
    private var globalLockedUntil: Date?

    /// Seconds until `host` may try again, or nil if it is not locked out.
    func lockout(host: String, now: Date = Date()) -> TimeInterval? {
        if let until = globalLockedUntil, until > now { return until.timeIntervalSince(now) }
        if let until = lockedUntil[host], until > now { return until.timeIntervalSince(now) }
        return nil
    }

    func recordFailure(host: String, now: Date = Date()) {
        prune(now: now)
        failures[host, default: []].append(now)
        globalFailures.append(now)
        if failures[host, default: []].count >= perHostLimit {
            lockedUntil[host] = now.addingTimeInterval(hostLockout)
            failures[host] = nil
        }
        if globalFailures.count >= globalLimit {
            globalLockedUntil = now.addingTimeInterval(globalLockout)
            globalFailures.removeAll()
        }
    }

    func recordSuccess(host: String) {
        failures[host] = nil
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-window)
        globalFailures.removeAll { $0 < cutoff }
        for (host, dates) in failures {
            let kept = dates.filter { $0 >= cutoff }
            failures[host] = kept.isEmpty ? nil : kept
        }
        lockedUntil = lockedUntil.filter { $0.value > now }
        if let until = globalLockedUntil, until <= now { globalLockedUntil = nil }
    }
}
