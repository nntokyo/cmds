import CmdsCore
import SwiftUI

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
                                Image(systemName: pane.kind == .browser ? "globe" : pane.kind == .preview ? "doc.richtext" : "terminal")
                                    .font(.caption2)
                                Text(pane.title.isEmpty ? String(localized: "Pane \(index + 1)") : DefaultTitle.localized(pane.title))
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
