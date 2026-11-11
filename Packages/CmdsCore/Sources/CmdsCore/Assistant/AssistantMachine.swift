import Foundation

/// The assistant's state as the HUD shows it, and the rules between hearing, answering and confirming (#243).
/// The app feeds it utterances, answers, the end of speech, keys and a clock tick, and does what the returned step
/// says; nothing here touches audio or panes.
public struct AssistantMachine: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        /// The assistant is off (the microphone too).
        case off
        /// On, microphone paused ("Pause listening").
        case paused
        /// Listening for its name.
        case idle
        /// Addressed (name alone, hotkey, after an answer): the next utterance is a command without the name.
        case listening
        /// Working out an answer.
        case thinking
        /// Saying the answer.
        case speaking
        /// An action is shown and waits for yes / Return or no / Esc.
        case confirming
    }

    /// What the app must do after an input.
    public enum Step: Equatable, Sendable {
        /// Nothing (not addressed, or not now): drop the utterance.
        case ignore
        /// The name alone: show that it listens.
        case wake
        /// Plan and answer this.
        case handle(AssistantIntent)
        /// The user confirmed: carry it out.
        case execute(AssistantAction)
        /// The user said no (or pressed Esc).
        case cancelled
        /// A spoken yes to an action that needs Return or a click.
        case needsKey
        /// The pending action timed out.
        case expired
    }

    public enum Key: Equatable, Sendable {
        /// Return or the confirm button.
        case confirm
        /// Esc or the cancel button.
        case cancel
    }

    public private(set) var phase: Phase = .off
    /// The last command addressed to the assistant (never what was not addressed to it).
    public private(set) var transcript: String?
    /// The last answer.
    public private(set) var answer: String?
    /// The action waiting for confirmation.
    public private(set) var pending: AssistantAction?
    public private(set) var pendingUntil: Date?
    /// Until when a command needs no name.
    public private(set) var followUpUntil: Date?
    /// Utterances before this are the assistant's own voice trailing off.
    public private(set) var deafUntil: Date?

    /// A command without the name counts this long after the assistant spoke or the hotkey was pressed.
    public static let followUpWindow: TimeInterval = 8
    /// An unconfirmed action is dropped after this.
    public static let confirmationTimeout: TimeInterval = 60
    /// Utterances ending this soon after the assistant spoke are ignored (its own voice).
    public static let echoGuard: TimeInterval = 0.6
    /// The hotkey was pressed while paused: back to paused after that one command.
    private var pausedBeforeHotkey = false

    public init() {}

    public var isOn: Bool { phase != .off }

    // MARK: On, off, pause

    public mutating func turnOn() {
        guard phase == .off else { return }
        reset(to: .idle)
    }

    public mutating func turnOff() { reset(to: .off) }

    public mutating func pause() {
        guard phase != .off else { return }
        reset(to: .paused)
    }

    public mutating func resume() {
        guard phase == .paused else { return }
        reset(to: .idle)
    }

    private mutating func reset(to phase: Phase) {
        self.phase = phase
        transcript = nil
        answer = nil
        pending = nil
        pendingUntil = nil
        followUpUntil = nil
        deafUntil = nil
        pausedBeforeHotkey = false
    }

    /// Where it rests: listening for the name, or paused again after a command taken by the hotkey.
    private var restingPhase: Phase { pausedBeforeHotkey ? .paused : .idle }

    /// The hotkey: the next utterance is a command (also while paused, for that one command).
    public mutating func hotkey(now: Date) {
        guard phase != .off, phase != .confirming else { return }
        if phase == .paused { pausedBeforeHotkey = true }
        phase = .listening
        followUpUntil = now.addingTimeInterval(Self.followUpWindow)
    }

    // MARK: Hearing

    /// A finished utterance. Addressed ones are kept as `transcript`; others change nothing.
    public mutating func hear(_ utterance: String, names: [String], now: Date) -> Step {
        switch phase {
        case .off, .paused, .speaking, .thinking: return .ignore
        default: break
        }
        if let deafUntil, now < deafUntil { return .ignore }
        let followUpOpen = phase == .confirming || (followUpUntil.map { now <= $0 } ?? false)
        switch AssistantAddressing.check(utterance, names: names, followUpOpen: followUpOpen) {
        case .ignored:
            return .ignore
        case .wake:
            if phase == .confirming { return .ignore }
            phase = .listening
            followUpUntil = now.addingTimeInterval(Self.followUpWindow)
            return .wake
        case .command(let text, let byName):
            let intent = AssistantIntent.parse(text)
            if phase == .confirming, let pending {
                switch intent {
                case .confirm:
                    transcript = text
                    guard pending.confirmation == .voiceOrKey else { return .needsKey }
                    return execute()
                case .cancel:
                    transcript = text
                    return cancel()
                default:
                    // Without the name only yes / no count while an action waits; with it, a new command replaces it.
                    guard byName else { return .ignore }
                    self.pending = nil
                    pendingUntil = nil
                }
            }
            transcript = text
            answer = nil
            phase = .thinking
            followUpUntil = nil
            return .handle(intent)
        }
    }

    // MARK: Answering

    /// The answer is ready: it is spoken now; `action` waits for confirmation.
    public mutating func answer(_ text: String, proposing action: AssistantAction? = nil, now: Date) {
        guard phase != .off else { return }
        answer = text
        pending = action
        pendingUntil = action.map { _ in now.addingTimeInterval(Self.confirmationTimeout) }
        phase = .speaking
    }

    /// The answer has been spoken (or speech is muted): wait for a follow-up or the confirmation.
    public mutating func speechFinished(now: Date) {
        guard phase == .speaking else { return }
        phase = pending == nil ? .listening : .confirming
        followUpUntil = now.addingTimeInterval(Self.followUpWindow)
        deafUntil = now.addingTimeInterval(Self.echoGuard)
    }

    /// Return / Esc / the card's buttons. Works for every action (a key or click is always enough).
    public mutating func key(_ key: Key, now: Date) -> Step {
        guard pending != nil, phase == .confirming || phase == .speaking else { return .ignore }
        switch key {
        case .confirm: return execute()
        case .cancel: return cancel()
        }
    }

    /// Once a second: drop an action nobody confirmed, close the follow-up window.
    public mutating func tick(now: Date) -> Step {
        if pending != nil, let pendingUntil, now > pendingUntil, phase == .confirming {
            _ = cancel()
            return .expired
        }
        if phase == .listening, let followUpUntil, now > followUpUntil {
            phase = restingPhase
            pausedBeforeHotkey = false
            self.followUpUntil = nil
        }
        return .ignore
    }

    private mutating func execute() -> Step {
        guard let action = pending else { return .ignore }
        pending = nil
        pendingUntil = nil
        phase = .thinking
        return .execute(action)
    }

    private mutating func cancel() -> Step {
        pending = nil
        pendingUntil = nil
        phase = .thinking
        return .cancelled
    }

    /// Back to listening for the name (after an action ran without anything to say).
    public mutating func settle() {
        guard phase == .thinking else { return }
        phase = restingPhase
        pausedBeforeHotkey = false
    }
}
