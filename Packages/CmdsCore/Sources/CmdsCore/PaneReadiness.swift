import Foundation

/// When cmds may type into a terminal pane by itself: a resume command (AppController+AgentSessions), the Ctrl-C of an
/// account switch (AppController+AccountSwitch) and a schedule run's command and prompt (`ScheduleRunTiming`). Pure
/// rules, unit-tested; the app builds a `PaneObservation` of the pane and asks these.
///
/// - Shell input only at an empty prompt (the cursor right after the prompt, nothing typed) whose screen has settled.
/// - Agent input only when the agent is in the foreground, not working, runs no subagent and its screen has not changed
///   for `agentIdleTime`.
public enum PaneReadiness {
    /// A local terminal's foreground process is read only after this long (its shell is still starting).
    public static let localStartDelay: TimeInterval = 0.8
    /// An SSH pane's prompt is looked at only after this long after its terminal started.
    public static let sshStartDelay: TimeInterval = 1.5
    /// The prompt's screen must not change for this long before a shell command is typed.
    public static let promptSettleTime: TimeInterval = 0.4
    /// The same for an SSH pane whose remote shell has not reported its prompt (`remote.location`).
    public static let unreportedPromptSettleTime: TimeInterval = 1.5
    /// The screen must not change for this long before an agent counts as idle.
    public static let agentIdleTime: TimeInterval = ClaudeAccountSwitchTiming.idleTime
    /// The same for Codex, which raises no hooks in cmds: its working line counts seconds, so a screen that has not
    /// changed for this long is not working.
    public static let codexIdleTime: TimeInterval = 5
    /// How many of the screen's last non-blank lines `showsWorking` looks at (the agent's status and input area).
    static let workingLines = 8

    /// The cursor sits right after a shell prompt with nothing typed (`AgentResume.isAtEmptyPrompt`), on a screen that
    /// is not blank.
    public static func isAtEmptyPrompt(screen: String, cursor: (row: Int, col: Int)?) -> Bool {
        !isBlank(screen) && AgentResume.isAtEmptyPrompt(screen: screen, cursor: cursor)
    }

