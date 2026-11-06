import AppKit
import Combine
import CmdsCore
import WidgetKit

/// Feeds the cmds widget (#96): writes `widget.json` (`WidgetSnapshot`) to the support folder and asks WidgetKit to
/// reload. Important changes (counts, a workspace's state, the warning) are written within `delay` and reload the
/// widget, at most once per `reloadInterval`; gauge figures alone (CPU, memory, limits) are written at most every
/// `figuresInterval`, and the file is refreshed every `heartbeat` so the widget can tell when cmds stopped. An isolated
/// instance (`CMDS_SUPPORT_DIR`) writes into its own folder and never reloads the user's widget.
@MainActor
final class WidgetPublisher {
    static let delay: TimeInterval = 2
    static let figuresInterval: TimeInterval = 15
    static let heartbeat: TimeInterval = 60
    static let reloadInterval: TimeInterval = 60

    private let controller: AppController
    private let url: URL
    private let isolated: Bool
    private var subscriptions: [AnyCancellable] = []
    private var scheduled = false
    private var written: WidgetSnapshot?
    private var lastReload = Date.distantPast
    private var reloadPending = false

    init(controller: AppController) {
        self.controller = controller
        url = CmdsEnv.supportDirectoryURL().appendingPathComponent(WidgetSnapshot.fileName)
        isolated = CmdsEnv.supportDirectoryOverride() != nil
    }

    func start() {
        subscriptions = [
            controller.changes.sink { [weak self] _ in self?.schedule() },
            controller.usageChanges.sink { [weak self] in self?.schedule() },
        ]
        let heartbeat = Timer(timeInterval: Self.heartbeat, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        schedule()
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay) { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduled = false
                self?.publish()
            }
        }
    }

    private func publish(now: Date = Date()) {
        let snapshot = Self.snapshot(controller, now: now)
        let important = written.map { Self.key($0) != Self.key(snapshot) } ?? true
        if !important, let written {
            let age = now.timeIntervalSince(written.updatedAt)
            guard age >= Self.heartbeat || (!written.sameContent(as: snapshot) && age >= Self.figuresInterval) else { return }
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try snapshot.encoded().write(to: url, options: .atomic)
            written = snapshot
        } catch {
            return  // the widget keeps the last file; nothing else depends on it
        }
        if important { reloadWidget(now: now) }
    }

    /// What makes the widget worth redrawing at once: the badges, the list and the warning, not the figures.
    private static func key(_ snapshot: WidgetSnapshot) -> String {
        "\(snapshot.needingUser)|\(snapshot.working)|\(snapshot.warning ?? "")|"
            + snapshot.workspaces.map { "\($0.id):\($0.state):\($0.title):\($0.waitingSince?.timeIntervalSince1970 ?? 0)" }
                .joined(separator: ",")
    }

    private func reloadWidget(now: Date) {
        guard !isolated else { return }
        let wait = Self.reloadInterval - now.timeIntervalSince(lastReload)
        guard wait > 0 else {
            lastReload = now
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadPending = false
                self.lastReload = Date()
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    /// The menu bar item's figures (`AgentOverview`), and the rings of its menu: CPU, memory and every account limit.
    static func snapshot(_ controller: AppController, now: Date = Date()) -> WidgetSnapshot {
        let summary = AgentOverview.summary(controller)
        let workspaces: [WidgetSnapshot.Workspace] = summary.entries.compactMap { entry in
            guard let workspace = controller.workspace(id: entry.id), let state = entry.state else { return nil }
            return .init(id: workspace.id, title: workspace.displayTitle, state: state,
                         detail: AgentOverview.detail(workspace, state: state, age: false),
                         waitingSince: state == .needsUser ? AgentOverview.waitingSince(workspace) : nil)
        }
        var gauges: [WidgetSnapshot.Gauge] = []
        if let stats = controller.systemSample?.stats {
            gauges.append(.init(label: String(localized: "CPU", comment: "sidebar meter title"),
                                fraction: min(max(stats.cpuPercent / 100, 0), 1), level: .accent))
            let pressure: WidgetSnapshot.Gauge.Level = stats.pressure == .critical ? .critical
                : stats.pressure == .warning ? .warning : .normal
            gauges.append(.init(label: String(localized: "Mem", comment: "sidebar meter title (memory)"),
                                fraction: min(max(stats.memoryFraction, 0), 1), level: pressure))
        }
        for limits in controller.activeAgentLimits(now: now) {
            for limit in limits.ordered where limit.id != UsageLimit.spend {
                let level: WidgetSnapshot.Gauge.Level
                switch UsageLevel(percent: limit.usedPercent) {
                case .normal: level = .normal
                case .warning: level = .warning
                case .critical: level = .critical
                }
                gauges.append(.init(label: "\(limits.agent.displayName) \(AgentFormat.limitLabel(limit, strings: .localized))",
                                    fraction: min(max(limit.usedPercent / 100, 0), 1), level: level, resetsAt: limit.resetsAt))
            }
        }
        return WidgetSnapshot(updatedAt: now, needingUser: summary.needingUserCount, working: summary.workingCount,
                              warning: AgentOverview.warning(controller), workspaces: workspaces, gauges: gauges)
    }
}
