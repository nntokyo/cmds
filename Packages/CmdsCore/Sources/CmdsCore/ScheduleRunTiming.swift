import Foundation

/// When a schedule run may type into its pane, and when it gives up (docs/guide/schedules.md "Safety"). Pure rules,
/// unit-tested; the app's ScheduleRunner builds an `Observation` of the pane on every tick and does what `step` says.
///
/// Safety rules kept here:
/// - Shell input only at a settled empty prompt of a shell in the foreground (`PaneReadiness.isShellReady`), with no
///   agent on the terminal.
/// - A prompt goes into Claude Code only when it is idle (`PaneReadiness.isAgentIdle`), not asking for input or
///   permission, with no account switch in progress and no resume queued, and only into the expected session.
/// - Type once: every typing step moves the run on; nothing is retried.
public enum ScheduleRunTiming {
    /// How often active runs are checked.
    public static let tickInterval: TimeInterval = ClaudeAccountSwitchTiming.tickInterval
    /// Waiting for a shell prompt.
    public static let shellReadyTimeout: TimeInterval = 60
    /// Waiting for Claude Code to start after its command was typed.
    public static let agentStartTimeout: TimeInterval = 120
    /// Waiting for a busy Claude Code to become idle.
    public static let idleWait: TimeInterval = 30 * 60
    /// Waiting for a limited account's reset.
    public static let accountWait: TimeInterval = 8 * 3600
    /// Waiting to see Claude Code start working after Return.
    public static let confirmTimeout: TimeInterval = 20
    /// The prompt's screen must not change for this long before typing a command.
    public static let shellSettleTime: TimeInterval = PaneReadiness.promptSettleTime
    /// Between pasting a prompt and pressing Return.
    public static let enterDelay: TimeInterval = 0.4
    /// A pane the run did not create that runs another program this long is left alone (skipped).
    public static let otherProgramGrace: TimeInterval = 3

    /// What runs in the foreground of the pane's terminal.
    public typealias Foreground = PaneForeground

    /// What the app sees in the run's pane: the `PaneObservation` every typing check uses (its fields are read and
    /// written as the observation's own, `o.foreground`), plus what only a run looks at.
    @dynamicMemberLookup
    public struct Observation: Equatable, Sendable {
        public var pane = PaneObservation()
        public var paneExists = true
        /// The agent reports itself as Codex (prompts go to Claude Code only).
        public var otherAgent = false
        /// The session id Claude Code reports in the pane (status line), if any.
        public var sessionID: String?
        /// The run's account is limited now; `accountFreeIn` is how long until its (or, with `auto`, the earliest)
        /// reset.
        public var accountLimited = false
        public var accountFreeIn: TimeInterval?
        public var accountSwitchInProgress = false
        public var resumeQueued = false
        /// Claude Code shows a choice (a permission prompt, the folder trust question): `showsChoice(screen:)`.
        public var choiceOnScreen = false
        /// After Return: Claude Code was seen working (busy, or its `UserPromptSubmit` hook).
        public var promptSubmitted = false

        public init() {}

        public subscript<Value>(dynamicMember keyPath: WritableKeyPath<PaneObservation, Value>) -> Value {
            get { pane[keyPath: keyPath] }
            set { pane[keyPath: keyPath] = newValue }
        }
    }

    /// What the run expects of its pane.
    public struct Expectation: Equatable, Sendable {
        /// The session the prompt is for; nil = whatever Claude Code the run started.
        public var sessionID: String?
        /// The run typed (or a queued resume will type) the command that starts the agent, so it may take
        /// `agentStartTimeout` to appear.
        public var startsAgent: Bool
        /// The run created the pane (else it is the user's pane holding the session).
        public var ownsPane: Bool

        public init(sessionID: String? = nil, startsAgent: Bool = false, ownsPane: Bool = false) {
            self.sessionID = sessionID
            self.startsAgent = startsAgent
            self.ownsPane = ownsPane
        }
    }

    public enum Step: Equatable, Sendable {
        case wait
        /// The account is free: go on to the pane.
        case proceed
        /// Type the shell command (with Return) now.
        case type
        /// Paste the prompt now.
        case paste
        /// Press Return now.
        case enter
        case succeed(ScheduleReason)
        case fail(ScheduleReason)
        case skip(ScheduleReason)
    }

