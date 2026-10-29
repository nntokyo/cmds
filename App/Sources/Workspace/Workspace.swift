import Foundation
import CmdsCore

/// One vertical tab: a split tree of panes plus sidebar metadata.
@MainActor
final class Workspace {
    let id: String
    /// User-assigned title; nil means "derive from the working directory".
    var customTitle: String?
    var root: SplitNode?
    var panes: [String: Pane] = [:]
    var focusedPaneID: String?
    var zoomedPaneID: String?

    /// Working directory of the focused terminal pane.
    var workingDirectory: String?
    var gitBranch: String?
    var ports: [Int] = []
    var notificationText: String?

    /// CPU of the processes in this workspace's terminals (100 = one core); nil until sampled.
    private(set) var cpuPercent: Double?
    /// Sum of their physical footprints; nil until sampled or when none was found.
    private(set) var memoryBytes: UInt64?
    private(set) var processCount = 0
    /// Consecutive samples above one full core (the sidebar tints CPU once this is sustained).
    private(set) var busySamples = 0

    init(id: String) {
        self.id = id
    }

    func applyUsage(_ usage: ResourceUsage?) {
        cpuPercent = usage?.cpuPercent.map { ($0 * 10).rounded() / 10 }
        memoryBytes = usage?.memoryBytes
        processCount = usage?.processCount ?? 0
        busySamples = (cpuPercent ?? 0) > 100 ? busySamples + 1 : 0
    }

    var hasTerminal: Bool { panes.values.contains { $0.kind == .terminal } }

    /// Panes running a coding agent with known usage, in reading order.
    var agentPanes: [Pane] { orderedPanes.filter { $0.agentUsage != nil } }

    /// The agent shown in the sidebar: the focused pane's, else the most recently updated one.
    var primaryAgent: (pane: Pane, usage: AgentUsage)? {
        AgentUsage.primary(agentPanes.compactMap { pane in pane.agentUsage.map { (pane, pane.id == focusedPaneID, $0) } })
            .map { (pane: $0.0, usage: $0.1) }
    }

    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        guard let workingDirectory else { return "Workspace" }
        if workingDirectory == NSHomeDirectory() { return "~" }
        return (workingDirectory as NSString).lastPathComponent
    }

    var orderedPanes: [Pane] { (root?.paneIDs ?? []).compactMap { panes[$0] } }
    var focusedPane: Pane? { focusedPaneID.flatMap { panes[$0] } }
    var attention: Bool { panes.values.contains { $0.attention } }

    func info(selected: Bool) -> WorkspaceInfo {
        WorkspaceInfo(id: id, title: title, selected: selected, gitBranch: gitBranch,
                      workingDirectory: workingDirectory, ports: ports, notificationText: notificationText,
                      attention: attention, panes: paneInfos(), layout: root?.layoutNode,
                      cpuPercent: cpuPercent, memoryBytes: memoryBytes)
    }

    func paneInfos() -> [PaneInfo] {
        orderedPanes.map { $0.info(focused: $0.id == focusedPaneID) }
    }
}

extension String {
    /// `/Users/me/src` → `~/src`.
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }
}
