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
    /// Claude Code runs in the pane but does not report (#360): `configDir` (abbreviated) has no cmds status line.
    case notReporting(configDir: String)
    case noOtherAccount
    case notShared(account: String)
    /// `account` is signed in to the same Claude account as the pane's: the limit is the same one.
    case sameSignIn(account: String)
    /// `account`'s config directory does not exist yet: nobody signed in there.
    case notSignedIn(account: String)
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
        case .notReporting(let dir): return "Claude Code in this pane does not report to cmds: \(dir)/settings.json has no `cmds hook claude-status` status line (set it up: cmds accounts setup NAME, after cmds accounts add NAME \(dir) if it is no account)"
        case .noOtherAccount: return "every other account has hit its limit (or there is no other account)"
        case .notShared(let account): return "the session's transcript is not reachable from account \(account): share sessions first (cmds accounts share)"
        case .sameSignIn(let account): return "account \(account) is signed in to the same Claude account, so it has the same limit (sign it in to another one: cmds accounts login \(account))"
        case .notSignedIn(let account): return "account \(account) is not signed in yet (its config directory does not exist): cmds accounts login \(account)"
        case .didNotQuit: return "Claude Code did not quit (Ctrl-C); quit it yourself and run cmds accounts switch again"
        }
    }

    var localized: String {
        switch self {
        case .notLocal: return String(localized: "Accounts are for local terminal panes, not SSH panes.")
        case .noSession: return String(localized: "The session id is not known: add cmds hook claude-status to the status line in this account’s settings.json.")
        case .notReporting(let dir): return String(localized: "Claude Code here does not report to cmds: \(dir) is not set up for cmds. Set it up in Settings › Claude Accounts (add the folder as an account if it is none).")
        case .noOtherAccount: return String(localized: "Every other account has hit its limit.")
        case .notShared(let account): return String(localized: "The session cannot be reached from “\(account)”: share sessions in Settings › Claude Accounts first.")
        case .sameSignIn(let account): return String(localized: "“\(account)” is signed in to the same Claude account, so it has the same limit. Sign it in to another account (the account menu’s Sign In).")
        case .notSignedIn(let account): return String(localized: "“\(account)” is not signed in yet. Sign in first (the account menu’s Sign In).")
        case .didNotQuit: return String(localized: "Claude Code did not quit. Quit it yourself, then try again.")
        }
    }
}
