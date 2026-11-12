import AppKit
import CmdsCore
import Combine
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
///
/// This file: on / off, the microphone, speaking, the HUD and the clock. The rest by responsibility:
/// `+Listening` (utterances, keys, the machine's steps), `+Thinking` (planning and answers), `+Actions` (confirmed
/// cards), `+FollowThrough` (sessions given a task) and `+Debug` (`debug.assistant`). The state they share is internal
/// for them; nothing outside the assistant changes it.
@available(macOS 26.0, *)
@MainActor
final class AssistantController {
    private(set) static var shared: AssistantController?
    /// Posted when the state changes (menu bar item, Settings).
    static let didChange = Notification.Name("AssistantDidChange")

    let controller: AppController
    var machine = AssistantMachine()
    let hud = AssistantHUD()
    /// The small orb while it waits for its name (`+Presence`).
    let orb = AssistantIdleOrb()
    /// What of it is on screen: the orb, the HUD or nothing (`+Presence`).
    var presence: AssistantPresence.Shown = .none
    /// Whether the microphone picks up speech (the orb follows the level then).
    var hearing = AssistantPresence.Hearing()
    /// A presence update is due (state changes come in bursts).
    var presenceUpdatePending = false
    private var screenChanges: NSObjectProtocol?
    /// `debug.assistant` `on {mute, style, web, …}`: test parameters in effect until off or a relaunch, never written
    /// to the settings (a test must not leave the user's assistant muted or changed).
    var overrides = AssistantOverrides()
    var muted: Bool { overrides.muted ?? settings.assistantMuted }
    var style: AssistantStyle { overrides.style ?? settings.assistantStyle }
    var usesWeb: Bool { overrides.web ?? settings.assistantWeb }
    var usesInterpreter: Bool { overrides.interpreter ?? settings.assistantInterpreter }
    var reportsTasks: Bool { overrides.reportTasks ?? settings.assistantReportTasks }
    var projectFolders: String { overrides.projectFolders ?? settings.assistantProjectFolders }
    var showsWhileWaiting: Bool { overrides.showWhileWaiting ?? settings.assistantShowWhileWaiting }
    var orbSize: AssistantPresence.Size { overrides.orbSize ?? settings.assistantOrbSize }
    let voice = AssistantVoice()
    let listener = AssistantListener()
    private(set) var hotkeys: AssistantHotkeys?
    private var timer: Timer?
    /// Each spoken answer's number: only the latest one's end moves the machine on.
    var speech = 0
    /// When the HUD hides, after the assistant went back to standing by (`AssistantTuning.hudLinger`).
    private var hideAt: Date?
    /// The user said yes to an action that needs Return or a click.
    var needsKey = false
    /// When the card appeared: Return / Esc are ignored just after (`AssistantTuning.confirmArmDelay`).
    var pendingShownAt: Date?
    /// Whether the microphone is used; `debug.assistant` turns the assistant on without it.
    var usesMicrophone = true
    /// The microphone runs for one command after the hotkey while paused.
    var temporaryMicrophone = false
    /// The answer being worked out (`think`); cancelled when the user moves on.
    var work: Task<Void, Never>?
    /// The last thing said, and a problem to show (microphone denied…).
    private(set) var lastSpoken: String?
    private(set) var problem: String?
    /// The rest of an utterance with several requests, carried out one after the other after the first (and its card).
    var queued: [AssistantIntent] = []
    /// Workspaces started by an earlier step of the utterance: the later steps mean the workspaces as they were when
    /// it was said (a new one in api's folder is also called api).
    var createdForQueue: Set<String> = []
    /// The workspace the last request was about, and when: a start without a place goes there.
    var recent: (id: String, at: Date)?
    /// Sessions the assistant started with a task or sent an instruction to, followed until their agent is done
    /// (Settings › Assistant › Report on tasks I gave).
    var taskWatch = AssistantTaskWatch()
    /// Follow-through lines waiting for the assistant to be free.
    var announcements: [String] = []
    private var stateChanges: AnyCancellable?
    /// The words last handed to speech recognition as context.
    private(set) var vocabulary: [String] = []
    /// The machine's last step other than `.ignore` (`debug.assistant`).
    var lastStep: AssistantMachine.Step?
    /// The request the assistant asked back about ("Which one: api, api-v2?"), until the next command.
    var askedBack: AssistantIntent?
    /// Claude Code is working on the answer to this request (the HUD says so).
    var claudeWorkingFor: Int?
    var claudeWorking: Bool { claudeWorkingFor == machine.request }
    /// The answer being worked out came from Claude Code.
    var claudeAnswered = false
    /// The answer shown came from Claude Code (a small label on the HUD).
    private var answerByClaude = false
    /// A note shown instead of the answer (paused, goodbye, "press Return").
    private var hudNote: String?
    /// The current request's stage times, and the last few requests' (`+Timing`, #248).
    var timeline: AssistantTimeline?
    var timelines: [AssistantTimeline] = []

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
        listener.onUtterance = { [weak self] text, speechEnd in self?.hear(text, speechEnd: speechEnd) }
        listener.onLevel = { [weak self] level in self?.heard(level: level) }
        orb.onClick = { [weak self] in self?.showLast() }
        orb.onMoved = { [weak self] center in self?.orbMoved(to: center) }
        screenChanges = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AssistantController.shared?.updatePresence() }
        }
        listener.onStop = { [weak self] error in self?.microphoneStopped(error) }
        stateChanges = controller.changes.sink { [weak self] change in
            MainActor.assumeIsolated { self?.stateChanged(change) }
        }
    }

    var isUnlocked: Bool { PaidFeatures.isUnlocked(.assistant) }
    var isOn: Bool { machine.isOn }
    var isPaused: Bool { machine.phase == .paused }
    var settings: AppSettings { AppSettings.shared }
    var language: AssistantLanguage { .current }
    var names: [String] { AssistantAddressing.names(configured: settings.assistantNames) }

    private func settingsChanged() {
        updateVocabulary()
        hotkeys?.setListen(isOn ? settings.assistantHotkey : .off)
        if settings.assistantEnabled, isUnlocked, !isOn {
            turnOn()
        } else if !settings.assistantEnabled, isOn, usesMicrophone {
            turnOff()
        }
        refresh()
    }

    // MARK: On, off, pause

    /// `microphone` false: text only (`debug.assistant`).
    func turnOn(microphone: Bool = true) {
        guard isUnlocked else { return }
        guard !isOn else { return }
        usesMicrophone = microphone
        // Remembered for the next launch, but not the text-only mode of `debug.assistant`: a relaunched test instance
        // must never start the microphone (and with it a privacy prompt) by itself.
        if microphone, !settings.assistantEnabled { settings.assistantEnabled = true }
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
        hearing.reset()
        overrides = AssistantOverrides()
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
        hearing.reset()
        refresh()
    }

    func resume() {
        guard machine.phase == .paused else { return }
        machine.resume()
        startMicrophone()
        refresh()
    }

    func startMicrophone() {
        guard usesMicrophone, !listener.isRunning else { return }
        updateVocabulary()
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
        hearing.reset()
        refresh()
    }

    // MARK: Speaking

    /// Shows and speaks an answer (for `request`: not when the user has moved on since); the machine moves on when it
    /// has been said.
    func say(_ text: String, proposing action: AssistantAction? = nil, request: Int? = nil, capped: Bool = false,
             byClaude: Bool = false) {
        guard machine.answer(text, proposing: action, request: request, now: Date()) else { return }
        answerByClaude = byClaude
        refresh()
        speech += 1
        let number = speech
        speak(capped ? AssistantBrevity.spoken(text) : text) { [weak self] in
            guard let self, self.speech == number else { return }
            self.machine.speechFinished(now: Date())
            self.refresh()
            self.continueQueue()
        }
    }

    /// Speaks without changing the state (a note while a card waits, or after turning off).
    /// `muted`: as muted was before turning off (the goodbye of a test muted by `debug.assistant` stays silent).
    func speakOnly(_ text: String, muted: Bool? = nil) {
        lastSpoken = text
        if isOn { hideAt = Date().addingTimeInterval(AssistantTuning.hudLinger) }
        hudNote = text
        machine.voiceStarted(text)
        refresh()
        speech += 1
        let number = speech
        voice.speak(text, language: language.voiceLanguage, voice: settings.assistantVoice, rate: settings.assistantRate,
                    muted: muted ?? self.muted) { [weak self] in
            guard let self, self.speech == number else { return }
            self.machine.voiceFinished(now: Date())
        }
    }

    private func speak(_ text: String, finished: @escaping () -> Void) {
        lastSpoken = text
        hudNote = nil
        mark(.speechStart)
        let request = machine.request
        voice.speak(text, language: language.voiceLanguage, voice: settings.assistantVoice, rate: settings.assistantRate,
                    muted: muted, started: { [weak self] in self?.mark(.voiceStart, request: request) }, finished: finished)
    }

    // MARK: HUD and clock

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: AssistantTuning.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func tick() {
        let before = machine.phase
        let step = machine.tick(now: Date())
        if step != .ignore { perform(step) }
        taskWatch.expire(now: Date())
        if !announcements.isEmpty, [.idle, .listening, .paused].contains(machine.phase), !machine.voiceActive {
            speakOnly(announcements.removeFirst())
        }
        if machine.phase != before || hideAt.map({ Date() > $0 }) == true { refresh() }
    }

    /// The HUD shows while the assistant is addressed, thinks, speaks or waits, and a few seconds after (or after a
    /// click on the waiting orb); else the orb, when wanted.
    func refresh() {
        let phase = machine.phase
        let active = [.listening, .thinking, .speaking, .confirming].contains(phase)
        if active {
            hideAt = nil
        } else if hideAt == nil, hud.isVisible {
            hideAt = Date().addingTimeInterval(AssistantTuning.hudLinger)
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
        updatePresence()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// A click on the waiting orb: the HUD with the last thing said, for a few seconds.
    func showLast() {
        guard isOn else { return }
        hudNote = lastSpoken
        hideAt = Date().addingTimeInterval(AssistantTuning.hudLinger)
        refresh()
    }

    var hudContent: AssistantHUDContent {
        let world = AgentOverview.summary(controller)
        let rings = world.entries.compactMap { entry -> AssistantRingsView.Ring? in
            controller.workspace(id: entry.id).map { .init(title: $0.displayTitle, state: entry.state) }
        }
        return AssistantHUDContent(phase: machine.phase, attention: world.needingUserCount > 0,
                                   transcript: machine.transcript, answer: hudNote ?? machine.answer ?? problem,
                                   pending: machine.pending, needsKey: needsKey, rings: rings, style: style,
                                   claude: claudeMark)
    }

    /// "Asking Claude" while it works on the answer; "Claude" under an answer that came from it.
    private var claudeMark: AssistantHUDContent.ClaudeMark {
        if machine.phase == .thinking { return claudeWorking ? .working : .none }
        return answerByClaude && machine.answer != nil && hudNote == nil ? .answered : .none
    }

    // MARK: Recognition

    /// Hands speech recognition the words to expect: the names, Claude Code, Codex, cmds, the workspaces and agents.
    func updateVocabulary() {
        let workspaces = controller.workspaces
        let words = AssistantVocabulary.contextualStrings(
            names: names, titles: workspaces.map(\.displayTitle),
            agents: workspaces.compactMap { $0.primaryAgent?.usage.agent.displayName })
        guard words != vocabulary else { return }
        vocabulary = words
        listener.setVocabulary(words)
    }

    #if DEBUG
    /// `debug.assistant` `speak`: the assistant "says" `text` without a voice and stays speaking until `spoken`, to
    /// test what it hears meanwhile (its own voice, barge-in). `card`: the card that waits is being read out (a yes or
    /// no without the name answers it).
    func debugSpeak(_ text: String, card: Bool = false) {
        let pending = card ? machine.pending : nil
        interrupt()
        guard machine.answer(text, proposing: pending, now: Date()) else { return }
        answerByClaude = false
        lastSpoken = text
        hudNote = nil
        refresh()
    }

    func debugSpeechEnded() {
        machine.speechFinished(now: Date())
        refresh()
    }

    /// `debug.assistant` `problem`: shows `text` as the problem (microphone denied…) without touching the microphone;
    /// nil clears it.
    func debugSetProblem(_ text: String?) {
        problem = text
        refresh()
    }
    #endif
}
