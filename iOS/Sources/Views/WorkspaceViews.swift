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
                    Label(client.workspaces.isEmpty ? client.status.label : String(localized: "Select a workspace"),
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
    @State private var showingSettings = false

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
            if client.systemStats != nil || !client.agentLimits.isEmpty || showsDiagnostics {
                VStack(spacing: 8) {
                    ForEach(client.agentLimits) { limits in
                        AgentLimitsBar(limits: limits)
                    }
                    if let stats = client.systemStats { SystemStatsBar(stats: stats) }
                    #if DEBUG
                    if showsDiagnostics { ConnectionDiagnosticsRow() }
                    #endif
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
                    Divider()
                    Button("Settings…", systemImage: "textformat.size") { showingSettings = true }
                        .accessibilityIdentifier("settingsMenuItem")
                    #if DEBUG
                    if client.target?.kind != .mock { TransportModeMenu() }
                    #endif
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("More")
                }
                .accessibilityIdentifier("moreMenu")
            }
        }
        .sheet(isPresented: $showingRemoteAccess) {
            if let target = client.target {
                RemoteAccessView(targetID: target.id, macName: client.macName)
            }
        }
        .sheet(isPresented: $showingSettings) { TerminalSettingsView() }
    }

    /// Debug builds connected to a real Mac show the connection diagnostics row.
    private var showsDiagnostics: Bool {
        #if DEBUG
        return client.target?.kind != .mock
        #else
        return false
        #endif
    }

    private var isFailure: Bool {
        if case .failed = client.status { return true }
        return false
    }

    private var emptyText: String {
        switch client.status {
        case .failed(let message): return message
        case .reconnecting(_, let reason): return [client.status.label, reason].compactMap { $0 }.joined(separator: "\n")
        case .connected: return String(localized: "No workspaces")
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
                .accessibilityLabel(attention ? String(localized: "Needs attention") : "")
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(DefaultTitle.localized(workspace.title)).font(.headline).lineLimit(1)
                    if workspace.selected {
                        Image(systemName: "desktopcomputer")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Active on Mac")
                    }
                    Spacer()
                    if workspace.panes.count > 1 {
                        Text(verbatim: "\(workspace.panes.count)")
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
                            Text(verbatim: ":\(port)")
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
