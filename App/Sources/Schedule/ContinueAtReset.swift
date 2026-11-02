import AppKit
import CmdsCore

/// The limit banner's "Continue at 15:01" and the notification's "Continue When It Resets": when every other account
/// is limited too (`AccountSwitchProblem.noOtherAccount`), a `limitReset` + `continueSession` schedule types
/// "continue" into the pane's session once its account's limit resets.
extension AppController {
    /// The delay after the reset.
    static let continueAtResetDelay = ScheduleLimits.defaultDelay

    /// When the "continue" would run, or nil when the pane cannot have one (no local Claude Code session, the account
    /// is not one of the user's, or it is not limited).
    func continueAtResetTime(_ pane: Pane, now: Date = Date()) -> Date? {
        guard pane.ssh == nil, continuableSession(pane) != nil,
              let name = pane.accountSwitch?.from ?? currentAccount(of: pane),
              let limit = claudeAccounts.account(named: name)?.limit, limit.isActive(at: now) else { return nil }
        return limit.resetsAt.addingTimeInterval(Self.continueAtResetDelay)
    }

    /// Creates the schedule (once per session and account), dismisses the banner and says when it runs.
    func continueWhenLimitResets(_ pane: Pane) {
        guard let session = continuableSession(pane), let at = continueAtResetTime(pane),
              let account = pane.accountSwitch?.from ?? currentAccount(of: pane) else { return }
        let runner = scheduleRunner
        let existing = runner.schedules.first { schedule in
            guard schedule.enabled, case .limitReset(let name, _) = schedule.trigger,
                  case .continueSession(let action) = schedule.action else { return false }
            return name.caseInsensitiveCompare(account) == .orderedSame && action.sessionID == session.sessionID
        }
        if existing == nil {
            let title = AgentResume.cleanTitle(session.title) ?? String(session.sessionID.prefix(8))
            let draft = ScheduleDraft(name: String(String(localized: "Continue “\(title)”").prefix(ScheduleLimits.maxNameLength)),
                                      trigger: .limitReset(account: account, delay: Self.continueAtResetDelay),
                                      action: .continueSession(ContinueSession(sessionID: session.sessionID, cwd: session.cwd)))
            do {
                try runner.add(draft, origin: .app)
            } catch {
                raiseAttention(pane: pane, title: String(localized: "Schedules"),
                               body: (error as? RPCError)?.message ?? "\(error)")
                return
            }
        }
        dismissAccountSwitch(pane)
        try? setStatus(workspaceID: pane.workspaceID,
                       text: String(localized: "Continues at \(at.formatted(date: .omitted, time: .shortened)) (Window › Schedules)"))
    }

    /// The local Claude Code session the banner is about.
    private func continuableSession(_ pane: Pane) -> AgentSession? {
        let session = [pane.accountSwitch?.session, pane.agentSession, pane.resumeOffer].compactMap { $0 }
            .first { $0.agent == .claude }
        guard let session, session.host == nil, AgentResume.isValidSessionID(session.sessionID) else { return nil }
        return session
    }
}
