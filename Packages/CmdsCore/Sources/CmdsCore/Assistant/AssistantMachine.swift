import Foundation

/// The assistant's state as the HUD shows it, and the rules between hearing, answering and confirming (#243).
/// The app feeds it utterances, answers, the end of speech, keys and a clock tick, and does what the returned step
/// says; nothing here touches audio or panes.
///
/// The microphone stays open while the assistant thinks and speaks, so the user can interrupt it by name (barge-in):
/// then only an utterance that starts with the name counts, and nothing that is mostly what the assistant itself just
/// said (`AssistantEcho`). Each request has a number (`request`); a late answer for an older one is dropped.
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
        /// The name alone: show that it listens. Stops what the assistant was saying or working out.
        case wake
        /// Plan and answer this (a new `request`). Stops what the assistant was saying or working out.
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
    /// The window was opened by an answer (only short follow-ups count), not by the hotkey or the name alone.
    public private(set) var followUpAfterAnswer = false
    /// Utterances before this need the name: the assistant's own voice may still be trailing off.
    public private(set) var deafUntil: Date?
    /// The number of the request being worked on; answers for another one are dropped.
    public private(set) var request = 0
    /// What the assistant said last, while it says it and `echoMemory` after (its own voice, if heard, is dropped).
    public private(set) var spoken: String?
    /// The assistant's voice is on (an answer, or a note while a card waits).
    public private(set) var voiceActive = false
    /// When the assistant last stopped speaking.
    public private(set) var spokeUntil: Date?

    /// A command without the name counts this long after the assistant finished speaking or the hotkey was pressed.
    public static let followUpWindow: TimeInterval = 8
    /// An unconfirmed action is dropped after this.
    public static let confirmationTimeout: TimeInterval = 60
    /// After the assistant finished speaking, utterances need the name this long (its own voice trailing off).
    public static let echoGuard: TimeInterval = 1.0
    /// A transcript that is mostly what the assistant said is dropped up to this long after it finished (speech
    /// recognition can deliver a long utterance seconds late).
    public static let echoMemory: TimeInterval = 30
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
        followUpAfterAnswer = false
        deafUntil = nil
        spoken = nil
        voiceActive = false
        spokeUntil = nil
        request += 1
        pausedBeforeHotkey = false
    }

    /// Where it rests: listening for the name, or paused again after a command taken by the hotkey.
    private var restingPhase: Phase { pausedBeforeHotkey ? .paused : .idle }

    /// The hotkey: the next utterance is a command (also while paused, for that one command). Stops what the assistant
    /// was saying or working out.
    public mutating func hotkey(now: Date) {
        guard phase != .off, phase != .confirming else { return }
        if phase == .paused { pausedBeforeHotkey = true }
        if phase == .thinking || phase == .speaking { request += 1 }
        if pending != nil, phase == .speaking {
            phase = .confirming
        } else {
            phase = .listening
        }
        stopVoice(now: now)
        deafUntil = nil
        followUpUntil = now.addingTimeInterval(Self.followUpWindow)
        followUpAfterAnswer = false
    }

    // MARK: Hearing

    /// A finished utterance. Addressed ones are kept as `transcript`; others change nothing.
    public mutating func hear(_ utterance: String, names: [String], now: Date) -> Step {
        guard phase != .off, phase != .paused else { return .ignore }
        if isEcho(utterance, now: now) { return .ignore }
        // While it thinks or speaks, and just after, only its name gets through (barge-in).
        let busy = phase == .thinking || phase == .speaking || voiceActive || (deafUntil.map { now < $0 } ?? false)
        let windowOpen = followUpUntil.map { now <= $0 } ?? false
        let followUpOpen = !busy && (phase == .confirming
            || (windowOpen && (!followUpAfterAnswer || AssistantAddressing.isShortFollowUp(utterance))))
        switch AssistantAddressing.check(utterance, names: names, followUpOpen: followUpOpen) {
        case .ignored:
            return .ignore
        case .wake:
            if phase == .confirming { return .ignore }
            if phase == .thinking || phase == .speaking { request += 1 }
            stopVoice(now: now)
            deafUntil = nil
            followUpUntil = now.addingTimeInterval(Self.followUpWindow)
            followUpAfterAnswer = false
            // A card being read out stays; the name alone only stops the voice.
            phase = pending != nil && phase == .speaking ? .confirming : .listening
            return .wake
        case .command(let text, let byName):
            let intent = AssistantIntent.parse(text)
            if let pending, phase == .confirming || phase == .speaking {
                switch intent {
                case .confirm:
                    transcript = text
                    stopVoice(now: now)
                    guard pending.confirmation == .voiceOrKey else {
                        phase = .confirming
                        return .needsKey
                    }
                    return execute()
                case .cancel:
                    transcript = text
                    stopVoice(now: now)
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
            followUpAfterAnswer = false
            stopVoice(now: now)
            deafUntil = nil
            request += 1
            return .handle(intent)
        }
    }

    /// Whether `utterance` is the assistant's own voice: mostly what it is saying or said a moment ago.
    public func isEcho(_ utterance: String, now: Date) -> Bool {
        guard let spoken else { return false }
        let recent = voiceActive || (spokeUntil.map { now <= $0.addingTimeInterval(Self.echoMemory) } ?? false)
        return recent && AssistantEcho.isEcho(utterance, of: spoken)
    }

    // MARK: Answering

    /// The answer is ready: it is spoken now; `action` waits for confirmation. `request`: the request it answers;
    /// false (and nothing changes) when the user has moved on to another one since.
    @discardableResult
    public mutating func answer(_ text: String, proposing action: AssistantAction? = nil, request: Int? = nil, now: Date) -> Bool {
        guard phase != .off else { return false }
        if let request, request != self.request { return false }
        answer = text
        pending = action
        pendingUntil = action.map { _ in now.addingTimeInterval(Self.confirmationTimeout) }
        phase = .speaking
        voiceStarted(text)
        return true
    }

    /// The answer has been spoken (or speech is muted): wait for a follow-up or the confirmation. The follow-up window
    /// starts now, when the voice stops.
    public mutating func speechFinished(now: Date) {
        guard phase == .speaking else { return }
        phase = pending == nil ? .listening : .confirming
        followUpUntil = now.addingTimeInterval(Self.followUpWindow)
        followUpAfterAnswer = true
        voiceFinished(now: now)
    }

    /// The voice starts saying `text` (an answer, or a note that changes no state).
    public mutating func voiceStarted(_ text: String) {
        spoken = text
        voiceActive = true
        spokeUntil = nil
    }

    /// The voice stopped.
    public mutating func voiceFinished(now: Date) {
        guard voiceActive else { return }
        voiceActive = false
        spokeUntil = now
        deafUntil = now.addingTimeInterval(Self.echoGuard)
    }

    /// The voice is cut off (barge-in, a new request): what it said is still remembered as its own.
    private mutating func stopVoice(now: Date) {
        guard voiceActive else { return }
        voiceActive = false
        spokeUntil = now
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
            followUpAfterAnswer = false
        }
        return .ignore
    }

    private mutating func execute() -> Step {
        guard let action = pending else { return .ignore }
        pending = nil
        pendingUntil = nil
        phase = .thinking
        request += 1
        return .execute(action)
    }

    private mutating func cancel() -> Step {
        pending = nil
        pendingUntil = nil
        phase = .thinking
        request += 1
        return .cancelled
    }

    /// Back to listening for the name (after an action ran without anything to say).
    public mutating func settle() {
        guard phase == .thinking else { return }
        phase = restingPhase
        pausedBeforeHotkey = false
    }
}
