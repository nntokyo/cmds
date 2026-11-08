import Foundation

/// When an account switch quits a pane's Claude Code (AppController+Accounts, docs/internals/architecture.md "Claude
/// accounts"): never mid-turn, then a double Ctrl-C until Claude Code is gone, giving up after a few. Pure rules,
/// unit-tested; the app supplies what it sees in the pane.
public enum ClaudeAccountSwitchTiming {
    /// How often a switch in progress is checked.
    public static let tickInterval: TimeInterval = 0.3
    /// The screen must not change for this long before Claude Code counts as idle.
    public static let idleTime: TimeInterval = 2
    /// Ctrl-C, as typed into the pane.
    public static let interrupt = "\u{3}"
    /// One attempt to quit: two Ctrl-Cs in one write. Claude Code quits on a second Ctrl-C only within about 0.7 s of
    /// the first (2.1.x; a first one may only clear a typed draft), so they are never left to the timer.
    public static let quit = interrupt + interrupt
    /// The gap between attempts when Claude Code did not quit.
    public static let retryGap: TimeInterval = 2.5
    /// No more attempts after this many.
    public static let maxAttempts = 3
    /// After the last attempt, how long to wait for the shell before giving up.
    public static let giveUpAfter: TimeInterval = 5

    /// Claude Code may be quit: it is in the foreground, not working, no subagent is running and the screen has not
    /// changed for `idleTime`.
    public static func isIdle(agentInForeground: Bool, busy: Bool, subagentRunning: Bool,
                              screenUnchangedFor: TimeInterval) -> Bool {
        agentInForeground && !busy && !subagentRunning && screenUnchangedFor >= idleTime
    }

    public enum QuitStep: Equatable, Sendable {
        /// Nothing to do yet.
        case wait
        /// Try again: send `quit`.
        case retry
        /// Claude Code did not quit: stop and tell the user.
        case giveUp
    }

    /// While quitting: `attempts` sent so far (`quit` each), the last one `sinceLast` ago.
    public static func quitStep(attempts: Int, sinceLast: TimeInterval, agentInForeground: Bool) -> QuitStep {
        if agentInForeground, attempts < maxAttempts, sinceLast >= retryGap { return .retry }
        if attempts >= maxAttempts, sinceLast >= giveUpAfter { return .giveUp }
        return .wait
    }
}
