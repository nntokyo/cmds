import CmdsCore
import SwiftUI

/// Tabs for each pane plus a mini-map of the split layout. A place holding several panes as tabs on the Mac (#378,
/// `PaneInfo.tabs`) shows how many on the mini-map, is highlighted when one of its tabs is selected, and its tabs that
/// are not shown on the Mac are marked in the list (`PaneInfo.background`).
struct PaneSelectorBar: View {
    @Environment(CompanionClient.self) private var client
    let workspace: WorkspaceInfo
    let panes: [PaneInfo]
    let selectedID: String?
    let select: (String) -> Void

    static func symbol(for kind: PaneKind) -> String {
        switch kind {
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .preview: return "doc.richtext"
        case .files: return "folder"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if let layout = workspace.layout {
                LayoutMiniMap(node: layout, selectedID: selectedID,
                              attention: Set(panes.filter { client.needsAttention($0) }.map(\.id)),
                              groups: Self.groups(panes), select: select)
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
                                Image(systemName: Self.symbol(for: pane.kind))
                                    .font(.caption2)
                                if (pane.tabs?.count ?? 0) > 1 {
                                    // A tab of a group; the ones not shown on the Mac are dimmed.
                                    Image(systemName: "square.stack")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                                Text(pane.title.isEmpty ? String(localized: "Pane \(index + 1)") : DefaultTitle.localized(pane.title))
                                    .font(.subheadline)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(pane.id == selectedID ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1),
                                        in: Capsule())
                            .opacity(pane.background == true && pane.id != selectedID ? 0.65 : 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(pane.id == selectedID ? .isSelected : [])
                        .accessibilityHint(Text(pane.background == true ? String(localized: "A background tab on the Mac") : ""))
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

extension PaneSelectorBar {
    /// Each pane's tab group (its tabs in order), for panes that are tabs of a group.
    static func groups(_ panes: [PaneInfo]) -> [String: [String]] {
        Dictionary(panes.compactMap { pane in pane.tabs.flatMap { $0.count > 1 ? (pane.id, $0) : nil } }) { first, _ in first }
    }
}

/// Proportional drawing of a `LayoutNode`; tap a cell to select that pane. A cell for a tab group shows how many tabs
/// it holds and is highlighted when any of them is selected.
struct LayoutMiniMap: View {
    let node: LayoutNode
    let selectedID: String?
    let attention: Set<String>
    var groups: [String: [String]] = [:]
    let select: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            cell(node, size: geo.size)
        }
    }

    private func cell(_ node: LayoutNode, size: CGSize) -> AnyView {
        switch node {
        case .pane(let id):
            let tabs = groups[id] ?? [id]
            let selected = selectedID.map(tabs.contains) ?? false
            let alert = tabs.contains(where: attention.contains)
            return AnyView(
                RoundedRectangle(cornerRadius: 2)
                    .fill(selected ? Color.accentColor : Color.secondary.opacity(0.25))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(alert ? Color.orange : .clear, lineWidth: 1.5))
                    .overlay(alignment: .topTrailing) {
                        if tabs.count > 1 {
                            Text(verbatim: "\(tabs.count)")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(selected ? Color.white : Color.secondary)
                                .padding(1)
                        }
                    }
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
