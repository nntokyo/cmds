import Foundation

/// When an account switch quits a pane's Claude Code (AppController+Accounts, docs/internals/architecture.md "Claude
/// accounts"): never mid-turn, then Ctrl-C until Claude Code is gone, giving up after a few. Pure rules, unit-tested;
/// the app supplies what it sees in the pane.
public enum ClaudeAccountSwitchTiming {
    /// How often a switch in progress is checked.
    public static let tickInterval: TimeInterval = 0.3
    /// The screen must not change for this long before Claude Code counts as idle.
    public static let idleTime: TimeInterval = 2
    /// Ctrl-C, as typed into the pane.
    public static let interrupt = "\u{3}"
    /// Claude Code quits on the second Ctrl-C (a first one may only clear a typed draft).
    public static let interruptsToQuit = 2
    /// The gap between the Ctrl-Cs that should quit it.
    public static let interruptGap: TimeInterval = 0.4
    /// The gap between further Ctrl-Cs when it did not quit.
    public static let retryGap: TimeInterval = 2.5
    /// No more Ctrl-Cs after this many.
    public static let maxInterrupts = 4
    /// After the last Ctrl-C, how long to wait for the shell before giving up.
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
        /// Send another Ctrl-C.
        case interrupt
        /// Claude Code did not quit: stop and tell the user.
        case giveUp
    }

    /// While quitting: `interrupts` Ctrl-Cs sent so far, the last one `sinceLast` ago.
    public static func quitStep(interrupts: Int, sinceLast: TimeInterval, agentInForeground: Bool) -> QuitStep {
        let due = interrupts < interruptsToQuit ? sinceLast >= interruptGap : sinceLast >= retryGap
        if agentInForeground, due, interrupts < maxInterrupts { return .interrupt }
        if interrupts >= maxInterrupts, sinceLast >= giveUpAfter { return .giveUp }
        return .wait
    }
}
