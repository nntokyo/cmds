import CmdsCore
import Foundation

/// Human-readable output for `cmds ls` / `cmds panes` / `cmds stats`.
enum Format {
    static func workspaces(_ workspaces: [WorkspaceInfo], currentPane: String?) -> String {
        guard !workspaces.isEmpty else { return "no workspaces\n" }
        var out = ""
        for (index, workspace) in workspaces.enumerated() {
            var line = "\(workspace.selected ? "*" : " ") \(index + 1). \(workspace.id)  \(workspace.title)"
            if let host = workspace.remoteHost { line += "  (ssh \(host))" }
            if let branch = workspace.gitBranch { line += "  [\(branch)]" }
            if let cwd = workspace.workingDirectory { line += "  \(workspace.remoteHost == nil ? abbreviate(cwd) : cwd)" }
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

    /// `cmds ports`: `* http://localhost:3000  w1  app` (one line per port, sidebar order; * the current workspace).
    static func ports(_ workspaces: [WorkspaceInfo], currentWorkspace: String?) -> String {
        let lines = workspaces.listeningPorts.map { workspace, port in
            "\(workspace.id == currentWorkspace ? "*" : " ") \(ListeningPort.url(port))  \(workspace.id)  \(workspace.title)"
        }
        return lines.isEmpty ? "no listening ports\n" : lines.joined(separator: "\n") + "\n"
    }

    /// `cmds stats`: one line for the Mac, then one per workspace (sidebar order).
    static func stats(_ snapshot: StatsSnapshot, titles: [String: String], currentWorkspace: String?) -> String {
        var out: String
        if let system = snapshot.system {
            out = "system  CPU \(leftPad(ResourceFormat.wholePercent(system.cpuPercent), 4))  "
                + "memory \(ResourceFormat.memory(used: system.memoryUsedBytes, total: system.memoryTotalBytes))  "
                + (swap(system).map { "swap \($0)  " } ?? "")
                + "pressure \(system.pressure.name)\n"
        } else {
            out = "system  (measuring, try again in a second)\n"
        }
        if let keepAwake = snapshot.keepAwake { out += "awake   \(keepAwake.summary)\n" }
        out += limits(snapshot.agentLimits ?? [])
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

    /// `3.9 / 5 GB`, `0 B` without swap files; nil from an app that does not send swap.
    static func swap(_ system: SystemStats) -> String? {
        guard let used = system.swapUsedBytes, let total = system.swapTotalBytes else { return nil }
        return total == 0 ? ResourceFormat.bytes(used) : ResourceFormat.memory(used: used, total: total)
    }

    /// `cmds top`: one line per process, heaviest first, then the count and their memory.
    static func processes(_ list: ProcessList, titles: [String: String], currentPane: String?, now: Date = Date(),
                          timeZone: TimeZone = .current) -> String {
        guard !list.processes.isEmpty else { return "no processes started from cmds terminals\n" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func started(_ seconds: Double) -> String {
            let date = Date(timeIntervalSince1970: seconds)
            formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "MMM d"
            return formatter.string(from: date)
        }
        let rows = list.processes.map { process -> [String] in
            let place = (process.pane != nil && process.pane == currentPane ? ">" : "") + (process.pane ?? "-")
            let title = process.isLeftover ? "(leftover)" : String(oneLine(titles[process.workspace] ?? "").prefix(20))
            return [String(process.pid), ResourceFormat.bytes(process.memoryBytes),
                    process.cpuPercent.map(ResourceFormat.percent) ?? "–", place,
                    "\(process.workspace) \(title)", started(process.started), oneLine(process.command ?? process.name)]
        }
        let header = ["PID", "MEMORY", "CPU", "PANE", "WORKSPACE", "START", "COMMAND"]
        let widths = (0..<header.count).map { column in ([header] + rows).map { $0[column].count }.max() ?? 0 }
        func line(_ row: [String]) -> String {
            row.enumerated().map { column, cell in
                if column == row.count - 1 { return cell }
                return column < 3 ? leftPad(cell, widths[column]) : cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
        var out = line(header) + "\n" + rows.map { line($0) + "\n" }.joined()
        let shown = list.processes.count < list.total ? " (\(list.processes.count) shown)" : ""
        out += "\(list.total) process\(list.total == 1 ? "" : "es") · \(ResourceFormat.bytes(list.totalMemoryBytes))\(shown)\n"
        return out
    }

    private static func leftPad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    static func pane(_ pane: PaneInfo, currentPane: String?) -> String {
        var line = "\(pane.focused ? ">" : " ")\(pane.attention ? "!" : " ") \(pane.id)  \(pane.kind.rawValue)  \(oneLine(pane.title))"
        if pane.kind == .browser, let url = pane.url { line += "  \(url)" }
        if pane.kind == .preview, let file = pane.file { line += "  \(abbreviate(file))" }
        if pane.kind == .files, let folder = pane.workingDirectory {
            // A folder on an SSH host: `host:/path`.
            line += pane.remote.map { "  \($0.host):\(folder)\($0.connected ? "" : " (not connected)")" } ?? "  \(abbreviate(folder))"
        } else if let remote = pane.remote {
            line += "  ssh \(remote.host)\(remote.connected ? "" : " (disconnected)")"
        }
        if pane.kind == .terminal, let cwd = pane.workingDirectory { line += "  \(pane.remote == nil ? abbreviate(cwd) : cwd)" }
        if pane.id == currentPane { line += "  (this pane)" }
        if let account = pane.account { line += "  account \(oneLine(account))" }
        if let agent = pane.agent {
            // Account limits are left to `cmds agents` / `cmds stats` (the session's own copy may be older).
            line += "  [\(AgentFormat.summary(agent, limits: []))\(agent.isStale ? ", idle" : "")]"
        }
        return line
    }

    /// `cmds agents`: one line per agent pane, then the account limits.
    static func agents(_ list: AgentList, titles: [String: String], currentPane: String?, now: Date = Date()) -> String {
        var out = ""
        if list.panes.isEmpty {
            out = "no agents in cmds panes\n"
        } else {
            let paneWidth = list.panes.map(\.pane.count).max() ?? 0
            let names = list.panes.map { entry -> String in
                var name = AgentFormat.name(entry.usage)
                if let effort = entry.usage.effort { name += " (\(effort))" }
                return name
            }
            let nameWidth = names.map(\.count).max() ?? 0
            let workspaceNames = list.panes.map { String(oneLine(titles[$0.workspace] ?? $0.workspace).prefix(24)) }
            let workspaceWidth = workspaceNames.map(\.count).max() ?? 0
            for ((entry, name), workspace) in zip(zip(list.panes, names), workspaceNames) {
                let marker = entry.pane == currentPane ? ">" : " "
                var line = "\(marker) \(entry.pane.padding(toLength: paneWidth, withPad: " ", startingAt: 0))  "
                    + "\(workspace.padding(toLength: workspaceWidth, withPad: " ", startingAt: 0))  "
                    + name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                let figures = AgentFormat.statusLine(entry.usage)
                if !figures.isEmpty { line += "  " + figures }
                line += "  (\(AgentFormat.age(entry.usage.updatedAt, now: now))\(entry.usage.isStale ? ", idle" : ""))"
                out += line + "\n"
            }
        }
        out += limits(list.limits, now: now)
        return out
    }

    /// `cmds agents --subagents`: `> p3  running  1m05s  Explore · Find the hook code  Read Sources/main.swift  12k tokens`.
    static func subagents(_ list: SubagentList, currentPane: String?) -> String {
        guard !list.subagents.isEmpty else { return "no subagents\n" }
        let paneWidth = list.subagents.map(\.pane.count).max() ?? 0
        var out = ""
        for agent in list.subagents {
            let marker = agent.pane == currentPane ? ">" : " "
            var line = "\(marker) \(agent.pane.padding(toLength: paneWidth, withPad: " ", startingAt: 0))  "
                + agent.state.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0) + "  "
                + duration(agent.elapsedSeconds).padding(toLength: 6, withPad: " ", startingAt: 0) + "  "
                + oneLine(agent.title.isEmpty ? agent.id : agent.title)
            if let action = agent.action { line += "  " + oneLine(action) }
            if let tokens = agent.tokens { line += "  \(AgentFormat.tokens(tokens)) tokens" }
            out += line + "\n"
        }
        return out
    }

    /// `> p3  offered  Claude Code session “Fix login” (Opus, 2 h ago)` + id, directory and resume command.
    static func agentSessions(_ list: AgentSessionList, currentPane: String?, now: Date = Date()) -> String {
        var out = "resume on launch: \(list.mode.rawValue)\n"
        guard !list.sessions.isEmpty else { return out + "no remembered agent sessions\n" }
        let paneWidth = list.sessions.map(\.pane.count).max() ?? 0
        let stateWidth = list.sessions.map(\.state.rawValue.count).max() ?? 0
        for entry in list.sessions {
            let marker = entry.pane == currentPane ? ">" : " "
            out += "\(marker) \(entry.pane.padding(toLength: paneWidth, withPad: " ", startingAt: 0))  "
                + "\(entry.state.rawValue.padding(toLength: stateWidth, withPad: " ", startingAt: 0))  "
                + oneLine(entry.session.summary(now: now)) + "\n"
            let indent = String(repeating: " ", count: paneWidth + 4)
            var where_ = "id \(entry.session.sessionID)"
            if let host = entry.session.host { where_ += "  on \(oneLine(host))" }
            if let cwd = entry.session.cwd { where_ += "  in \(oneLine(cwd))" }
            if let account = entry.session.account { where_ += "  account \(oneLine(account))" }
            out += indent + where_ + "\n"
            if let command = entry.command, entry.state == .offered || entry.state == .waiting {
                out += indent + "$ \(command)\n"
            }
        }
        return out
    }

    /// `cmds sessions --recent`: `1  running p3  Claude Code session “Fix login” (Opus, 2 h ago)` + id, host,
    /// directory and account, and the resume command for sessions no pane holds.
    static func agentHistory(_ entries: [AgentHistoryEntry], now: Date = Date()) -> String {
        guard !entries.isEmpty else { return "no recent agent sessions\n" }
        let numberWidth = String(entries.count).count
        let places = entries.map { entry in entry.pane.map { "\(entry.state?.rawValue ?? "open") \($0)" } ?? "-" }
        let placeWidth = places.map(\.count).max() ?? 0
        var out = ""
        for (index, entry) in entries.enumerated() {
            let number = String(index + 1).padding(toLength: numberWidth, withPad: " ", startingAt: 0)
            out += "\(number)  \(places[index].padding(toLength: placeWidth, withPad: " ", startingAt: 0))  "
                + oneLine(entry.session.summary(now: now)) + "\n"
            let indent = String(repeating: " ", count: numberWidth + 2)
            var where_ = "id \(entry.session.sessionID)"
            if let host = entry.session.host { where_ += "  on \(oneLine(host))" }
            if let cwd = entry.session.cwd { where_ += "  in \(oneLine(cwd))" }
            if let account = entry.session.account { where_ += "  account \(oneLine(account))" }
            out += indent + where_ + "\n"
            if entry.pane == nil, let command = entry.command { out += indent + "$ \(command)\n" }
        }
        return out
    }

    /// `Claude  5h 40% (resets 15:30 (in 2h10m)) · 7d 12% (resets Fri 09:00)`.
    static func limits(_ limits: [AgentLimits], now: Date = Date()) -> String {
        guard !limits.isEmpty else { return "" }
        let width = limits.map(\.agent.displayName.count).max() ?? 0
        return limits.map { entry in
            var line = entry.agent.displayName.padding(toLength: width, withPad: " ", startingAt: 0) + "  "
            line += entry.ordered.map { limit in
                var text = "\(AgentFormat.limitLabel(limit)) \(AgentFormat.limitValue(limit))"
                if let period = limit.period, limit.id == UsageLimit.spend { text += " \(period)" }
                if let resetsAt = limit.resetsAt { text += " (resets \(AgentFormat.resetTime(resetsAt, now: now)))" }
                return text
            }.joined(separator: " · ")
            if let plan = entry.plan { line += "  · plan \(plan)" }
            if now.timeIntervalSince(entry.updatedAt) > 600 { line += "  (as of \(AgentFormat.age(entry.updatedAt, now: now)))" }
            return line + "\n"
        }.joined()
    }

    /// `cmds accounts`: one line per Claude account in the user's order, then the switch setting.
    /// `1  work  ~/.claude-work  limit, resets 15:00 (in 2h10m)  sessions shared  panes p3 p5`
    static func accounts(_ list: ClaudeAccountList, now: Date = Date()) -> String {
        guard !list.accounts.isEmpty else {
            return "no Claude accounts (add one: cmds accounts add NAME CONFIG_DIR)\n"
        }
        let nameWidth = list.accounts.map(\.name.count).max() ?? 0
        let dirWidth = list.accounts.map(\.configDir.count).max() ?? 0
        var out = ""
        for (index, account) in list.accounts.enumerated() {
            var line = "\(index + 1)  " + account.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                + "  " + account.configDir.padding(toLength: dirWidth, withPad: " ", startingAt: 0) + "  "
            if let limit = account.limit {
                line += "\(limit.kind == .rateLimit ? "rate limit" : "limit"), resets "
                    + (limit.estimated ? "about " : "") + AgentFormat.resetTime(limit.resetsAt, now: now)
            } else {
                line += account.exists ? "available" : "missing directory"
            }
            switch account.sessions {
            case .shared: line += "  sessions shared"
            case .missing, .separate: line += "  sessions not shared"
            case .elsewhere: line += "  projects links elsewhere"
            case .noConfigDir: break
            }
            if !account.panes.isEmpty { line += "  panes \(account.panes.joined(separator: " "))" }
            out += line + "\n"
        }
        return out + "switch at the limit: \(list.autoSwitch ? "automatic" : "ask")\n"
    }

    /// `cmds accounts share`: what each account's projects folder becomes.
    static func shareSteps(_ steps: [JSONValue], applied: Bool) -> String {
        steps.map { step in
            let account = step["account"]?.stringValue ?? "?"
            let projects = abbreviate(step["projects"]?.stringValue ?? "")
            switch step["action"]?.stringValue.flatMap(ClaudeSessionSharing.Step.Action.Name.init(rawValue:)) {
            case .unchanged?: return "\(account): \(projects) is shared already\n"
            case .link?: return "\(account): \(applied ? "linked" : "link") \(projects) to the shared folder\n"
            case .moveAside?:
                let backup = step["backup"]?.stringValue ?? ""
                return "\(account): \(applied ? "renamed" : "rename") \(projects) to \(backup) (kept), then \(applied ? "linked" : "link")\n"
            default: return "\(account): left alone — \(step["reason"]?.stringValue ?? "")\n"
            }
        }.joined()
    }

    /// `cmds sync`: server, Bonjour, Bluetooth, SSH remote access, then one line per connection.
    /// `cmds sync devices`: one line per paired device (#114), times in `timeZone` (the Mac's).
    static func pairedDevices(_ devices: [SyncPairedDevice], timeZone: TimeZone = .current) -> String {
        guard !devices.isEmpty else { return "no paired devices\n" }
        let iso = ISO8601DateFormatter()
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = timeZone
        func time(_ text: String, _ format: String) -> String {
            guard let date = iso.date(from: text) else { return text }
            local.dateFormat = format
            return local.string(from: date)
        }
        let width = devices.map(\.name.count).max() ?? 0
        return devices.map { device in
            let name = device.name.padding(toLength: width, withPad: " ", startingAt: 0)
            let state = device.connectedFrom.isEmpty
                ? (device.lastSeen.map { "last seen \(time($0, "yyyy-MM-dd HH:mm"))" } ?? "not connected")
                : "connected (\(device.connectedFrom.joined(separator: ", ")))"
            return "\(device.id)  \(name)  \(state)  · paired \(time(device.pairedAt, "yyyy-MM-dd"))\n"
        }.joined()
    }

    static func sync(_ report: SyncStatusReport) -> String {
        func yes(_ flag: Bool) -> String { flag ? "on" : "off" }
        var out = "sync       \(report.enabled ? "enabled" : "disabled") · \(report.state)"
        if let port = report.port, !report.state.contains("port \(port)") { out += " · port \(port)" }
        if let fingerprint = report.fingerprint { out += " · identity \(fingerprint)" }
        out += " · \(report.pairedDevices) paired\(report.pairingWindowOpen ? " · pairing window open" : "")\n"
        out += "bonjour    \(yes(report.bonjour.enabled))\(report.bonjour.serviceName.map { " · \"\($0)\"" } ?? "")\n"
        let bt = report.bluetooth
        out += "bluetooth  \(bt.allowed ? "allowed" : "not allowed")\(bt.disabledByEnvironment ? " (disabled by CMDS_SYNC_NO_BLUETOOTH)" : "")"
            + " · authorization \(bt.authorization) · manager \(bt.managerState)"
            + " · advertising \(yes(bt.advertising))\(bt.psm.map { " · PSM \($0)" } ?? "")"
            + " · \(bt.channels) channel\(bt.channels == 1 ? "" : "s") · \(bt.status)\n"
        let remote = report.remote
        out += "ssh relay  \(yes(remote.enabled))"
        if !remote.host.isEmpty { out += " · \(remote.host) 127.0.0.1:\(remote.relayPort)" }
        out += " · forwarding \(yes(remote.forwarding)) · \(remote.status)\n"
        guard !report.clients.isEmpty else { return out + "no connections\n" }
        for client in report.clients {
            let name = client.deviceName.isEmpty ? "(no hello yet)" : oneLine(client.deviceName)
            out += "  \(client.authenticated ? "✓" : "…") \(name)  \(client.peer)  \(client.path)"
                + "  \(client.subscribedPanes) pane\(client.subscribedPanes == 1 ? "" : "s")"
                + "  sent \(ResourceFormat.bytes(UInt64(max(0, client.bytesSent))))"
                + "  received \(ResourceFormat.bytes(UInt64(max(0, client.bytesReceived))))"
                + "  for \(duration(client.connectedSeconds))\n"
        }
        return out
    }

    private static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m\(String(format: "%02d", seconds % 60))s" }
        return "\(seconds / 3600)h\(String(format: "%02d", seconds / 60 % 60))m"
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
