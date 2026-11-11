import CmdsCore
import SwiftUI
import WidgetKit

/// Drawings of the widget, in the menu bar item's colours: orange needs you, the accent colour working, green done,
/// limits green / orange from 80 % / red from 95 %. Little text: counts, names, rings.
struct CmdsWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var widgetFamily

    var body: some View { CmdsWidgetContent(entry: entry, family: widgetFamily) }
}

/// The widget for a given size (also rendered outside WidgetKit, for checking the drawings).
struct CmdsWidgetContent: View {
    let entry: SnapshotEntry
    let family: WidgetFamily
    /// Rows open their workspace (`Link`); off only where links cannot be drawn (rendering the views for a check).
    var linksRows = true

    /// The app refreshes the file at least every minute while it runs; older figures mean it stopped.
    static let staleAfter: TimeInterval = 300

    var body: some View {
        if let snapshot = entry.snapshot {
            let stale = entry.date.timeIntervalSince(snapshot.updatedAt) > Self.staleAfter
            content(snapshot)
                .opacity(stale ? 0.45 : 1)
                .overlay(alignment: .bottom) {
                    if stale {
                        Text("cmds isn't running")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
                .widgetURL(Self.url(snapshot.workspaces.first { $0.state == .needsUser }?.id))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "apple.terminal").font(.system(size: 28))
                Text("Open cmds to see your agents here.")
                    .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            .widgetURL(Self.url(nil))
        }
    }

    @ViewBuilder
    private func content(_ snapshot: WidgetSnapshot) -> some View {
        switch family {
        case .systemMedium:
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    BadgeRow(snapshot: snapshot)
                    WorkspaceList(workspaces: Array(snapshot.workspaces.prefix(4)), now: entry.date, linked: linksRows)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                RingColumn(gauges: Self.rings(snapshot, count: 3), now: entry.date)
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                BadgeRow(snapshot: snapshot)
                if let first = snapshot.workspaces.first, first.state == .needsUser || first.state == .working {
                    WorkspaceLine(workspace: first, showsDetail: false, now: entry.date)
                } else {
                    Text("No agents working").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let ring = Self.rings(snapshot, count: 1).first {
                    HStack(spacing: 8) {
                        RingView(gauge: ring, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ring.label).font(.caption2.weight(.medium))
                            if let reset = ring.resetsAt { ResetText(date: reset, now: entry.date) }
                        }
                    }
                }
            }
        }
    }

    /// Account limits first (the most used first), then CPU and memory.
    static func rings(_ snapshot: WidgetSnapshot, count: Int) -> [WidgetSnapshot.Gauge] {
        let limits = snapshot.gauges.filter { $0.resetsAt != nil }.sorted { $0.fraction > $1.fraction }
        let machine = snapshot.gauges.filter { $0.resetsAt == nil }
        return Array((limits + machine).prefix(count))
    }

    /// The app's URL scheme. Debug builds are a separate app ("cmds Dev") with their own scheme (#236, project.yml).
    #if DEBUG
    static let scheme = "cmds-dev"
    #else
    static let scheme = "cmds"
    #endif

    static func url(_ workspaceID: String?) -> URL {
        guard let workspaceID, let escaped = workspaceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return URL(string: "\(scheme)://")!
        }
        return URL(string: "\(scheme)://workspace/\(escaped)")!
    }
}

/// The glyph, the orange count of workspaces that need you, the accent count of those working, the red warning dot.
private struct BadgeRow: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "apple.terminal")
                .font(.system(size: 15))
                .overlay(alignment: .topTrailing) {
                    if snapshot.warning != nil {
                        Circle().fill(.red).frame(width: 7, height: 7).offset(x: 3, y: -3)
                    }
                }
            if snapshot.needingUser > 0 { Badge(count: snapshot.needingUser, color: .orange) }
            if snapshot.working > 0 { Badge(count: snapshot.working, color: .accentColor) }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(snapshot.needingUser) need you, \(snapshot.working) working"))
    }
}

private struct Badge: View {
    let count: Int
    let color: Color

    var body: some View {
        Text(count > 9 ? "9+" : "\(count)")
            .font(.system(size: 11, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .frame(minWidth: 18, minHeight: 18)
            .background(color, in: Circle())
    }
}

private struct WorkspaceList: View {
    let workspaces: [WidgetSnapshot.Workspace]
    let now: Date
    let linked: Bool

    var body: some View {
        if workspaces.isEmpty {
            Text("No agents working").font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(workspaces, id: \.id) { workspace in
                    if linked {
                        Link(destination: CmdsWidgetContent.url(workspace.id)) {
                            WorkspaceLine(workspace: workspace, showsDetail: true, now: now)
                        }
                    } else {
                        WorkspaceLine(workspace: workspace, showsDetail: true, now: now)
                    }
                }
            }
        }
    }
}

/// State mark, name, and how long it has waited or what the agent does.
private struct WorkspaceLine: View {
    let workspace: WidgetSnapshot.Workspace
    let showsDetail: Bool
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            StateMark(state: workspace.state)
            VStack(alignment: .leading, spacing: 0) {
                Text(workspace.title).font(.caption.weight(.semibold)).lineLimit(1)
                if let since = workspace.waitingSince {
                    Text(Self.age(since, now: now)).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                } else if showsDetail, !workspace.detail.isEmpty {
                    Text(workspace.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

extension WorkspaceLine {
    /// `3 min ago` / `3分前`, as of the entry (a still text: a ticking one would draw attention to itself).
    static func age(_ since: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: min(since, now), relativeTo: now)
    }
}

private struct StateMark: View {
    let state: MenuBarSummary.State

    var body: some View {
        switch state {
        case .needsUser: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white, .orange)
        case .working: Image(systemName: "circle.dotted").foregroundStyle(Color.accentColor)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green)
        case .idle: Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.secondary)
        case .stopped: Image(systemName: "circle").font(.system(size: 7)).foregroundStyle(.tertiary)
        }
    }
}

private struct RingColumn: View {
    let gauges: [WidgetSnapshot.Gauge]
    let now: Date

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(gauges.enumerated()), id: \.offset) { _, gauge in
                HStack(spacing: 6) {
                    RingView(gauge: gauge, size: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(gauge.label).font(.caption2.weight(.medium)).lineLimit(1)
                        if let reset = gauge.resetsAt { ResetText(date: reset, now: now) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 118)
    }
}

/// A ring filled by the share, the percentage inside.
struct RingView: View {
    let gauge: WidgetSnapshot.Gauge
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: size / 8)
            Circle()
                .trim(from: 0, to: gauge.fraction)
                .stroke(color, style: StrokeStyle(lineWidth: size / 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((gauge.fraction * 100).rounded()))")
                .font(.system(size: size * 0.32, weight: .semibold).monospacedDigit())
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(gauge.label) \(Int((gauge.fraction * 100).rounded())) %")
    }

    private var color: Color {
        switch gauge.level {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        case .accent: return .accentColor
        }
    }
}

/// Time to a limit's reset as of the entry, two units at most: `2時間9分` / `2h 9m`, `3日23時間` / `3d 23h`.
private struct ResetText: View {
    let date: Date
    let now: Date

    var body: some View {
        Text(Self.text(date, now: now)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
    }

    static func text(_ date: Date, now: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter.string(from: max(60, date.timeIntervalSince(now))) ?? ""
    }
}
