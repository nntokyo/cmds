import AppKit
import CmdsCore
import IOKit.ps
import IOKit.pwr_mgt
import UserNotifications

/// Keeps the Mac awake for long-running agent sessions (docs/ARCHITECTURE.md "Keeping the Mac awake").
///
/// - Always (no admin): while cmds runs it holds a `PreventUserIdleSystemSleep` assertion (cmds › Prevent Idle Sleep,
///   default on) and, optionally, `PreventUserIdleDisplaySleep` (cmds › Keep Display Awake, default off).
///   Assertions die with the process, so nothing outlives cmds.
/// - Opt-in: cmds › Keep Awake With Lid Closed… turns the system-wide `SleepDisabled` setting on with
///   `pmset -a disablesleep 1` through macOS's administrator dialog, and off again when unchecked or at quit.
///   No unprivileged API prevents clamshell sleep. A marker file notices runs that ended without restoring.
///   Isolated instances (`CMDS_SUPPORT_DIR`) never prompt or change power settings.
@MainActor
final class KeepAwakeManager: NSObject, NSMenuItemValidation {
    static let shared = KeepAwakeManager()
    static let didChange = Notification.Name("KeepAwakeManagerDidChange")

    static let idleAssertionName = "cmds: keeping AI agent sessions running"
    static let displayAssertionName = "cmds: keeping the display on"
    private static let idleDefaultsKey = "KeepAwakePreventIdleSleep"
    private static let displayDefaultsKey = "KeepAwakeKeepDisplayOn"

    private let isolated = CmdsEnv.supportDirectoryOverride() != nil
    /// In-memory settings of an isolated instance (it never writes the live app's defaults).
    private var isolatedIdle = true
    private var isolatedDisplay = false

    private var idleAssertionID: IOPMAssertionID?
    private var displayAssertionID: IOPMAssertionID?
    let lid: LidSleepController
    private(set) var onBattery: Bool?
    private var powerSource: CFRunLoopSource?
    private var refreshTimer: Timer?
    private var batteryAlertShown = false
    private var busy = false

    override init() {
        let marker = CmdsEnv.supportDirectoryURL().appendingPathComponent("lid-sleep-disabled.json")
        lid = LidSleepController(isAvailable: CmdsEnv.supportDirectoryOverride() == nil,
                                 system: PmsetSleepSystem(), markers: FileLidSleepMarkerStore(url: marker))
        super.init()
    }

    // MARK: Settings

    var preventIdleSleep: Bool {
        get {
            if isolated { return isolatedIdle }
            return UserDefaults.standard.object(forKey: Self.idleDefaultsKey) as? Bool ?? true
        }
        set {
            if isolated { isolatedIdle = newValue } else { UserDefaults.standard.set(newValue, forKey: Self.idleDefaultsKey) }
            applyAssertions()
        }
    }

    var keepDisplayOn: Bool {
        get {
            if isolated { return isolatedDisplay }
            return UserDefaults.standard.bool(forKey: Self.displayDefaultsKey)
        }
        set {
            if isolated { isolatedDisplay = newValue } else { UserDefaults.standard.set(newValue, forKey: Self.displayDefaultsKey) }
            applyAssertions()
        }
    }

    var status: KeepAwakeStatus {
        KeepAwakeStatus(idleAssertion: idleAssertionID != nil, displayAssertion: displayAssertionID != nil,
                        lidCloseDisabled: lid.systemSleepDisabled, lidCloseByCmds: lid.ownedByCmds,
                        lidCloseAvailable: lid.isAvailable, onBattery: onBattery)
    }

    // MARK: Lifecycle

    func start() {
        applyAssertions()
        startPowerSourceMonitor()
        let check = lid.launchCheck()
        if check != .offerRestore { lid.refresh() }
        changed()
        if check == .offerRestore { offerRestoreFromEarlierRun() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { KeepAwakeManager.shared.refreshInBackground() }
        }
    }

    /// At quit: release the assertions and restore lid-close sleep if cmds turned it off (one admin dialog).
    func stop() {
        refreshTimer?.invalidate()
        release(&idleAssertionID)
        release(&displayAssertionID)
        if lid.ownedByCmds, !lid.restoreOnQuit() {
            NSLog("cmds: sleep is still disabled (pmset disablesleep 1); cmds offers to restore it at the next launch, "
                  + "or run: \(SleepDisabledCommand.manualRestore)")
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func refreshInBackground() {
        DispatchQueue.global(qos: .utility).async {
            let value = PmsetSleepSystem.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let manager = KeepAwakeManager.shared
                    guard !manager.busy, value != manager.lid.systemSleepDisabled else { return }
                    manager.lid.update(sleepDisabled: value)
                    manager.changed()
                }
            }
        }
    }

