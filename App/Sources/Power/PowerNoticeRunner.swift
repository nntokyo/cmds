import AppKit
import CmdsCore
import IOKit.ps

/// Tells the agents when the Mac goes on battery or its battery runs low (`cmds power`, API `power.*`;
/// docs/guide/queue.md "On battery"). `PowerNotice` decides; this class reads the power source (IOKit, on every change
/// the system reports) and keeps the line for each pane that runs an agent (`PaneQueueRunner`). Owned by
/// `AppController`. Off until turned on (`power-notice.json` in the support directory).
@MainActor
final class PowerNoticeRunner {
    unowned let controller: AppController
    private let url: URL
    private(set) var settings: PowerNotice.Settings
    private var state = PowerNotice.State()
    private var source: CFRunLoopSource?
    /// Tests only (`debug.power`): read in place of the Mac's power source.
    var simulated: PowerNotice.Power? {
        didSet { check() }
    }
    private var last: (event: PowerNotice.Event, at: Date, panes: Int)?

    init(controller: AppController, supportDirectory: URL = CmdsEnv.supportDirectoryURL()) {
        self.controller = controller
        url = PowerNotice.url(supportDirectory: supportDirectory)
        settings = PowerNotice.loadSettings(from: url)
    }

    /// After session restore and `PaneQueueRunner.start`.
    func start() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let created = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let runner = Unmanaged<PowerNoticeRunner>.fromOpaque(context).takeUnretainedValue()
            // Delivered on the main run loop, where the source was added.
            MainActor.assumeIsolated { runner.check() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
            source = created
        }
        check()
    }

    /// Reads the power source and sends the line when `PowerNotice.event` says so.
    func check() {
        guard let power = simulated ?? Self.read() else { return }
        guard let event = PowerNotice.event(current: power, settings: settings, state: &state) else { return }
        send(event, power: power)
    }

    private func send(_ event: PowerNotice.Event, power: PowerNotice.Power) {
        let panes = controller.workspaces.flatMap(\.orderedPanes).filter { AppController.isScheduleTarget($0) && !$0.isClosing }
        let candidates = panes.map { pane in
            PowerNotice.Candidate(pane: pane.id,
                                  runsAgent: pane.agentUsage.map { $0.agent == .claude || $0.agent == .codex } ?? false,
                                  hasPowerLineWaiting: controller.paneQueue.hasWaiting(from: PowerNotice.queueSource, for: pane))
        }
        let line = PowerNotice.line(event, power: power, settings: settings)
        var kept = 0
        for paneID in PowerNotice.targets(candidates) {
            // A pane whose queue is full keeps what it has.
            if (try? controller.paneQueue.add(text: line, paneID: paneID, from: PowerNotice.queueSource)) != nil { kept += 1 }
        }
        last = (event, Date(), kept)
        scheduleLog.info("power notice: \(event.rawValue, privacy: .public) kept for \(kept) panes")
    }

    // MARK: API

    func status() -> PowerNoticeStatus {
        PowerNoticeStatus(settings: settings, power: simulated ?? Self.read(), lastEvent: last?.event,
                          lastSentAt: last.map { ISO8601DateFormatter().string(from: $0.at) }, lastPanes: last?.panes)
    }

    /// Changes what is given (`request` empty: back to the default line) and checks the power source at once, so
    /// turning it on while on a low battery tells the agents now.
    func set(enabled: Bool?, belowPercent: Int?, request: String?) throws -> PowerNoticeStatus {
        var changed = settings
        if let enabled { changed.enabled = enabled }
        if let belowPercent {
            guard PowerNotice.belowRange.contains(belowPercent) else {
                throw RPCError.invalidParams("below must be \(PowerNotice.belowRange.lowerBound) to \(PowerNotice.belowRange.upperBound)")
            }
            changed.belowPercent = belowPercent
        }
        if let request { changed.request = PowerNotice.oneLine(request) }
        if changed != settings {
            do {
                try PowerNotice.save(changed, to: url)
            } catch {
                throw RPCError(code: 500, message: "the setting could not be saved: \(error.localizedDescription)")
            }
            settings = changed
        }
        check()
        return status()
    }

    // MARK: Power source

    /// The providing power source and the internal battery's charge; nil when the system gives no answer.
    static func read() -> PowerNotice.Power? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var percent: Int?
        let sources = (IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description["Type"] as? String == "InternalBattery",
                  let current = description["Current Capacity"] as? Int,
                  let capacity = description["Max Capacity"] as? Int, capacity > 0 else { continue }
            percent = min(100, max(0, current * 100 / capacity))
        }
        return PowerNotice.Power(onBattery: providing == "Battery Power", percent: percent)
    }
}

/// `power.status` and `power.set` on the local socket (docs/reference/api.md). Never on an SSH pane's socket: the
/// methods are not in `RemoteAPIPolicy.allowedMethods`.
@MainActor
enum PowerNoticeAPI {
    static func perform(_ method: String, _ params: Params, runner: PowerNoticeRunner) throws -> JSONValue? {
        switch method {
        case "power.status":
            return try .from(runner.status())
        case "power.set":
            return try .from(runner.set(enabled: try params.bool("enabled"), belowPercent: try params.int("below"),
                                        request: try params.string("request")))
        default:
            throw RPCError.methodNotFound(method)
        }
    }
}
