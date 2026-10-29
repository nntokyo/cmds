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

    init(id: String) {
        self.id = id
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
                      attention: attention, panes: paneInfos(), layout: root?.layoutNode)
    }

    func paneInfos() -> [PaneInfo] {
        orderedPanes.map { $0.info(focused: $0.id == focusedPaneID) }
    }
}

extension String {
    /// `/Users/me/src` → `~/src`.
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }
}
