import Foundation

/// The last command that finished in a terminal pane, from the shell integration's OSC 133;D: what `pane.wait_command`,
/// `cmds wait` and MCP terminal_wait report, so a script or an agent that typed a command into a pane learns that it
/// ended and how, instead of reading the screen over and over.
public struct FinishedCommand: Codable, Equatable, Sendable {
    /// Counts the pane's finished commands from 1: wait for one after the number you saw.
    public var seq: Int
    /// nil when the shell did not give one.
    public var exitCode: Int?
    public var seconds: Double
    public var finishedAt: Date

    public init(seq: Int, exitCode: Int?, seconds: Double, finishedAt: Date) {
        self.seq = seq
        self.exitCode = exitCode
        self.seconds = seconds
        self.finishedAt = finishedAt
    }

    /// `pane.wait_command`'s default wait and its longest.
    public static let defaultTimeout: Double = 600
    public static let maxTimeout: Double = 3600

    /// "exit 1 after 12.3 s" / "exit 0 after 2 min 5 s".
    public var summary: String {
        let code = exitCode.map { "exit \($0)" } ?? "finished"
        let rounded = (seconds * 10).rounded() / 10
        let time = rounded < 60 ? "\(rounded) s" : "\(Int(rounded) / 60) min \(Int(rounded) % 60) s"
        return "\(code) after \(time)"
    }
}
