import CmdsCore
import SwiftUI

/// Sidebar + detail. On iPhone (compact width) NavigationSplitView collapses into a stack.
struct MainView: View {
    @Environment(CompanionClient.self) private var client
    /// `-mockWorkspace <id>` preselects a workspace (screenshots / UI checks).
    @State private var selectedWorkspaceID: String? = UserDefaults.standard.string(forKey: "mockWorkspace")
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WorkspaceListView(selection: $selectedWorkspaceID)
        } detail: {
            if let workspace = client.workspace(selectedWorkspaceID) {
                WorkspaceDetailView(workspace: workspace)
                    .id(workspace.id)
            } else {
                ContentUnavailableView {
                    Label(client.workspaces.isEmpty ? client.status.label : "Select a workspace",
                          systemImage: "terminal")
                } description: {
                    if case .reconnecting(_, let reason?) = client.status { Text(reason) }
                    if case .failed(let message) = client.status { Text(message) }
                }
            }
        }
        .onChange(of: client.workspaces) { _, workspaces in
            // Keep selection valid; on iPad pick the workspace selected on the Mac.
            if let id = selectedWorkspaceID, !workspaces.contains(where: { $0.id == id }) {
                selectedWorkspaceID = nil
            }
            if selectedWorkspaceID == nil, UIDevice.current.userInterfaceIdiom == .pad {
                selectedWorkspaceID = workspaces.first(where: \.selected)?.id ?? workspaces.first?.id
            }
        }
        .onChange(of: selectedWorkspaceID) { _, id in
            if id == nil { client.setVisiblePanes([]) }
        }
    }
}

struct WorkspaceListView: View {
    @Environment(CompanionClient.self) private var client
    @Binding var selection: String?
    @State private var showingRemoteAccess = false

