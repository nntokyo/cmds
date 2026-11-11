import Foundation

/// Which utterance the assistant's voice is speaking and whom to tell when it ends (#261). Each utterance gets a
/// number; the synthesizer's end callbacks (didFinish / didCancel, delivered later on the main queue) end it only if
/// it is still the current one, so a stopped utterance's late callback cannot end the next one (which would open the
/// follow-up window and start the echo guard while the next answer is still being said). Stopping ends the current
/// one at once. Each completion runs at most once.
public struct AssistantUtterances<Completion> {
    public private(set) var current: Int?
    private var completion: Completion?
    private var last = 0

    public init() {}

    /// A new utterance (stop the previous one first): its number, for the synthesizer's callbacks.
    public mutating func start(_ completion: Completion) -> Int {
        last += 1
        current = last
        self.completion = completion
        return last
    }

    /// Stopped (barge-in, a new answer, turning off): the current utterance's completion, to run now.
    public mutating func stop() -> Completion? {
        current = nil
        defer { completion = nil }
        return completion
    }

    /// The synthesizer finished or cancelled utterance `number`: its completion if it is still the current one, else
    /// nil (stopped already, or an older one's late callback).
    public mutating func ended(_ number: Int) -> Completion? {
        guard number == current else { return nil }
        return stop()
    }
}