    public static func isBlank(_ screen: String) -> Bool {
        screen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A shell is in the foreground, waiting at an empty prompt that has settled.
    public static func isShellReady(_ o: PaneObservation) -> Bool {
        o.foreground == .shell && o.atEmptyPrompt && o.screenUnchangedFor >= promptSettleTime
    }

    /// The agent may get input (a prompt, a Ctrl-C): `ClaudeAccountSwitchTiming.isIdle`.
    public static func isAgentIdle(_ o: PaneObservation) -> Bool {
        ClaudeAccountSwitchTiming.isIdle(agentInForeground: o.foreground == .agent, busy: o.activity == .busy,
                                         subagentRunning: o.subagentRunning, screenUnchangedFor: o.screenUnchangedFor)
    }

    /// Codex may get a prompt (conservative; Codex has no hooks in cmds). All of:
    /// - Codex is the foreground process and its session file is matched to the pane (`sessionReported`), so its
    ///   writes are seen;
    /// - not busy: no write to its session file for `AgentSignals.reportBusyTimeout` (it appends while it works);
    /// - the screen has not changed for `codexIdleTime`.
    /// The caller also checks the screen (`showsWorking`, `ScheduleRunTiming.showsChoice`) and `.needsInput`.
    public static func isCodexIdle(_ o: PaneObservation, sessionReported: Bool) -> Bool {
        o.foreground == .agent && sessionReported && o.activity != .busy && !o.subagentRunning
            && o.screenUnchangedFor >= codexIdleTime
    }

    /// The last lines of an agent's screen show it working: Claude Code and Codex both show "esc to interrupt" next
    /// to their working indicator. Only the bottom lines count (older output higher up may quote the words).
    public static func showsWorking(screen: String) -> Bool {
        let lines = screen.split(separator: "\n").filter { !$0.allSatisfy(\.isWhitespace) }.suffix(workingLines)
        return lines.contains { $0.lowercased().contains("esc to interrupt") }
    }

    // MARK: Resuming a session

    public enum ResumeStep: Equatable, Sendable {
        case wait
        /// Type the resume command now.
        case ready
        /// An agent runs in the pane: never type over it (the offer is moot).
        case agentRunning
    }

    /// An SSH pane, for `resumeGate` / `resumeStep`.
    public struct Remote: Equatable, Sendable {
        public var connected: Bool
        /// Since the pane's terminal started.
        public var sinceStart: TimeInterval
        /// The remote shell reported its prompt since the terminal started.
        public var promptReported: Bool

        public init(connected: Bool, sinceStart: TimeInterval, promptReported: Bool) {
            self.connected = connected
            self.sinceStart = sinceStart
            self.promptReported = promptReported
        }
    }

    /// Before the screen is looked at: whether the pane can take a resume command at all. nil = look at its prompt
    /// (`resumeStep`). `agentReported`: an agent reports its usage in the pane. `foreground` is read for local panes
    /// only (`remote` nil).
    public static func resumeGate(foreground: PaneForeground, agentReported: Bool, remote: Remote?) -> ResumeStep? {
        if agentReported { return .agentRunning }
        if let remote { return remote.connected && remote.sinceStart >= sshStartDelay ? nil : .wait }
        switch foreground {
        case .agent: return .agentRunning
        case .shell: return nil
        case .unknown, .other: return .wait
        }
    }

    /// Past the gate: the resume command is typed at an empty prompt that has settled. A remote prompt report only
    /// shortens the wait on an SSH pane.
    public static func resumeStep(_ o: PaneObservation, remote: Remote?) -> ResumeStep {
        guard o.atEmptyPrompt else { return .wait }
        let settle = remote.map { $0.promptReported ? promptSettleTime : unreportedPromptSettleTime } ?? promptSettleTime
        return o.screenUnchangedFor >= settle ? .ready : .wait
    }
}

/// What runs in the foreground of a pane's terminal.
public enum PaneForeground: Equatable, Sendable {
    /// Not known (the terminal is starting, an SSH pane, or the process could not be read).
    case unknown
    case shell
    /// Claude Code or Codex.
    case agent
    case other
}

/// What the app sees in a terminal pane before typing into it (`PaneReadiness`).
public struct PaneObservation: Equatable, Sendable {
    public var foreground: PaneForeground = .unknown
    /// Any Claude Code / Codex process on the pane's terminal (also in the background).
    public var agentOnTerminal = false
    public var activity: AgentActivity = .none
    public var subagentRunning = false
    /// How long the screen has looked like this (`ScreenStability`).
    public var screenUnchangedFor: TimeInterval = 0
    /// The cursor sits right after a prompt with nothing typed (`PaneReadiness.isAtEmptyPrompt`).
    public var atEmptyPrompt = false

    public init(foreground: PaneForeground = .unknown, agentOnTerminal: Bool = false, activity: AgentActivity = .none,
                subagentRunning: Bool = false, screenUnchangedFor: TimeInterval = 0, atEmptyPrompt: Bool = false) {
        self.foreground = foreground
        self.agentOnTerminal = agentOnTerminal
        self.activity = activity
        self.subagentRunning = subagentRunning
        self.screenUnchangedFor = screenUnchangedFor
        self.atEmptyPrompt = atEmptyPrompt
    }
}

/// A pane's screen text and since when it has looked like that.
public struct ScreenStability: Equatable, Sendable {
    public private(set) var screen: String?
    public private(set) var since: Date?

    public init() {}

    /// Records the screen seen at `now`; returns how long it has looked like that (0 when it just changed).
    @discardableResult
    public mutating func update(_ screen: String, at now: Date) -> TimeInterval {
        if screen != self.screen {
            self.screen = screen
            since = now
        }
        return now.timeIntervalSince(since ?? now)
    }

    /// Forgets the screen: the next one counts as a change.
    public mutating func reset() {
        screen = nil
        since = nil
    }
}
