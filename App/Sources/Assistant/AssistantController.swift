import AppKit
import CmdsCore
import os

private let assistantLog = Logger(subsystem: "tokyo.n-n.cmds", category: "assistant")

/// The voice assistant, "JARVIS" (#243; macOS 26 and later, free during its beta: `PaidFeatures`). Ties the parts
/// together: the microphone (`AssistantListener`), the rules in CmdsCore (`AssistantMachine`: addressing, states,
/// confirmation; `AssistantIntent` and `AssistantPlanner`: what was asked and what to do), the answers
/// (`AssistantBrain`: on-device model, `claude -p` on request), the voice (`AssistantVoice`), the HUD
/// (`AssistantHUD`) and the global keys (`AssistantHotkeys`).
///
/// Voice alone only answers. Everything that acts goes through `AssistantMachine.pending`: shown on the HUD's card,
/// carried out by `run(_:)` only after yes / Return / a click (Return or a click only for dangerous text and SSH
/// panes), through the same paths as the menu bar's reply panel.
///
/// Isolated instances (`CMDS_SUPPORT_DIR`) register no global keys, so a test never takes Return or ⌥⌘J from the app
/// in use; `debug.assistant` drives them with text instead of the microphone.
@available(macOS 26.0, *)
@MainActor
final class AssistantController {
    private(set) static var shared: AssistantController?
    /// Posted when the state changes (menu bar item, Settings).
    static let didChange = Notification.Name("AssistantDidChange")

    let controller: AppController
    private(set) var machine = AssistantMachine()
    let hud = AssistantHUD()
    private let voice = AssistantVoice()
    private let listener = AssistantListener()
    private var hotkeys: AssistantHotkeys?
    private var timer: Timer?
    /// Each spoken answer's number: only the latest one's end moves the machine on.
    private var speech = 0
    /// The HUD stays this long after the assistant went back to standing by.
    private static let hudLinger: TimeInterval = 6
    private var hideAt: Date?
    /// The user said yes to an action that needs Return or a click.
    private var needsKey = false
    /// Return / Esc are ignored this long after a card appears (a Return already on its way to the terminal).
    private static let confirmArmDelay: TimeInterval = 0.8
    private var pendingShownAt: Date?
    /// Whether the microphone is used; `debug.assistant` turns the assistant on without it.
    private var usesMicrophone = true
    /// The microphone runs for one command after the hotkey while paused.
    private var temporaryMicrophone = false
    private var work: Task<Void, Never>?
    /// The last thing said, and a problem to show (microphone denied…).
    private(set) var lastSpoken: String?
    private(set) var problem: String?
    private(set) var lastStep: AssistantMachine.Step?

    static var isSupported: Bool { true }