    // MARK: Assertions

    private func applyAssertions() {
        sync(&idleAssertionID, wanted: preventIdleSleep, type: kIOPMAssertPreventUserIdleSystemSleep, name: Self.idleAssertionName)
        sync(&displayAssertionID, wanted: keepDisplayOn, type: kIOPMAssertPreventUserIdleDisplaySleep, name: Self.displayAssertionName)
        changed()
    }

    private func sync(_ id: inout IOPMAssertionID?, wanted: Bool, type: String, name: String) {
        if wanted, id == nil {
            var newID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     name as CFString, &newID)
            if result == kIOReturnSuccess { id = newID } else { NSLog("cmds: IOPMAssertionCreateWithName failed: \(result)") }
        } else if !wanted {
            release(&id)
        }
    }

    private func release(_ id: inout IOPMAssertionID?) {
        if let current = id { IOPMAssertionRelease(current) }
        id = nil
    }

    // MARK: Power source

    private func startPowerSourceMonitor() {
        onBattery = Self.readOnBattery()
        let callback: IOPowerSourceCallbackType = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { KeepAwakeManager.shared.powerSourceChanged() } }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() else { return }
        powerSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private static func readOnBattery() -> Bool? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return nil }
        return type == kIOPMBatteryPowerKey
    }

    private func powerSourceChanged() {
        let now = Self.readOnBattery()
        guard now != onBattery else { return }
        onBattery = now
        changed()
        if now != true { batteryAlertShown = false; return }
        guard lid.shouldOfferTurnOff(onBattery: true), !batteryAlertShown else { return }
        batteryAlertShown = true
        postNotification(title: "Mac is on battery", body: "cmds keeps it awake with the lid closed. "
                         + "A closed Mac that never sleeps drains the battery and can overheat in a bag.")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Turn off Keep Awake With Lid Closed?"
        alert.informativeText = "This Mac switched to battery power. While the setting is on, closing the lid does not "
            + "put it to sleep — in a bag it keeps running, drains the battery and can get hot. macOS will ask for "
            + "your administrator password to turn it off."
        alert.addButton(withTitle: "Turn Off")
        alert.addButton(withTitle: "Keep Awake")
        present(alert) { response in
            if response == .alertFirstButtonReturn { KeepAwakeManager.shared.disableLid() }
        }
    }

    // MARK: Lid close

    private func offerRestoreFromEarlierRun() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Sleep is still disabled from an earlier cmds session"
        alert.informativeText = "cmds turned on \"Keep Awake With Lid Closed\" before and did not turn it off (it quit "
            + "unexpectedly, or the password dialog was cancelled). Your Mac currently does not sleep when you close the "
            + "lid. Restore normal sleep now? macOS will ask for your administrator password.\n\n"
            + "You can also run: \(SleepDisabledCommand.manualRestore)"
        alert.addButton(withTitle: "Restore Sleep")
        alert.addButton(withTitle: "Keep It Disabled")
        present(alert) { response in
            if response == .alertFirstButtonReturn { KeepAwakeManager.shared.disableLid() }
        }
    }

    @objc func toggleLidClose(_ sender: Any?) {
        guard lid.isAvailable, !busy else { return }
        switch lid.refresh() {
        case .onByCmds:
            disableLid()
        case .onOutsideCmds:
            let alert = NSAlert()
            alert.messageText = "Sleep is already disabled on this Mac"
            alert.informativeText = "Closing the lid already does not sleep this Mac, but the setting was not made by "
                + "cmds, so cmds leaves it alone. To restore normal sleep, run:\n\(SleepDisabledCommand.manualRestore)"
            present(alert) { _ in }
            changed()
        case .off, .unknown:
            confirmEnable()
        }
    }

    private func confirmEnable() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Keep this Mac awake with the lid closed?"
        var text = "Agents keep running when you close the lid. cmds changes a system-wide power setting "
            + "(pmset -a disablesleep 1) and changes it back when you turn this off or quit cmds. macOS asks for "
            + "your administrator password each time; cmds never sees it.\n\n"
            + "Caution: a closed Mac that never sleeps keeps running in a bag — it can overheat and drain the battery. "
            + "cmds asks you to turn this off when the Mac switches to battery. If cmds crashes or is force-quit, sleep "
            + "stays disabled until cmds starts again (it then offers to restore it) or you run "
            + "\(SleepDisabledCommand.manualRestore)."
        if onBattery == true { text += "\n\nThis Mac is on battery power right now." }
        alert.informativeText = text
        alert.addButton(withTitle: "Keep Awake…")
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in
            guard response == .alertFirstButtonReturn else { return }
            KeepAwakeManager.shared.run { try $0.enable() }
        }
    }

    func disableLid() {
        run { try $0.disable() }
    }

    /// Runs one lid change (shows the admin dialog) and reports failures other than cancelling.
    private func run(_ change: (LidSleepController) throws -> Void) {
        guard !busy else { return }
        busy = true
        defer {
            busy = false
            changed()
        }
        do {
            try change(lid)
        } catch LidSleepError.cancelled {
            return
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the sleep setting"
            alert.informativeText = "\(error)\n\nTo restore normal sleep by hand, run: \(SleepDisabledCommand.manualRestore)"
            present(alert) { _ in }
        }
    }

    private func present(_ alert: NSAlert, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        if let window = AppController.shared.window, window.isVisible {
            alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { completion(response) } }
        } else {
            completion(alert.runModal())
        }
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "cmds.keepawake.\(UUID().uuidString)",
                                                                     content: content, trigger: nil))
    }

    // MARK: Menu

    static func items() -> [NSMenuItem] {
        let idle = NSMenuItem(title: "Prevent Idle Sleep", action: #selector(toggleIdle(_:)), keyEquivalent: "")
        idle.toolTip = "While cmds runs, the Mac does not go to sleep when idle (the display may still turn off). "
            + "Closing the lid still sleeps it."
        let display = NSMenuItem(title: "Keep Display Awake", action: #selector(toggleDisplay(_:)), keyEquivalent: "")
        display.toolTip = "While cmds runs, the display does not turn off when idle."
        let lid = NSMenuItem(title: "Keep Awake With Lid Closed…", action: #selector(toggleLidClose(_:)), keyEquivalent: "")
        lid.toolTip = "Turns system sleep off (pmset disablesleep 1, asks for your administrator password) until you "
            + "turn this off or quit cmds."
        for item in [idle, display, lid] { item.target = shared }
        return [idle, display, lid]
    }

    @objc func toggleIdle(_ sender: Any?) { preventIdleSleep.toggle() }
    @objc func toggleDisplay(_ sender: Any?) { keepDisplayOn.toggle() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleIdle(_:)):
            menuItem.state = preventIdleSleep ? .on : .off
            return true
        case #selector(toggleDisplay(_:)):
            menuItem.state = keepDisplayOn ? .on : .off
            return true
        case #selector(toggleLidClose(_:)):
            switch lid.state {
            case .onByCmds:
                menuItem.state = .on
                menuItem.title = "Keep Awake With Lid Closed"
            case .onOutsideCmds:
                menuItem.state = .mixed
                menuItem.title = "Keep Awake With Lid Closed (set outside cmds)"
            case .off, .unknown:
                menuItem.state = .off
                menuItem.title = "Keep Awake With Lid Closed…"
            }
            if !lid.isAvailable { menuItem.title = "Keep Awake With Lid Closed (not in test instances)" }
            return lid.isAvailable && !busy
        default:
            return true
        }
    }
}

/// `SleepDisabled` via `/usr/bin/pmset`: `-g` to read (unprivileged), `-a disablesleep 1/0` through
/// `NSAppleScript … with administrator privileges` (macOS's own password dialog). Main thread only for writes.
final class PmsetSleepSystem: SleepDisabledSystem {
    static func read() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SleepDisabledCommand.pmsetPath)
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return SleepDisabledCommand.parseSleepDisabled(pmsetOutput: String(decoding: data, as: UTF8.self))
    }

    func readSleepDisabled() -> Bool? { Self.read() }

    func setSleepDisabled(_ disabled: Bool) throws {
        precondition(Thread.isMainThread)
        guard CmdsEnv.supportDirectoryOverride() == nil else { throw LidSleepError.unavailable }
        guard let script = NSAppleScript(source: SleepDisabledCommand.appleScript(sleepDisabled: disabled)) else {
            throw LidSleepError.failed("could not build the AppleScript")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { throw LidSleepError.cancelled }
        throw LidSleepError.failed(error[NSAppleScript.errorMessage] as? String ?? "pmset failed")
    }
}
