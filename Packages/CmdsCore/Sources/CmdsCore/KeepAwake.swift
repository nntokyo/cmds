import Foundation

/// Read-only "keep the Mac awake" state, in `system.stats` (`keepAwake`) and `cmds stats`.
/// See docs/ARCHITECTURE.md "Keeping the Mac awake".
public struct KeepAwakeStatus: Codable, Equatable, Sendable {
    /// cmds holds a `PreventUserIdleSystemSleep` assertion (idle sleep is blocked while cmds runs).
    public var idleAssertion: Bool
    /// cmds holds a `PreventUserIdleDisplaySleep` assertion (the display stays on).
    public var displayAssertion: Bool?
    /// The system-wide `SleepDisabled` power setting (`pmset -a disablesleep 1`) is on: closing the lid does not
    /// sleep the Mac. nil if it could not be read.
    public var lidCloseDisabled: Bool?
    /// cmds turned `SleepDisabled` on and will turn it off again when the option is switched off or cmds quits.
    /// false while it is on because of something else (it was on before; cmds leaves it alone).
    public var lidCloseByCmds: Bool?
    /// The lid-close option can be used by this instance (false in isolated test instances, `CMDS_SUPPORT_DIR`).
    public var lidCloseAvailable: Bool?
    /// The Mac currently runs on battery. nil if unknown (or there is no battery).
    public var onBattery: Bool?

    public init(idleAssertion: Bool, displayAssertion: Bool? = nil, lidCloseDisabled: Bool? = nil,
                lidCloseByCmds: Bool? = nil, lidCloseAvailable: Bool? = nil, onBattery: Bool? = nil) {
        self.idleAssertion = idleAssertion
        self.displayAssertion = displayAssertion
        self.lidCloseDisabled = lidCloseDisabled
        self.lidCloseByCmds = lidCloseByCmds
        self.lidCloseAvailable = lidCloseAvailable
        self.onBattery = onBattery
    }

    /// `awake: idle sleep blocked · lid close: sleeps` style line for `cmds stats`.
    public var summary: String {
        var parts = [idleAssertion ? "idle sleep blocked" : "idle sleep allowed"]
        if displayAssertion == true { parts.append("display kept on") }
        switch (lidCloseDisabled, lidCloseByCmds) {
        case (true?, true?): parts.append("lid closed OK (cmds turned sleep off; restored on quit)")
        case (true?, _): parts.append("lid closed OK (sleep turned off outside cmds)")
        case (false?, _): parts.append("closing the lid sleeps")
        default: parts.append("lid close: unknown")
        }
        if onBattery == true { parts.append("on battery") }
        return parts.joined(separator: " · ")
    }
}

/// Commands that change the system-wide `SleepDisabled` setting. Only these fixed strings are ever run with
/// administrator privileges (no user input is interpolated).
public enum SleepDisabledCommand {
    public static let pmsetPath = "/usr/bin/pmset"

    /// `["-a", "disablesleep", "1"]` (or `"0"`).
    public static func arguments(sleepDisabled: Bool) -> [String] {
        ["-a", "disablesleep", sleepDisabled ? "1" : "0"]
    }

    /// `/usr/bin/pmset -a disablesleep 1` (or `0`).
    public static func shellCommand(sleepDisabled: Bool) -> String {
        ([pmsetPath] + arguments(sleepDisabled: sleepDisabled)).joined(separator: " ")
    }

    /// AppleScript for `NSAppleScript`: macOS shows its own administrator dialog; the password never reaches cmds.
    public static func appleScript(sleepDisabled: Bool) -> String {
        let prompt = sleepDisabled
            ? "cmds wants to keep this Mac awake when the lid is closed (pmset disablesleep 1)."
            : "cmds wants to let this Mac sleep again when the lid is closed (pmset disablesleep 0)."
        return "do shell script \"\(escape(shellCommand(sleepDisabled: sleepDisabled)))\" "
            + "with prompt \"\(escape(prompt))\" with administrator privileges"
    }

    /// Fallback for the user: `sudo pmset -a disablesleep 0`.
    public static let manualRestore = "sudo " + shellCommand(sleepDisabled: false)

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// `SleepDisabled` from `pmset -g` output (`System-wide power settings:` / ` SleepDisabled\t\t1`).
    /// A missing line means off; nil when the output does not look like `pmset -g` at all.
    public static func parseSleepDisabled(pmsetOutput: String) -> Bool? {
        var sawSettings = false
        for line in pmsetOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.first == "SleepDisabled", fields.count >= 2 {
                return fields[1] == "1"
            }
            if line.contains("power settings") || line.hasPrefix("Currently in use") || line.hasPrefix("Active Profiles") {
                sawSettings = true
            }
        }
        return sawSettings ? false : nil
    }
}

/// Reads and changes `SleepDisabled`. The app's implementation runs `pmset`; tests use a fake.
public protocol SleepDisabledSystem: AnyObject {
    /// Current `SleepDisabled`, nil if unknown.
    func readSleepDisabled() -> Bool?
    /// Runs `pmset -a disablesleep 1/0` with administrator privileges (asks the user).
    func setSleepDisabled(_ disabled: Bool) throws
}

/// "cmds turned SleepDisabled on" marker, kept on disk so a run that crashed or was killed is noticed at the next launch.
public protocol LidSleepMarkerStore: AnyObject {
    var exists: Bool { get }
    func write(enabledAt: Date, pid: Int32) throws
    func remove()
}