    /// Created at launch (AppDelegate); turns itself on when the user had it on.
    static func start(controller: AppController) {
        let assistant = AssistantController(controller: controller)
        shared = assistant
        NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AssistantController.shared?.settingsChanged() }
        }
        assistant.settingsChanged()
    }

    private init(controller: AppController) {
        self.controller = controller
        if CmdsEnv.supportDirectoryOverride() == nil {
            let hotkeys = AssistantHotkeys()
            hotkeys.onKey = { [weak self] key in self?.globalKey(key) }
            self.hotkeys = hotkeys
        }
        hud.onConfirm = { [weak self] in self?.key(.confirm) }
        hud.onCancel = { [weak self] in self?.key(.cancel) }
        listener.onUtterance = { [weak self] text in self?.hear(text) }
        listener.onLevel = { [weak self] level in self?.hud.level(level) }
        listener.onStop = { [weak self] error in self?.microphoneStopped(error) }
    }

    var isUnlocked: Bool { PaidFeatures.isUnlocked(.assistant) }
    var isOn: Bool { machine.isOn }
    var isPaused: Bool { machine.phase == .paused }
    private var settings: AppSettings { AppSettings.shared }
    private var language: AssistantLanguage { .current }
    private var names: [String] { AssistantAddressing.names(configured: settings.assistantNames) }

    private func settingsChanged() {
        hotkeys?.setListen(isOn ? settings.assistantHotkey : .off)
        if settings.assistantEnabled, isUnlocked, !isOn {
            turnOn()
        } else if !settings.assistantEnabled, isOn {
            turnOff()
        }
        refresh()
    }

    // MARK: On, off, pause

    /// `microphone` false: text only (`debug.assistant`).
    func turnOn(microphone: Bool = true) {
        guard isUnlocked else { return }
        usesMicrophone = microphone
        if !settings.assistantEnabled { settings.assistantEnabled = true }
        guard !isOn else { return }
        machine.turnOn()
        problem = nil
        hotkeys?.setListen(settings.assistantHotkey)
        startMicrophone()
        startTimer()
        assistantLog.info("assistant on (microphone: \(microphone))")
        refresh()
    }

    func turnOff() {
        work?.cancel()
        machine.turnOff()
        listener.stop()
        speech += 1
        voice.stop()
        hotkeys?.setListen(.off)
        hotkeys?.setConfirmationKeys(false)
        timer?.invalidate()
        timer = nil
        hud.hide()
        if settings.assistantEnabled { settings.assistantEnabled = false }
        assistantLog.info("assistant off")
        refresh()
    }

    func pause() {
        guard isOn else { return }
        work?.cancel()
        speech += 1
        voice.stop()
        machine.pause()
        listener.stop()
        refresh()
    }

    func resume() {
        guard machine.phase == .paused else { return }
        machine.resume()
        startMicrophone()
        refresh()
    }

    private func startMicrophone() {
        guard usesMicrophone, !listener.isRunning else { return }
        let locale = language.locale
        Task { [weak self] in
            do {
                try await self?.listener.start(locale: locale)
            } catch {
                self?.microphoneStopped(error)
            }
        }
    }

    private func microphoneStopped(_ error: Error?) {
        guard let error else { return }
        assistantLog.error("assistant microphone stopped: \(String(describing: error), privacy: .public)")
        switch error {
        case AssistantListener.Failure.microphoneDenied:
            problem = String(localized: "cmds may not use the microphone. Allow it in System Settings › Privacy & Security › Microphone.", comment: "assistant problem")
        case AssistantListener.Failure.speechDenied:
            problem = String(localized: "cmds may not use speech recognition. Allow it in System Settings › Privacy & Security › Speech Recognition.", comment: "assistant problem")
        case AssistantListener.Failure.languageUnsupported:
            problem = String(localized: "Speech recognition on this Mac does not support the app's language.", comment: "assistant problem")
        default:
            problem = String(localized: "The microphone stopped: \(error.localizedDescription)", comment: "assistant problem")
        }
        if isOn, machine.phase != .paused { machine.pause() }
        refresh()
    }

    // MARK: Input

    /// A finished utterance from the microphone (or `debug.assistant`). Not addressed: dropped here, unstored.
    func hear(_ text: String) {
        let step = machine.hear(text, names: names, now: Date())
        perform(step)
    }

    /// The listen shortcut.
    func hotkey() {
        guard isOn else { return }
        machine.hotkey(now: Date())
        if machine.phase == .listening, !listener.isRunning, usesMicrophone {
            temporaryMicrophone = true
            startMicrophone()
        }
        refresh()
    }

    /// Return / Esc (while the card shows) and the card's buttons.
    func key(_ key: AssistantMachine.Key) {
        perform(machine.key(key, now: Date()))
    }

    private func globalKey(_ key: AssistantHotkeys.Key) {
        switch key {
        case .listen: hotkey()
        case .confirm, .enter, .cancel:
            if let shown = pendingShownAt, Date().timeIntervalSince(shown) < Self.confirmArmDelay { return }
            self.key(key == .cancel ? .cancel : .confirm)
        }
    }

    private func perform(_ step: AssistantMachine.Step) {
        if step != .ignore { lastStep = step }
        switch step {
        case .ignore:
            return
        case .wake:
            refresh()
        case .handle(let intent):
            assistantLog.info("assistant command: \(String(describing: intent).prefix(24), privacy: .private)")
            refresh()
            let world = AgentOverview.assistantWorld(controller)
            let plan = AssistantPlanner.plan(intent, world: world, strings: .localized) { path in
                var isFolder: ObjCBool = false
                return FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath, isDirectory: &isFolder)
                    && isFolder.boolValue
            }
            carryOut(plan, world: world)
        case .execute(let action):
            run(action)
        case .cancelled:
            say(AssistantStrings.localized(.cancelled))
        case .needsKey:
            needsKey = true
            speakOnly(AssistantStrings.localized(.voiceNotEnough))
        case .expired:
            say(AssistantStrings.localized(.expired))
        }
    }

    // MARK: Answers

    private func carryOut(_ plan: AssistantPlan, world: AssistantWorld) {
        let strings = AssistantStrings.localized
        switch plan {
        case .answer(let text), .askBack(let text):
            say(text)
        case .propose(let action, let prompt):
            needsKey = false
            pendingShownAt = Date()
            say(prompt, proposing: action)
        case .summarize(let workspaceID, let paneID, let detailed, let fallback):
            let screen = paneID.flatMap { try? controller.readText(paneID: $0, scrollback: 120) } ?? ""
            think {
                guard !screen.isEmpty else { return fallback }
                do {
                    if detailed {
                        return try await AssistantBrain.detailedSummary(facts: fallback, screen: screen, language: self.language)
                    }
                    guard AssistantBrain.modelAvailable else { return fallback }
                    let summary = try await AssistantBrain.summarize(facts: fallback, screen: screen, language: self.language)
                    return summary.isEmpty ? fallback : summary
                } catch {
                    assistantLog.error("assistant summary of \(workspaceID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    return fallback
                }
            }
        case .ask(let question):
            guard AssistantBrain.modelAvailable else { return say(strings(.modelUnavailable)) }
            let status = AssistantReport.status(world, strings: .english)
            think {
                do {
                    return try await AssistantBrain.answer(question, status: status, language: self.language)
                } catch {
                    return strings(.modelUnavailable)
                }
            }
        case .pauseListening:
            pause()
            speakOnly(strings(.paused))
        case .stop:
            let text = strings(.goodbye)
            turnOff()
            speakOnly(text)
        case .confirm, .cancel:
            say(strings(.nothingToConfirm))
        }
    }

    /// Works out an answer off the main actor's way, then says it (dropped when the assistant moved on).
    private func think(_ body: @escaping @MainActor () async -> String) {
        work?.cancel()
        work = Task { [weak self] in
            let text = await body()
            guard let self, !Task.isCancelled, self.machine.phase == .thinking else { return }
            self.say(text)
        }
    }

    /// Shows and speaks an answer; the machine moves on when it has been said.
    private func say(_ text: String, proposing action: AssistantAction? = nil) {
        machine.answer(text, proposing: action, now: Date())
        refresh()
        speech += 1
        let number = speech
        speak(text) { [weak self] in
            guard let self, self.speech == number else { return }
            self.machine.speechFinished(now: Date())
            self.refresh()
        }
    }

    /// Speaks without changing the state (a note while a card waits, or after turning off).
    private func speakOnly(_ text: String) {
        lastSpoken = text
        if isOn { hideAt = Date().addingTimeInterval(Self.hudLinger) }
        hudNote = text
        refresh()
        speech += 1
        voice.speak(text, language: language.voiceLanguage, voice: settings.assistantVoice, rate: settings.assistantRate,
                    muted: settings.assistantMuted) {}
    }

    /// A note shown instead of the answer (paused, goodbye, "press Return").
    private var hudNote: String?

    private func speak(_ text: String, finished: @escaping () -> Void) {
        lastSpoken = text
        hudNote = nil
        voice.speak(text, language: language.voiceLanguage, voice: settings.assistantVoice, rate: settings.assistantRate,
                    muted: settings.assistantMuted, finished: finished)
    }

    // MARK: Actions

    /// Carries out a confirmed action through the app's own paths (as the menu bar's reply panel does). The target
    /// pane is checked again: it must still exist in the same workspace.
    private func run(_ action: AssistantAction) {
        let strings = AssistantStrings.localized
        pendingShownAt = nil
        assistantLog.info("assistant runs a confirmed action in \(action.workspaceID ?? "new", privacy: .public)/\(action.paneID ?? "-", privacy: .public)")
        switch action.kind {
        case .reply, .choose:
            guard let paneID = action.paneID, let pane = controller.pane(id: paneID), pane.workspaceID == action.workspaceID,
                  pane.terminal != nil else { return say(strings(.failed)) }
            do {
                if case .choose = action.kind {
                    try controller.typeText(paneID: paneID, text: action.text)
                } else {
                    try controller.sendText(paneID: paneID, text: action.text)
                    DispatchQueue.main.asyncAfter(deadline: .now() + ScheduleRunTiming.enterDelay) { [controller] in
                        try? controller.typeText(paneID: paneID, text: "\r")
                    }
                }
                say(strings(.sent(workspace: action.workspaceTitle)))
            } catch {
                say(strings(.failed))
            }
        case .startAgent(let kind, let directory):
            let path = (directory as NSString).expandingTildeInPath
            controller.createWorkspace(cwd: path, command: action.text, select: false)
            say(strings(.started(agent: kind.displayName, place: action.workspaceTitle)))
        }
    }

    // MARK: HUD and clock

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let before = machine.phase
        let step = machine.tick(now: Date())
        if step != .ignore { perform(step) }
        if machine.phase != before || hideAt.map({ Date() > $0 }) == true { refresh() }
    }

    /// The HUD shows while the assistant is addressed, thinks, speaks or waits, and a few seconds after.
    func refresh() {
        let phase = machine.phase
        let active = [.listening, .thinking, .speaking, .confirming].contains(phase)
        if active {
            hideAt = nil
        } else if hideAt == nil, hud.isVisible {
            hideAt = Date().addingTimeInterval(Self.hudLinger)
        }
        // The microphone taken by the hotkey while paused goes off again.
        if temporaryMicrophone, phase == .paused {
            temporaryMicrophone = false
            listener.stop()
        }
        if !active, phase != .confirming { needsKey = false }
        hotkeys?.setConfirmationKeys(machine.pending != nil)
        if (active || hideAt.map { Date() < $0 } == true) && (isOn || hudNote != nil) {
            hud.show(hudContent)
        } else {
            hud.hide()
            hudNote = nil
            hideAt = nil
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    var hudContent: AssistantHUDContent {
        let world = AgentOverview.summary(controller)
        let rings = world.entries.compactMap { entry -> AssistantRingsView.Ring? in
            controller.workspace(id: entry.id).map { .init(title: $0.displayTitle, state: entry.state) }
        }
        return AssistantHUDContent(phase: machine.phase, attention: world.needingUserCount > 0,
                                   transcript: machine.transcript, answer: hudNote ?? machine.answer ?? problem,
                                   pending: machine.pending, needsKey: needsKey, rings: rings, style: settings.assistantStyle)
    }

    /// Phase 2 hook (#243, proactive announcements, opt-in): called when the workspaces' states change, e.g. to say
    /// "api needs you". Does nothing in the MVP.
    func workspacesChanged(_ summary: MenuBarSummary) {}

    #if DEBUG
    var debugUsesMicrophone: Bool { usesMicrophone }
    var debugConfirmationKeys: Bool { hotkeys?.confirmationKeysOn ?? false }
    #endif
}
