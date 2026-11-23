import Foundation

/// A notification when a long command finishes in a pane you are not looking at (the shell integration's OSC 133
/// marks; libghostty's `command_finished` with the exit code and duration): a build, a test run or a deploy you
/// switched away from.
public enum LongCommand {
    /// Settings › General › Terminal choices, in seconds (0: off); default `defaultSeconds`.
    public static let choices = [0, 10, 30, 60, 300]
    public static let defaultSeconds = 30

    /// Whether the end of a command that ran `duration` seconds is worth a notification. Not for a pane you look at,
    /// nor one where a coding agent runs (its hooks notify already; its own commands would be noise).
    public static func notifies(duration: TimeInterval, threshold: Int, visible: Bool, agentRunning: Bool) -> Bool {
        threshold > 0 && duration >= TimeInterval(threshold) && !visible && !agentRunning
    }

    /// libghostty's report: `exitCode` -1 when the shell gave none; `nanoseconds` the time it ran.
    public static func finish(exitCode: Int, nanoseconds: UInt64) -> (exitCode: Int?, duration: TimeInterval) {
        (exitCode < 0 ? nil : exitCode, TimeInterval(nanoseconds) / 1_000_000_000)
    }
}
