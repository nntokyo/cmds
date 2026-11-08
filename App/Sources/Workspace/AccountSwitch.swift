import Foundation
import CmdsCore

/// An account switch offered or in progress in a pane (`Pane.accountSwitch`, AppController+AccountSwitch).
struct AccountSwitch {
    enum Phase: Equatable {
        /// Shown in the pane's banner and notified; waits for the user. `problem`: why it cannot switch now.
        case offered(problem: AccountSwitchProblem?)
        /// Asked for (button, notification, `account.switch`, automatic): waits for Claude Code to sit idle.
        case waitingForIdle
        /// A double Ctrl-C sent; waits for the shell to come back.
        case quitting
    }

    /// The account that hit its limit (nil: not one of the user's accounts).
    var from: String?
    /// The account to continue with; nil when none is free.
    var to: String?
    var session: AgentSession?
    var phase: Phase
    /// Attempts to quit (a double Ctrl-C each), and when the last one was.
    var quitAttempts = 0
    var lastQuitAt: Date?
    /// The pane's screen while waiting for idle, and since when it has looked like that.
    var screen = ScreenStability()

    var isInProgress: Bool { phase == .waitingForIdle || phase == .quitting }

    /// How the account that hit its limit is named to the user: its name, else Claude Code itself.
    static func displayName(_ account: String?) -> String { account ?? "Claude Code" }
}

/// Why a pane cannot move to another account now.
enum AccountSwitchProblem: Equatable {
    case notLocal
    case noSession
    case noOtherAccount
    case notShared(account: String)
    case didNotQuit

    /// Sharing the sessions (Settings › Claude Accounts) would solve it.
    var needsSharing: Bool {
        if case .notShared = self { return true }
        return false
    }

    /// For the API and CLI (English, docs/internals/localization.md).
    var english: String {
        switch self {
        case .notLocal: return "accounts are for local terminal panes, not SSH panes"
        case .noSession: return "no Claude Code session id is known for this pane (add `cmds hook claude-status` to the status line in the account's settings.json)"
        case .noOtherAccount: return "every other account has hit its limit (or there is no other account)"
        case .notShared(let account): return "the session's transcript is not reachable from account \(account): share sessions first (cmds accounts share)"
        case .didNotQuit: return "Claude Code did not quit (Ctrl-C); quit it yourself and run cmds accounts switch again"
        }
    }

    var localized: String {
        switch self {
        case .notLocal: return String(localized: "Accounts are for local terminal panes, not SSH panes.")
        case .noSession: return String(localized: "The session id is not known: add cmds hook claude-status to the status line in this account’s settings.json.")
        case .noOtherAccount: return String(localized: "Every other account has hit its limit.")
        case .notShared(let account): return String(localized: "The session cannot be reached from “\(account)”: share sessions in Settings › Claude Accounts first.")
        case .didNotQuit: return String(localized: "Claude Code did not quit. Quit it yourself, then try again.")
        }
    }
}
