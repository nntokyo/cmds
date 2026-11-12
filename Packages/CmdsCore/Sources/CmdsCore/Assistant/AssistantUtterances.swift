import Foundation

/// Which utterance the assistant's voice is speaking and whom to tell when it ends (#261). Each utterance gets a
/// number; the synthesizer's end callbacks (didFinish / didCancel, delivered later on the main queue) end it only if
/// it is still the current one, so a stopped utterance's late callback cannot end the next one (which would open the
/// follow-up window and start the echo guard while the next answer is still being said). Stopping ends the current
/// one at once. Each completion runs at most once.
///
/// An utterance may be said in parts (#248: an answer spoken sentence by sentence while the rest is still being
/// written): `open` at its start, more parts `add`ed under the same number, `close`d when no more come. It ends when
/// it is closed and every part has ended.
public struct AssistantUtterances<Completion> {
    public private(set) var current: Int?
    private var completion: Completion?
    private var last = 0
    /// Parts of the current utterance given to the synthesizer and not ended yet.
    private var parts = 0
    /// More parts may still come.
    public private(set) var isOpen = false

    public init() {}

    /// A new utterance (stop the previous one first, or let it be cut off: its callbacks no longer count): its
    /// number, for the synthesizer's callbacks. `open`: more parts may follow (`add`), until `close`.
    public mutating func start(_ completion: Completion, open: Bool = false) -> Int {
        last += 1
        current = last
        self.completion = completion
        parts = 1
        isOpen = open
        return last
    }

    /// Another part of the current utterance: its number, or nil when there is none.
    public mutating func add() -> Int? {
        guard current != nil else { return nil }
        parts += 1
        return current
    }

    /// No more parts: the completion to run now when every part has already ended.
    public mutating func close() -> Completion? {
        guard current != nil, isOpen else { return nil }
        isOpen = false
        return parts == 0 ? stop() : nil
    }

    /// Stopped (barge-in, a new answer, turning off): the current utterance's completion, to run now.
    public mutating func stop() -> Completion? {
        current = nil
        parts = 0
        isOpen = false
        defer { completion = nil }
        return completion
    }

    /// The synthesizer finished or cancelled a part of utterance `number`: its completion if it is still the current
    /// one and this was its last part (and it is closed), else nil (more to say, stopped already, or an older one's
    /// late callback).
    public mutating func ended(_ number: Int) -> Completion? {
        guard number == current else { return nil }
        parts = max(0, parts - 1)
        guard parts == 0, !isOpen else { return nil }
        return stop()
    }
}
