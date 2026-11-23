import Foundation

/// A program's progress report in a terminal pane (OSC 9;4, as Windows Terminal, Ghostty and others take it; #174 G21):
/// builds, installers and agents tell how far they are. The sidebar shows it as a thin bar under the workspace's row.
public struct TerminalProgress: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Working, `percent` done.
        case normal
        /// Failed (red), with or without a percent.
        case error
        /// Working, how far is unknown.
        case indeterminate
        /// Paused (with the percent reached).
        case paused
    }

    public var state: State
    /// 0–100; nil when the program gave none.
    public var percent: Int?

    public init(state: State, percent: Int? = nil) {
        self.state = state
        self.percent = percent.map { min(100, max(0, $0)) }
    }

    /// A report nobody updates for this long is taken as over (a program that exits without clearing it; Ghostty's own
    /// window does the same).
    public static let staleAfter: TimeInterval = 15

    /// libghostty's report (`ghostty_action_progress_report_s`): state 0 remove, 1 set, 2 error, 3 indeterminate,
    /// 4 pause; `progress` -1 when none. nil: the report is removed.
    public static func fromGhostty(state: Int, progress: Int) -> TerminalProgress? {
        let percent = progress < 0 ? nil : progress
        switch state {
        case 1: return TerminalProgress(state: .normal, percent: percent ?? 0)
        case 2: return TerminalProgress(state: .error, percent: percent)
        case 3: return TerminalProgress(state: .indeterminate)
        case 4: return TerminalProgress(state: .paused, percent: percent)
        default: return nil
        }
    }

    /// The workspace's progress from its panes' (with when each was reported): a failure first, else the newest.
    public static func pick(_ reports: [(progress: TerminalProgress, at: Date)]) -> TerminalProgress? {
        if let failed = reports.filter({ $0.progress.state == .error }).max(by: { $0.at < $1.at }) { return failed.progress }
        return reports.max(by: { $0.at < $1.at })?.progress
    }
}
