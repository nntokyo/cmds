import CmdsCore
import SwiftUI
import WidgetKit

/// The cmds widget (#96): the menu bar item (#95) on the desktop or in Notification Center. It reads `widget.json`,
/// which the app writes to its support folder (`WidgetSnapshot`); the extension is sandboxed and may read only that
/// file. Small: badges and the workspace that waited longest. Medium: the list and the rings.
@main
struct CmdsWidgetBundle: WidgetBundle {
    var body: some Widget { CmdsStatusWidget() }
}

struct CmdsStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CmdsStatus", provider: SnapshotProvider()) { entry in
            CmdsWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        }
        .configurationDisplayName("cmds")
        .description(String(localized: "The workspaces that need you, the agents at work, and your limits."))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// nil: no file (cmds never ran with this version) or it cannot be read.
    let snapshot: WidgetSnapshot?
}

/// Reads the file now and again in five minutes; the app reloads the timeline when something important changes.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: Date(), snapshot: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: context.isPreview ? .sample : Self.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        completion(Timeline(entries: [SnapshotEntry(date: now, snapshot: Self.read())],
                            policy: .after(now.addingTimeInterval(300))))
    }

    static func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: WidgetSnapshot.defaultURL()) else { return nil }
        return try? WidgetSnapshot.decode(data)
    }
}

extension WidgetSnapshot {
    /// The widget gallery's preview.
    static let sample = WidgetSnapshot(
        updatedAt: Date(), needingUser: 1, working: 2,
        workspaces: [
            .init(id: "w1", title: "api-server", state: .needsUser, detail: "Claude · permission to use Bash",
                  waitingSince: Date().addingTimeInterval(-180)),
            .init(id: "w2", title: "my-app", state: .working, detail: "Claude · Add login validation"),
            .init(id: "w3", title: "billing", state: .working, detail: "Codex · Fix invoice PDF"),
        ],
        gauges: [.init(label: "Claude 5h", fraction: 0.46, level: .normal, resetsAt: Date().addingTimeInterval(7800)),
                 .init(label: "Claude 7d", fraction: 0.82, level: .warning, resetsAt: Date().addingTimeInterval(4 * 86400)),
                 .init(label: "CPU", fraction: 0.31, level: .accent)])
}
