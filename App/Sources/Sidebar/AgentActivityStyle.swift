import AppKit
import CmdsCore

/// How a workspace's agent state looks in the sidebar (full rows and the compact rail).
@MainActor
enum AgentActivityStyle {
    enum Badge: Equatable {
        case working, needsInput, done, idle, stopped

        var text: String {
            switch self {
            case .working: return String(localized: "Working", comment: "sidebar agent state: the agent is busy")
            case .needsInput: return String(localized: "Needs Input", comment: "sidebar agent state: waiting for the user's answer or permission")
            case .done: return String(localized: "Done", comment: "sidebar agent state: finished, not seen yet")
            case .idle: return String(localized: "Idle", comment: "sidebar agent state: waiting for the next prompt")
            case .stopped: return String(localized: "Stopped", comment: "sidebar agent state: the agent exited")
            }
        }

        var color: NSColor {
            switch self {
            case .working: return .controlAccentColor
            case .needsInput: return .systemOrange
            case .done: return .systemGreen
            case .idle: return .secondaryLabelColor
            case .stopped: return .tertiaryLabelColor
            }
        }
    }

    /// nil when no agent ran in the workspace in this run (plain shells get no badge).
    static func badge(for workspace: Workspace) -> Badge? {
        switch workspace.agentActivity {
        case .busy: return .working
        case .needsInput: return .needsInput
        case .idle: return workspace.attention ? .done : .idle
        case .none: return workspace.hadAgent ? .stopped : nil
        }
    }

    /// The agent works and nothing waits for the user: a spinner (full row) or a pulsing dot (rail) instead of a still dot.
    static func isWorking(_ workspace: Workspace) -> Bool {
        workspace.agentActivity == .busy && !workspace.attention
    }

    /// Unseen attention or an agent waiting for input.
    static func needsUser(_ workspace: Workspace) -> Bool {
        workspace.attention || workspace.agentActivity == .needsInput
    }

    /// Colour of the dot in front of the title / next to the rail number: orange for unseen attention, else the state.
    static func dotColor(for workspace: Workspace) -> NSColor? {
        if workspace.attention { return .systemOrange }
        switch workspace.agentActivity {
        case .busy: return .controlAccentColor
        case .needsInput: return .systemOrange
        case .idle: return NSColor.systemGreen.withAlphaComponent(0.7)
        case .none: return nil
        }
    }
}

/// A path label that drops leading components rather than cutting a name in the middle: `…/NN/自社/jav-a`.
final class PathLabel: NSTextField {
    var path = "" {
        didSet { if path != oldValue { fit() } }
    }
    private var fittedWidth: CGFloat = -1

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - fittedWidth) > 0.5 { fit() }
    }

    private func fit() {
        fittedWidth = frame.width
        let text = Self.fitted(path, width: frame.width, font: font ?? .systemFont(ofSize: 11))
        if stringValue != text { stringValue = text }
    }

    /// The whole path if it fits, else `…/` + as many trailing components as fit (at least the last one, which the
    /// label then truncates at its head).
    static func fitted(_ path: String, width: CGFloat, font: NSFont) -> String {
        guard width > 0 else { return path }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        func fits(_ text: String) -> Bool { (text as NSString).size(withAttributes: attributes).width <= width - 4 }
        if fits(path) { return path }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count > 1 else { return path }
        for count in stride(from: components.count - 1, through: 1, by: -1) {
            let candidate = "…/" + components.suffix(count).joined(separator: "/")
            if fits(candidate) { return candidate }
        }
        return "…/" + (components.last ?? path)
    }
}
