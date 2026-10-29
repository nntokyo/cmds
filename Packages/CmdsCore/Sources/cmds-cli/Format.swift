import CmdsCore
import Foundation

/// Human-readable output for `cmds ls` / `cmds panes` / `cmds stats`.
enum Format {
    static func workspaces(_ workspaces: [WorkspaceInfo], currentPane: String?) -> String {
        guard !workspaces.isEmpty else { return "no workspaces\n" }
        var out = ""
        for (index, workspace) in workspaces.enumerated() {
            var line = "\(workspace.selected ? "*" : " ") \(index + 1). \(workspace.id)  \(workspace.title)"
            if let branch = workspace.gitBranch { line += "  [\(branch)]" }
            if let cwd = workspace.workingDirectory { line += "  \(abbreviate(cwd))" }
            if !workspace.ports.isEmpty { line += "  " + workspace.ports.map { ":\($0)" }.joined(separator: " ") }
            if workspace.cpuPercent != nil || workspace.memoryBytes != nil {
                line += "  " + ResourceFormat.usage(cpuPercent: workspace.cpuPercent, memoryBytes: workspace.memoryBytes)
            }
            if workspace.attention { line += "  !" }
            if let text = workspace.notificationText { line += "  — \(oneLine(text))" }
            out += line + "\n"
            let panes = Dictionary(uniqueKeysWithValues: workspace.panes.map { ($0.id, $0) })
            if let layout = workspace.layout {
                out += tree(layout, panes: panes, currentPane: currentPane, prefix: "     ")
            } else {
                for pane in workspace.panes { out += "     " + Self.pane(pane, currentPane: currentPane) + "\n" }
            }
        }
        return out
    }

    /// `cmds stats`: one line for the Mac, then one per workspace (sidebar order).
    static func stats(_ snapshot: StatsSnapshot, titles: [String: String], currentWorkspace: String?) -> String {
        var out: String
        if let system = snapshot.system {
            out = "system  CPU \(leftPad(ResourceFormat.wholePercent(system.cpuPercent), 4))  "
                + "memory \(ResourceFormat.memory(used: system.memoryUsedBytes, total: system.memoryTotalBytes))  "
                + "pressure \(system.pressure.name)\n"
        } else {
            out = "system  (measuring, try again in a second)\n"
        }
        guard !snapshot.workspaces.isEmpty else { return out + "no workspaces\n" }
        let idWidth = snapshot.workspaces.map(\.id.count).max() ?? 0
        let names = snapshot.workspaces.map { oneLine(titles[$0.id] ?? "") }
        let nameWidth = min(names.map(\.count).max() ?? 0, 30)
        for (workspace, name) in zip(snapshot.workspaces, names) {
            let marker = workspace.id == currentWorkspace ? ">" : " "
            let cpu = workspace.cpuPercent.map(ResourceFormat.percent) ?? "–"
            let memory = workspace.memoryBytes.map(ResourceFormat.bytes) ?? "–"
            let title = name.count > nameWidth ? String(name.prefix(nameWidth - 1)) + "…" : name
            out += "\(marker) \(workspace.id.padding(toLength: idWidth, withPad: " ", startingAt: 0))  "
                + "\(title.padding(toLength: nameWidth, withPad: " ", startingAt: 0))  "
                + "CPU \(leftPad(cpu, 5))  \(leftPad(memory, 8))\n"
        }
        return out
    }

    private static func leftPad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    static func pane(_ pane: PaneInfo, currentPane: String?) -> String {
        var line = "\(pane.focused ? ">" : " ")\(pane.attention ? "!" : " ") \(pane.id)  \(pane.kind.rawValue)  \(oneLine(pane.title))"
        if pane.kind == .browser, let url = pane.url { line += "  \(url)" }
        if pane.kind == .terminal, let cwd = pane.workingDirectory { line += "  \(abbreviate(cwd))" }
        if pane.id == currentPane { line += "  (this pane)" }
        return line
    }

    /// Box-drawing tree of the split layout.
    private static func tree(_ node: LayoutNode, panes: [String: PaneInfo], currentPane: String?, prefix: String) -> String {
        func render(_ node: LayoutNode, _ indent: String, _ last: Bool, root: Bool) -> String {
            let branch = root ? "" : (last ? "└─ " : "├─ ")
            let childIndent = root ? indent : indent + (last ? "   " : "│  ")
            switch node {
            case .pane(let id):
                let text = panes[id].map { pane($0, currentPane: currentPane) } ?? "   \(id)"
                return indent + branch + text + "\n"
            case .split(let axis, let ratio, let first, let second):
                let label = axis == .horizontal ? "split right" : "split down"
                return indent + branch + "\(label) \(Int((ratio * 100).rounded()))%\n"
                    + render(first, childIndent, false, root: false)
                    + render(second, childIndent, true, root: false)
            }
        }
        return render(node, prefix, true, root: true)
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func oneLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 80 ? String(flat.prefix(79)) + "…" : flat
    }
}
