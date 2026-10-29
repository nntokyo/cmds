import Foundation

/// Snapshot types shared by the socket API, the CLI and the iOS companion.
/// The macOS app owns the live state; these are value copies sent over the wire.

public enum PaneKind: String, Codable, Sendable {
    case terminal
    case browser
}

public enum SplitAxis: String, Codable, Sendable {
    /// Children side by side (left | right).
    case horizontal
    /// Children stacked (top / bottom).
    case vertical
}

public struct PaneInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: PaneKind
    public var title: String
    public var focused: Bool
    /// Notification ring is lit (agent needs attention).
    public var attention: Bool
    public var workingDirectory: String?
    public var url: String?

    public init(id: String, kind: PaneKind, title: String, focused: Bool, attention: Bool,
                workingDirectory: String? = nil, url: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.focused = focused
        self.attention = attention
        self.workingDirectory = workingDirectory
        self.url = url
    }
}

/// Split tree as sent over the wire.
public indirect enum LayoutNode: Codable, Equatable, Sendable {
    case pane(id: String)
    case split(axis: SplitAxis, ratio: Double, first: LayoutNode, second: LayoutNode)
}

public struct WorkspaceInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var selected: Bool
    public var gitBranch: String?
    public var workingDirectory: String?
    public var ports: [Int]
    /// Latest notification text shown in the sidebar.
    public var notificationText: String?
    public var attention: Bool
    public var panes: [PaneInfo]
    public var layout: LayoutNode?
    /// CPU use of all processes in the workspace's terminals, Activity Monitor style
    /// (100 = one core, so it can exceed 100). nil until sampled.
    public var cpuPercent: Double?
    /// Sum of the physical footprints ("Memory" in Activity Monitor) of those processes.
    /// nil until sampled or when no process was found.
    public var memoryBytes: UInt64?

    public init(id: String, title: String, selected: Bool, gitBranch: String? = nil, workingDirectory: String? = nil,
                ports: [Int] = [], notificationText: String? = nil, attention: Bool = false,
                panes: [PaneInfo] = [], layout: LayoutNode? = nil,
                cpuPercent: Double? = nil, memoryBytes: UInt64? = nil) {
        self.id = id
        self.title = title
        self.selected = selected
        self.gitBranch = gitBranch
        self.workingDirectory = workingDirectory
        self.ports = ports
        self.notificationText = notificationText
        self.attention = attention
        self.panes = panes
        self.layout = layout
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}
