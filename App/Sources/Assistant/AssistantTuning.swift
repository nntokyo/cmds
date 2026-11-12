import Foundation

/// The voice assistant's timings and caps in the app (#243), in one place. Those of its rules are with the rules in
/// CmdsCore (`AssistantMachine.followUpWindow` and `confirmationTimeout`, `AssistantPlanner.maxSessions`,
/// `AssistantTaskWatch.lifetime`, …).
enum AssistantTuning {
    // MARK: Answers

    /// How long the on-device model may take.
    static let modelTimeout: Duration = .seconds(20)
    /// How long `claude -p` may take for a web answer or a detailed summary before it is stopped.
    static let claudeTimeout: TimeInterval = 90
    /// How long the interpreter may take (it is asked before anything is said).
    static let interpreterTimeout: TimeInterval = 30
    /// The on-device model is warmed up when speech begins at most this often (#248).
    static let prewarmInterval: TimeInterval = 30
    /// Rows of scrollback read from a pane for a summary.
    static let summaryScrollback = 120
    /// Screen text handed to the on-device model, from the end.
    static let maxScreenCharacters = 6000
    /// Screen text handed to `claude -p` for a detailed summary, from the end.
    static let maxDetailedScreenCharacters = 2 * maxScreenCharacters
    /// Lines above an agent's numbered choice checked for dangerous text (what a permission prompt asks about).
    static let promptContextLines = 16

    // MARK: Conversation

    /// A start without a place goes to the workspace the last request was about, for this long.
    static let recentFor: TimeInterval = 300

    // MARK: HUD and keys

    /// The HUD stays this long after the assistant went back to standing by.
    static let hudLinger: TimeInterval = 6
    /// Return / Esc are ignored this long after a card appears (a Return already on its way to the terminal).
    static let confirmArmDelay: TimeInterval = 0.8
    /// The clock that expires cards, closes the follow-up window and says follow-through lines.
    static let tickInterval: TimeInterval = 0.5

    // MARK: Microphone

    /// Frames per buffer the microphone tap delivers.
    static let tapBufferSize: UInt32 = 2048
    /// The input level is reported at most this often (20 times a second).
    static let levelInterval: TimeInterval = 0.05
    /// RMS scaled up for display (speech is far below full scale).
    static let levelGain: Float = 12
}