/// Marker as a small JSON file (`lid-sleep-disabled.json` in the support directory).
public final class FileLidSleepMarkerStore: LidSleepMarkerStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    public func write(enabledAt: Date, pid: Int32) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body: [String: Any] = ["enabledAt": enabledAt.timeIntervalSince1970, "pid": Int(pid),
                                   "restore": SleepDisabledCommand.manualRestore]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    public func remove() { try? FileManager.default.removeItem(at: url) }
}

public enum LidSleepError: Error, Equatable, CustomStringConvertible {
    /// Isolated test instance: never prompts, never changes power settings.
    case unavailable
    /// `SleepDisabled` is already on and cmds did not turn it on: cmds leaves it alone.
    case alreadyDisabledOutsideCmds
    /// The user cancelled the administrator dialog.
    case cancelled
    case failed(String)

    public var description: String {
        switch self {
        case .unavailable: return "not available in an isolated instance (CMDS_SUPPORT_DIR)"
        case .alreadyDisabledOutsideCmds: return "sleep is already disabled system-wide by something other than cmds"
        case .cancelled: return "cancelled"
        case .failed(let message): return message
        }
    }
}

/// State of "Keep Awake With Lid Closed".
public enum LidSleepState: Equatable, Sendable {
    /// Closing the lid sleeps the Mac.
    case off
    /// cmds turned `SleepDisabled` on (marker present) and restores it.
    case onByCmds
    /// `SleepDisabled` is on, but not by cmds (cmds will not turn it off).
    case onOutsideCmds
    /// `pmset -g` could not be read.
    case unknown
}

/// What to do at launch about a marker left behind by an earlier run.
public enum LidSleepLaunchCheck: Equatable, Sendable {
    case nothing
    /// The earlier run did not restore sleep (crash, kill, cancelled dialog at quit): ask to restore now.
    case offerRestore
    /// Sleep had been restored outside cmds; the stale marker was removed.
    case clearedStaleMarker
}

/// The lid-close option's state machine. Not thread-safe; the app uses it on the main actor.
///
/// Rules: cmds only ever turns `SleepDisabled` off again if it turned it on itself (marker). The marker is written
/// before the admin dialog and removed only after sleep is restored, so any way out of a run (crash, kill,
/// cancelled dialog) leaves the marker and the next launch offers to restore.
public final class LidSleepController {
    public let isAvailable: Bool
    private let system: SleepDisabledSystem
    private let markers: LidSleepMarkerStore
    private let now: () -> Date
    private let pid: Int32
    /// Last read `SleepDisabled`.
    public private(set) var systemSleepDisabled: Bool?

    public init(isAvailable: Bool, system: SleepDisabledSystem, markers: LidSleepMarkerStore,
                now: @escaping () -> Date = Date.init, pid: Int32 = getpid()) {
        self.isAvailable = isAvailable
        self.system = system
        self.markers = markers
        self.now = now
        self.pid = pid
    }

    public var ownedByCmds: Bool { isAvailable && markers.exists }

    public var state: LidSleepState {
        switch systemSleepDisabled {
        case nil: return .unknown
        case false?: return .off
        case true?: return ownedByCmds ? .onByCmds : .onOutsideCmds
        }
    }

    /// Re-reads `SleepDisabled`.
    @discardableResult
    public func refresh() -> LidSleepState {
        systemSleepDisabled = system.readSleepDisabled()
        return state
    }

    /// Takes a `SleepDisabled` value read elsewhere (e.g. on a background queue).
    public func update(sleepDisabled: Bool?) {
        systemSleepDisabled = sleepDisabled
    }

    /// At launch: a marker means an earlier run turned sleep off and did not turn it back on.
    public func launchCheck() -> LidSleepLaunchCheck {
        guard isAvailable, markers.exists else { return .nothing }
        refresh()
        if systemSleepDisabled == false {
            markers.remove()
            return .clearedStaleMarker
        }
        return .offerRestore
    }

    /// Turns `SleepDisabled` on (one admin dialog). Throws `.alreadyDisabledOutsideCmds` instead of taking over a
    /// setting someone else made.
    public func enable() throws {
        guard isAvailable else { throw LidSleepError.unavailable }
        refresh()
        if systemSleepDisabled == true {
            if markers.exists { return }
            throw LidSleepError.alreadyDisabledOutsideCmds
        }
        try markers.write(enabledAt: now(), pid: pid)
        do {
            try system.setSleepDisabled(true)
        } catch {
            markers.remove()
            refresh()
            throw error
        }
        refresh()
    }

    /// Turns `SleepDisabled` off again if cmds turned it on (one admin dialog; none if it is already off).
    /// Does nothing when cmds does not own the setting.
    public func disable() throws {
        guard isAvailable, markers.exists else { return }
        refresh()
        if systemSleepDisabled == false {
            markers.remove()
            return
        }
        try system.setSleepDisabled(false)
        markers.remove()
        refresh()
    }

    /// At quit. Returns false if sleep is still disabled by cmds afterwards (dialog cancelled or failed); the
    /// marker then stays for the next launch.
    @discardableResult
    public func restoreOnQuit() -> Bool {
        guard ownedByCmds else { return true }
        do {
            try disable()
            return true
        } catch {
            return false
        }
    }

    /// The Mac switched power source. True when the user should be asked to turn the option off (on battery while
    /// cmds keeps the closed Mac awake).
    public func shouldOfferTurnOff(onBattery: Bool) -> Bool {
        onBattery && ownedByCmds && systemSleepDisabled != false
    }
}