    var body: some View {
        List(selection: $selection) {
            ForEach(client.workspaces) { workspace in
                NavigationLink(value: workspace.id) {
                    WorkspaceRow(workspace: workspace, attention: client.needsAttention(workspace),
                                 agentLimits: client.agentLimits)
                }
                .contextMenu {
                    Button {
                        client.selectWorkspaceOnMac(workspace.id)
                    } label: {
                        Label("Show on Mac", systemImage: "desktopcomputer")
                    }
                }
            }
        }
        .overlay {
            if client.workspaces.isEmpty {
                VStack(spacing: 12) {
                    if !client.status.isLive && !isFailure { ProgressView() }
                    Text(emptyText).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Older Macs do not send system stats or agent limits; show nothing rather than placeholders.
            if client.systemStats != nil || !client.agentLimits.isEmpty {
                VStack(spacing: 8) {
                    ForEach(client.agentLimits) { limits in
                        AgentLimitsBar(limits: limits)
                    }
                    if let stats = client.systemStats { SystemStatsBar(stats: stats) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
                .opacity(client.status.isLive ? 1 : 0.5)
            }
        }
        .navigationTitle(client.macName.isEmpty ? "cmds" : client.macName)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ConnectionStatusBadge()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if case .failed = client.status, let target = client.target {
                        Button("Retry") { client.connect(to: target) }
                    }
                    if client.target?.kind != .mock {
                        Button("Remote Access via SSH…", systemImage: "network") { showingRemoteAccess = true }
                        Button("Unpair This Mac", role: .destructive) { client.unpair() }
                    }
                    Button("Switch Mac…") { client.disconnect() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingRemoteAccess) {
            if let target = client.target {
                RemoteAccessView(targetID: target.id, macName: client.macName)
            }
        }
    }

    private var isFailure: Bool {
        if case .failed = client.status { return true }
        return false
    }

    private var emptyText: String {
        switch client.status {
        case .failed(let message): return message
        case .reconnecting(_, let reason): return [client.status.label, reason].compactMap { $0 }.joined(separator: "\n")
        case .connected: return "No workspaces"
        default: return client.status.label
        }
    }
}

struct WorkspaceRow: View {
    let workspace: WorkspaceInfo
    let attention: Bool
    var agentLimits: [AgentLimits] = []

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(attention ? Color.orange : Color.clear)
                .overlay(Circle().stroke(attention ? Color.clear : Color.secondary.opacity(0.3), lineWidth: 1))
                .frame(width: 9, height: 9)
                .padding(.top, 6)
                .accessibilityLabel(attention ? "Needs attention" : "")
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(workspace.title).font(.headline).lineLimit(1)
                    if workspace.selected {
                        Image(systemName: "desktopcomputer")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Active on Mac")
                    }
                    Spacer()
                    if workspace.panes.count > 1 {
                        Text("\(workspace.panes.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let branch = workspace.gitBranch {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                        Text(branch).lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let cwd = workspace.workingDirectory {
                    Text(cwd)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if !workspace.ports.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(workspace.ports, id: \.self) { port in
                            Text(":\(String(port))")
                                .font(.caption2.monospaced())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.blue.opacity(0.15), in: Capsule())
                        }
                    }
                }
                if let agent = workspace.primaryAgent {
                    AgentSummaryLine(usage: agent.usage, limits: agentLimits.limits(for: agent.usage.agent)?.limits)
                }
                if workspace.cpuPercent != nil || workspace.memoryBytes != nil {
                    WorkspaceUsageLine(cpuPercent: workspace.cpuPercent, memoryBytes: workspace.memoryBytes)
                }
                if let note = workspace.notificationText, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(attention ? Color.orange : Color.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// `CPU 12% · 1.2 GB` for one workspace (CPU as in Activity Monitor: 100% = one core).
struct WorkspaceUsageLine: View {
    let cpuPercent: Double?
    let memoryBytes: UInt64?

    var body: some View {
        let cpu = cpuPercent.map(ResourceFormat.percent) ?? "–"
        let memory = memoryBytes.map(ResourceFormat.bytes) ?? "–"
        HStack(spacing: 4) {
            Text("CPU").foregroundStyle(.tertiary)
            // Reserve the width of "100%" so the memory figure does not shift as CPU digits change.
            Text("100%").hidden().overlay(alignment: .leading) {
                Text(cpu).foregroundStyle((cpuPercent ?? 0) > 100 ? Color.orange : Color.secondary)
            }
            Text("·").foregroundStyle(.tertiary)
            Text(memory).foregroundStyle(.secondary)
        }
        .font(.caption2.monospacedDigit())
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU \(cpu), memory \(memory)")
    }
}

/// One agent's account limits: `Claude  5h ━━━ 40%  7d ━ 12%` (meters orange from 80 %, red from 95 %).
struct AgentLimitsBar: View {
    let limits: AgentLimits

    var body: some View {
        let windows = Array(limits.ordered.prefix(3))
        HStack(alignment: .bottom, spacing: 12) {
            Text(limits.agent.displayName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            ForEach(windows) { limit in
                let level = UsageLevel(percent: limit.usedPercent)
                UsageGauge(title: limit.id == UsageLimit.spend ? "$" : AgentFormat.limitLabel(limit),
                           value: limit.id == UsageLimit.spend ? AgentFormat.limitValue(limit) : AgentFormat.percent(limit.usedPercent),
                           fraction: limit.usedPercent / 100, tint: level.color,
                           valueTint: level == .normal ? nil : level.color)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(limits.agent.displayName) limits: " + AgentFormat.limitLines(windows).joined(separator: ", "))
    }
}

/// The workspace's agent pane: `Claude Opus 4.5 · ctx 53% · $117.99 · 5h 40%`.
struct AgentSummaryLine: View {
    let usage: AgentUsage
    let limits: [UsageLimit]?

    var body: some View {
        let parts = AgentFormat.summaryParts(usage, limits: limits)
        parts.reduce(Text("")) { text, part in
            var piece = Text(part.text)
            switch part.style {
            case .name: piece = piece.fontWeight(.medium).foregroundColor(.primary.opacity(0.85))
            case .label, .separator: piece = piece.foregroundColor(Color(uiColor: .tertiaryLabel))
            case .value: piece = piece.foregroundColor(part.level == .normal ? .secondary : part.level.color)
            }
            return text + piece
        }
        .font(.caption2.monospacedDigit())
        .lineLimit(1)
        .opacity(usage.isStale ? 0.6 : 1)
        .accessibilityLabel(AgentFormat.summary(usage, limits: limits) + (usage.isStale ? ", idle" : ""))
    }
}

extension UsageLevel {
    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

/// Mac-wide CPU and memory with thin meters; the memory meter follows the memory pressure.
struct SystemStatsBar: View {
    let stats: SystemStats

    var body: some View {
        let memory = ResourceFormat.memory(used: stats.memoryUsedBytes, total: stats.memoryTotalBytes)
        let pressure = stats.pressure
        HStack(spacing: 16) {
            UsageGauge(title: "CPU", value: ResourceFormat.wholePercent(stats.cpuPercent),
                       fraction: stats.cpuPercent / 100, tint: .accentColor)
            UsageGauge(title: pressure == .normal || pressure == .unknown ? "Mem" : "Mem · \(pressure.name)",
                       value: memory, fraction: stats.memoryFraction, tint: pressureColor,
                       valueTint: pressure == .warning || pressure == .critical ? pressureColor : nil)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mac CPU \(ResourceFormat.wholePercent(stats.cpuPercent)), memory \(memory), pressure \(pressure.name)")
    }

    private var pressureColor: Color {
        switch stats.pressure {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        case .unknown: return .secondary
        }
    }
}

private struct UsageGauge: View {
    let title: String
    let value: String
    let fraction: Double
    let tint: Color
    var valueTint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(value).font(.caption2.monospacedDigit()).foregroundStyle(valueTint ?? .primary)
            }
            UsageMeter(fraction: fraction, tint: tint)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Thin capsule track with a proportional fill.
private struct UsageMeter: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
            Capsule()
                .fill(Color.secondary.opacity(0.2))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint.opacity(0.85))
                        .frame(width: geo.size.width * clamped)
                }
                .animation(.easeOut(duration: 0.4), value: clamped)
        }
        .frame(height: 4)
    }
}

/// Pane selector (tabs + split mini-map) and the selected pane's screen + input.
struct WorkspaceDetailView: View {
    @Environment(CompanionClient.self) private var client
    let workspace: WorkspaceInfo
    @State private var selectedPaneID: String?

    private var orderedPanes: [PaneInfo] {
        let order = workspace.layout?.paneIDsInOrder ?? []
        let byID = Dictionary(uniqueKeysWithValues: workspace.panes.map { ($0.id, $0) })
        var result = order.compactMap { byID[$0] }
        result += workspace.panes.filter { !order.contains($0.id) }
        return result
    }

    private var selectedPane: PaneInfo? {
        orderedPanes.first { $0.id == selectedPaneID } ?? orderedPanes.first(where: \.focused) ?? orderedPanes.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if orderedPanes.count > 1 {
                PaneSelectorBar(workspace: workspace, panes: orderedPanes, selectedID: selectedPane?.id) { id in
                    selectedPaneID = id
                }
                Divider()
            }
            if let pane = selectedPane {
                PaneView(pane: pane)
                    .id(pane.id)
            } else {
                ContentUnavailableView("No panes", systemImage: "rectangle.dashed")
            }
        }
        .navigationTitle(workspace.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        client.selectWorkspaceOnMac(workspace.id)
                    } label: { Label("Show Workspace on Mac", systemImage: "desktopcomputer") }
                    if let pane = selectedPane {
                        Button {
                            client.selectWorkspaceOnMac(workspace.id)
                            client.focusPaneOnMac(pane.id)
                        } label: { Label("Focus Pane on Mac", systemImage: "scope") }
                    }
                } label: {
                    Image(systemName: "desktopcomputer")
                }
            }
        }
        .onAppear(perform: syncSubscription)
        .onChange(of: selectedPane?.id) { _, _ in syncSubscription() }
        .onDisappear { client.setViewedPane(nil, workspaceID: nil) }
    }

    private func syncSubscription() {
        guard let pane = selectedPane else { return }
        client.setVisiblePanes(pane.kind == .terminal ? [pane.id] : [])
        client.setViewedPane(pane.id, workspaceID: workspace.id)
    }
}

/// Tabs for each pane plus a mini-map of the split layout.
struct PaneSelectorBar: View {
    @Environment(CompanionClient.self) private var client
    let workspace: WorkspaceInfo
    let panes: [PaneInfo]
    let selectedID: String?
    let select: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let layout = workspace.layout {
                LayoutMiniMap(node: layout, selectedID: selectedID,
                              attention: Set(panes.filter { client.needsAttention($0) }.map(\.id)),
                              select: select)
                    .frame(width: 54, height: 34)
                    .accessibilityHidden(true)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                        Button {
                            select(pane.id)
                        } label: {
                            HStack(spacing: 5) {
                                if client.needsAttention(pane) {
                                    Circle().fill(.orange).frame(width: 7, height: 7)
                                }
                                Image(systemName: pane.kind == .browser ? "globe" : "terminal")
                                    .font(.caption2)
                                Text(pane.title.isEmpty ? "Pane \(index + 1)" : pane.title)
                                    .font(.subheadline)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(pane.id == selectedID ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1),
                                        in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(pane.id == selectedID ? .isSelected : [])
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// Proportional drawing of a `LayoutNode`; tap a cell to select that pane.
struct LayoutMiniMap: View {
    let node: LayoutNode
    let selectedID: String?
    let attention: Set<String>
    let select: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            cell(node, size: geo.size)
        }
    }

    private func cell(_ node: LayoutNode, size: CGSize) -> AnyView {
        switch node {
        case .pane(let id):
            return AnyView(
                RoundedRectangle(cornerRadius: 2)
                    .fill(id == selectedID ? Color.accentColor : Color.secondary.opacity(0.25))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(attention.contains(id) ? Color.orange : .clear, lineWidth: 1.5))
                    .frame(width: max(0, size.width), height: max(0, size.height))
                    .contentShape(Rectangle())
                    .onTapGesture { select(id) }
            )
        case .split(let axis, let ratio, let first, let second):
            let gap: CGFloat = 2
            let r = min(max(ratio, 0.05), 0.95)
            if axis == .horizontal {
                let w1 = (size.width - gap) * r
                return AnyView(HStack(spacing: gap) {
                    cell(first, size: CGSize(width: w1, height: size.height))
                    cell(second, size: CGSize(width: size.width - gap - w1, height: size.height))
                })
            } else {
                let h1 = (size.height - gap) * r
                return AnyView(VStack(spacing: gap) {
                    cell(first, size: CGSize(width: size.width, height: h1))
                    cell(second, size: CGSize(width: size.width, height: size.height - gap - h1))
                })
            }
        }
    }
}

extension LayoutNode {
    /// Pane IDs left-to-right / top-to-bottom.
    var paneIDsInOrder: [String] {
        switch self {
        case .pane(let id): return [id]
        case .split(_, _, let first, let second): return first.paneIDsInOrder + second.paneIDsInOrder
        }
    }
}