    /// The next step of a run in `state`, which it entered `elapsed` ago.
    public static func step(state: ScheduleRunState, observation o: Observation, elapsed: TimeInterval,
                            expect: Expectation = Expectation()) -> Step {
        switch state {
        case .waitingForAccount:
            guard o.accountLimited else { return .proceed }
            guard let freeIn = o.accountFreeIn, elapsed + freeIn <= accountWait else { return .fail(.accountStillLimited) }
            return .wait
        case .waitingForPane:
            return shellStep(o, elapsed: elapsed, expect: expect)
        case .waitingForAgent:
            return agentStep(o, elapsed: elapsed, expect: expect)
        case .typing:
            guard o.paneExists else { return .fail(.paneClosed) }
            // Return goes only to the Claude Code that got the paste.
            guard o.foreground == .agent else { return .fail(.agentNotRunning) }
            return elapsed >= enterDelay ? .enter : .wait
        case .confirming:
            if o.promptSubmitted { return .succeed(.confirmed) }
            return elapsed >= confirmTimeout || !o.paneExists ? .succeed(.unconfirmed) : .wait
        case .succeeded, .failed, .skipped, .missed, .cancelled:
            return .wait
        }
    }

    private static func shellStep(_ o: Observation, elapsed: TimeInterval, expect: Expectation) -> Step {
        guard o.paneExists else { return .fail(.paneClosed) }
        // Never type a command into a running agent.
        if o.foreground == .agent || o.agentOnTerminal { return .skip(.agentRunning) }
        let timedOut = elapsed >= shellReadyTimeout
        switch o.foreground {
        case .unknown:
            return timedOut ? .fail(.shellNotReady) : .wait
        case .other:
            if !expect.ownsPane, elapsed >= otherProgramGrace { return .skip(.otherProgram) }
            return timedOut ? (expect.ownsPane ? .fail(.shellNotReady) : .skip(.otherProgram)) : .wait
        case .agent:
            return .skip(.agentRunning)
        case .shell:
            let ready = PaneReadiness.isShellReady(o.pane) && !o.resumeQueued && !o.accountSwitchInProgress
            if ready { return .type }
            return timedOut ? (expect.ownsPane ? .fail(.shellNotReady) : .skip(.otherProgram)) : .wait
        }
    }

    private static func agentStep(_ o: Observation, elapsed: TimeInterval, expect: Expectation) -> Step {
        guard o.paneExists else { return .fail(.paneClosed) }
        if o.otherAgent { return .skip(.notClaude) }
        let agentUp = o.foreground == .agent
        guard agentUp else {
            // Still starting (or a queued resume has not typed yet).
            if expect.startsAgent || o.resumeQueued {
                return elapsed >= agentStartTimeout ? .fail(.agentDidNotStart) : .wait
            }
            return o.foreground == .shell && !o.agentOnTerminal ? .skip(.agentNotRunning) : .skip(.otherProgram)
        }
        if let expected = expect.sessionID {
            if let seen = o.sessionID {
                if seen != expected { return .skip(.differentSession) }
            } else {
                // Typing only into the session the run is for: wait for Claude Code to report it.
                return elapsed >= agentStartTimeout ? .fail(.agentDidNotStart) : .wait
            }
        }
        if PaneReadiness.isAgentIdle(o.pane), o.activity != .needsInput, !o.choiceOnScreen, !o.accountSwitchInProgress, !o.resumeQueued { return .paste }
        return elapsed >= idleWait ? .fail(.agentBusy) : .wait
    }

    /// Claude Code shows a numbered choice with its selection marker (`❯ 1. Yes`): a permission prompt or a question
    /// such as "Do you trust the files in this folder?". Pasting and Return would answer it, so the run waits.
    /// Some of these raise no `Notification` hook (the trust question comes before any hook runs).
    public static func showsChoice(screen: String) -> Bool {
        screen.split(separator: "\n").contains { line in
            let trimmed = line.drop { $0 == " " || $0 == "│" || $0 == "┃" || $0 == "|" }
            guard let marker = trimmed.first, marker == "❯" || marker == ">" || marker == "›" else { return false }
            let rest = trimmed.dropFirst().drop { $0 == " " }
            guard let digit = rest.first, digit.isNumber else { return false }
            return rest.dropFirst().hasPrefix(".")
        }
    }

    /// The account to wait for with `auto`: none is free; `resets` are the accounts' reset times. nil = no account
    /// frees up within `accountWait` from `now`, so the run is skipped at once.
    public static func autoAccountFreeIn(resets: [Date], now: Date) -> TimeInterval? {
        guard let earliest = resets.min() else { return nil }
        let wait = max(0, earliest.timeIntervalSince(now))
        return wait <= accountWait ? wait : nil
    }
}
