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
    /// When the HUD hides, after the assistant went back to standing by (`AssistantTuning.hudLinger`).
    private var hideAt: Date?
    /// The user said yes to an action that needs Return or a click.
    private var needsKey = false
    /// When the card appeared: Return / Esc are ignored just after (`AssistantTuning.confirmArmDelay`).
    private var pendingShownAt: Date?
    /// Whether the microphone is used; `debug.assistant` turns the assistant on without it.
    private var usesMicrophone = true
    /// The microphone runs for one command after the hotkey while paused.
    private var temporaryMicrophone = false
    private var work: Task<Void, Never>?
    /// The last thing said, and a problem to show (microphone denied…).
    private(set) var lastSpoken: String?
    private(set) var problem: String?
    /// The rest of an utterance with several requests, carried out one after the other after the first (and its card).
    private var queued: [AssistantIntent] = []
    /// Workspaces started by an earlier step of the utterance: the later steps mean the workspaces as they were when
    /// it was said (a new one in api's folder is also called api).
    private var createdForQueue: Set<String> = []
    /// The workspace the last request was about, and when: a start without a place goes there.
    private var recent: (id: String, at: Date)?
    /// Sessions the assistant started with a task or sent an instruction to, followed until their agent is done
    /// (Settings › Assistant › Report on tasks I gave).
    private var taskWatch = AssistantTaskWatch()
    /// Follow-through lines waiting for the assistant to be free.
    private var announcements: [String] = []
    private var stateChanges: AnyCancellable?
    /// The words last handed to speech recognition as context.
    private var vocabulary: [String] = []
    private(set) var lastStep: AssistantMachine.Step?

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
        stateChanges = controller.changes.sink { [weak self] change in
            MainActor.assumeIsolated { self?.stateChanged(change) }
        }
    }

    var isUnlocked: Bool { PaidFeatures.isUnlocked(.assistant) }
    var isOn: Bool { machine.isOn }
    var isPaused: Bool { machine.phase == .paused }
    private var settings: AppSettings { AppSettings.shared }
    private var language: AssistantLanguage { .current }
    private var names: [String] { AssistantAddressing.names(configured: settings.assistantNames) }

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
        refresh()
    }

    // MARK: Input

    /// A finished utterance from the microphone (or `debug.assistant`). Not addressed: dropped here, unstored.
    /// Said by name while the assistant speaks or works (barge-in), it stops that first; the HUD shows the new
    /// transcript at once.
    func hear(_ text: String) {
        let request = machine.request
        let step = machine.hear(text, names: names, now: Date())
        if machine.request != request { interrupt() }
        perform(step)
    }

    /// The listen shortcut.
    func hotkey() {
        guard isOn else { return }
        let request = machine.request
        machine.hotkey(now: Date())
        if machine.request != request { interrupt() }
        if machine.phase == .listening, !listener.isRunning, usesMicrophone {
            temporaryMicrophone = true
            startMicrophone()
        }
        refresh()
    }

    /// Return / Esc (while the card shows) and the card's buttons.
    func key(_ key: AssistantMachine.Key) {
        let request = machine.request
        let step = machine.key(key, now: Date())
        if machine.request != request { interrupt() }
        perform(step)
    }

    /// Stops what the assistant was saying or working out (a new request, barge-in): the voice, and the task with its
    /// `claude` process (cancelled: `AssistantBrain` terminates it). A late answer is dropped by its request number.
    private func interrupt() {
        speech += 1
        voice.stop()
        work?.cancel()
        work = nil
        claudeWorkingFor = nil
    }

    private func globalKey(_ key: AssistantHotkeys.Key) {
        switch key {
        case .listen: hotkey()
        case .confirm, .enter, .cancel:
            if let shown = pendingShownAt, Date().timeIntervalSince(shown) < AssistantTuning.confirmArmDelay { return }
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
        case .handle(var intent):
            // The answer to "Which one?": the request asked back about, aimed at the workspace named. The rest of its
            // utterance still follows; any other new request drops it.
            if let previous = askedBack, case .question(let answer) = intent, let retargeted = previous.retargeted(answer) {
                intent = retargeted
            } else {
                queued = []
                createdForQueue = []
            }
            askedBack = nil
            assistantLog.info("assistant command: \(String(describing: intent).prefix(24), privacy: .private)")
            refresh()
            handle(intent)
        case .execute(let action):
            run(action)
        case .cancelled:
            // No to a card is no to the rest of that utterance as well.
            queued = []
            say(AssistantStrings.localized(.cancelled))
        case .needsKey:
            needsKey = true
            speakOnly(AssistantStrings.localized(.voiceNotEnough))
        case .expired:
            queued = []
            say(AssistantStrings.localized(.expired))
        }
    }

    // MARK: Answers

    /// The request the assistant asked back about ("Which one: api, api-v2?"), until the next command.
    private var askedBack: AssistantIntent?

    /// Plans what was asked against the workspaces as they are now, and carries it out.
    private func handle(_ intent: AssistantIntent) {
        // Several requests in one utterance: the first now (its card says what comes next), the rest after it.
        var asked = intent
        if case .sequence(let intents) = intent, let first = intents.first {
            queued = Array(intents.dropFirst())
            createdForQueue = []
            asked = first
        }
        let world = currentWorld()
        let plan = AssistantPlanner.plan(intent, world: world, strings: .localized, directoryExists: Self.isFolder,
                                         folders: { [settings] name in
                                             AssistantPlaces(roots: AssistantPlaces.roots(setting: settings.assistantProjectFolders,
                                                                                          home: NSHomeDirectory(), exists: Self.isFolder)).find(name)
                                         }, executable: Self.agentExecutable)
        remember(plan)
        carryOut(plan, world: world, asked: asked)
    }

    private static func isFolder(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath, isDirectory: &isFolder)
            && isFolder.boolValue
    }

    /// Debug builds only: `CMDS_ASSISTANT_AGENT_EXECUTABLE` (an absolute path) runs instead of `claude` / `codex` when
    /// the assistant starts an agent, so tests can confirm a start without running a real agent.
    private static var agentExecutable: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["CMDS_ASSISTANT_AGENT_EXECUTABLE"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        #else
        nil
        #endif
    }

    /// The workspaces now, with the selected one and the one the last request was about.
    private func currentWorld() -> AssistantWorld {
        var world = AgentOverview.assistantWorld(controller)
        world.workspaces.removeAll { createdForQueue.contains($0.id) }
        world.focusedID = controller.selectedWorkspaceID
        if let recent, Date().timeIntervalSince(recent.at) < AssistantTuning.recentFor { world.recentID = recent.id }
        return world
    }

    /// Notes the workspace a request was about.
    private func remember(_ plan: AssistantPlan) {
        switch plan {
        case .summarize(let id, _, _, _): recent = (id, Date())
        case .propose(let action, _): if let id = action.workspaceID { recent = (id, Date()) }
        default: break
        }
    }

    /// The next request of the utterance, once the one before has been answered (and its card confirmed).
    private func continueQueue() {
        guard !queued.isEmpty, askedBack == nil, machine.proceed() else { return }
        let next = queued.removeFirst()
        refresh()
        handle(next)
    }

    private func carryOut(_ plan: AssistantPlan, world: AssistantWorld, asked: AssistantIntent) {
        let strings = AssistantStrings.localized
        switch plan {
        case .answer(let text):
            say(text)
        case .askBack(let text):
            say(text)
            askedBack = asked
        case .propose(let action, let prompt):
            needsKey = false
            pendingShownAt = Date()
            say(prompt, proposing: action)
        case .summarize(let workspaceID, let paneID, let detailed, let fallback):
            let screen = paneID.flatMap { try? controller.readText(paneID: $0, scrollback: AssistantTuning.summaryScrollback) } ?? ""
            think(capped: !detailed) { await self.summary(of: workspaceID, facts: fallback, screen: screen, detailed: detailed) }
        case .summarizeEach(let items, let detailed):
            // One session after the other, a line each (spoken in turn, listed on the HUD).
            let screens = items.map { item in item.paneID.flatMap { try? controller.readText(paneID: $0, scrollback: AssistantTuning.summaryScrollback) } ?? "" }
            think {
                var lines: [String] = []
                for (item, screen) in zip(items, screens) {
                    if Task.isCancelled { return nil }
                    let summary = await self.summary(of: item.workspaceID, facts: item.fallback, screen: screen, detailed: detailed)
                    lines.append(strings(.session(workspace: item.title, summary: summary)))
                }
                return lines.joined(separator: "\n")
            }
        case .ask(let question):
            // A free command for the agents ("api の Claude にテストを書くよう指示して"): the interpreter (`claude -p`, no
            // tools) turns it into a proposal, planned and confirmed like any other command. Else it is a question.
            if settings.assistantInterpreter, AssistantInterpretation.mightBeCommand(question, world: world) {
                let request = machine.request
                return think(capped: true) {
                    if await self.handleAsCommand(question, world: world, request: request) { return nil }
                    return await self.answer(question, world: world, interpreted: true)
                }
            }
            think(capped: true) { await self.answer(question, world: world, interpreted: false) }
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

    /// What a session's agent is doing: by the on-device model, or by `claude -p` when `detailed`; the facts when there
    /// is no screen, no model or it fails.
    private func summary(of workspaceID: String, facts: String, screen: String, detailed: Bool) async -> String {
        guard !screen.isEmpty else { return facts }
        do {
            if detailed {
                let summary = try await askingClaude(answers: true) {
                    try await AssistantBrain.detailedSummary(facts: facts, screen: screen, language: language)
                }
                return AssistantBrevity.first(3, of: summary)
            }
            guard AssistantBrain.modelAvailable else { return facts }
            // One sentence a session ("api: テストを実行中。").
            let summary = AssistantBrevity.first(1, of: try await AssistantBrain.summarize(facts: facts, screen: screen, language: language))
            // A marker or a bracketed word ("[START]") is no summary.
            return AssistantModelReply.isSummary(summary) ? summary : facts
        } catch {
            assistantLog.error("assistant summary of \(workspaceID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return facts
        }
    }

    /// A free question: Claude with web search for weather, news, "search…" (Settings › Assistant, on by default),
    /// else the on-device model, and Claude after all when the model answers that it needs current information. When
    /// the model takes it for an action (or apologises that it cannot act), it is never spoken: the interpreter gets it
    /// (unless it already had it), else the assistant says how to ask. nil: it went on as a command.
    private func answer(_ question: String, world: AssistantWorld, interpreted: Bool) async -> String? {
        let strings = AssistantStrings.localized
        let web = settings.assistantWeb
        if web, AssistantWeb.needsWeb(question) { return await webAnswer(question) }
        guard AssistantBrain.modelAvailable else { return strings(.modelUnavailable) }
        let status = AssistantReport.status(world, strings: .english)
        do {
            let answer = try await AssistantBrain.answer(question, status: status, language: language, web: web)
            if web, AssistantWeb.answerNeedsWeb(answer) { return await webAnswer(question) }
            if AssistantModelReply.isAction(answer) {
                if !interpreted, settings.assistantInterpreter,
                   await handleAsCommand(question, world: world, request: machine.request) { return nil }
                return strings(.cannotTell)
            }
            let text = AssistantWeb.withoutMarker(answer)
            return text.isEmpty ? strings(.modelUnavailable) : text
        } catch {
            return strings(.modelUnavailable)
        }
    }

    /// A free command as an intent, by the interpreter; nil when it is a question, `claude` is missing or fails.
    private func interpret(_ utterance: String, world: AssistantWorld) async -> AssistantIntent? {
        do {
            let output = try await askingClaude {
                try await AssistantBrain.interpret(utterance: utterance, world: world, language: language)
            }
            let intent = AssistantInterpretation.parse(output)?.intent(in: world)
            assistantLog.info("assistant interpreted a free command: \(intent.map { String(describing: $0).prefix(24) } ?? "question", privacy: .private)")
            return intent
        } catch {
            assistantLog.error("assistant interpreter failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// A question for Claude Code with web search (`AssistantBrain.webAnswer`); a short note when it is missing, fails
    /// or takes too long.
    private func webAnswer(_ question: String) async -> String {
        let strings = AssistantStrings.localized
        do {
            return try await askingClaude(answers: true) { try await AssistantBrain.webAnswer(question: question, language: language) }
        } catch AssistantClaudeProcess.Failure.notFound {
            return strings(.claudeNotFound)
        } catch {
            assistantLog.error("assistant web answer failed: \(String(describing: error), privacy: .public)")
            return strings(.webFailed)
        }
    }

    /// Claude Code is working on the answer to this request (the HUD says so).
    private var claudeWorkingFor: Int?
    private var claudeWorking: Bool { claudeWorkingFor == machine.request }
    /// The answer being worked out came from Claude Code.
    private var claudeAnswered = false

    /// A `claude -p` call for the current request, with "Asking Claude…" on the HUD while it runs (when it ends or is
    /// stopped, a newer request's mark stays). `answers`: what it returns is the answer, labelled as Claude's (not when
    /// the user has moved on since).
    private func askingClaude<T>(answers: Bool = false, _ call: () async throws -> T) async rethrows -> T {
        let request = machine.request
        claudeWorkingFor = request
        refresh()
        defer { if claudeWorkingFor == request { claudeWorkingFor = nil } }
        let result = try await call()
        if answers, machine.request == request { claudeAnswered = true }
        return result
    }

    /// A free command the rules did not understand, worked out by the interpreter and planned like any other (unless
    /// the user has moved on from `request` meanwhile). False when the interpreter makes no command of it: then it is a
    /// question.
    private func handleAsCommand(_ utterance: String, world: AssistantWorld, request: Int) async -> Bool {
        guard let intent = await interpret(utterance, world: world) else { return false }
        if !Task.isCancelled, machine.request == request, machine.phase == .thinking { handle(intent) }
        return true
    }
    /// The answer shown came from Claude Code (a small label on the HUD).
    private var answerByClaude = false

    /// Works out an answer off the main actor's way, then says it (dropped when the user has moved on to another
    /// request; nil: the body already went on another way). `capped`: a long answer is spoken only up to its first
    /// sentence (`AssistantBrevity.spoken`); the HUD shows it all.
    private func think(capped: Bool = false, _ body: @escaping @MainActor () async -> String?) {
        work?.cancel()
        claudeAnswered = false
        let request = machine.request
        work = Task { [weak self] in
            let text = await body()
            guard let self, let text, !Task.isCancelled, self.machine.request == request, self.machine.phase == .thinking else { return }
            self.say(text, request: request, capped: capped, byClaude: self.claudeAnswered)
        }
    }

    /// Shows and speaks an answer (for `request`: not when the user has moved on since); the machine moves on when it
    /// has been said.
    private func say(_ text: String, proposing action: AssistantAction? = nil, request: Int? = nil, capped: Bool = false,
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
    private func speakOnly(_ text: String) {
        lastSpoken = text
        if isOn { hideAt = Date().addingTimeInterval(AssistantTuning.hudLinger) }
        hudNote = text
        machine.voiceStarted(text)
        refresh()
        speech += 1
        let number = speech
        voice.speak(text, language: language.voiceLanguage, voice: settings.assistantVoice, rate: settings.assistantRate,
                    muted: settings.assistantMuted) { [weak self] in
            guard let self, self.speech == number else { return }
            self.machine.voiceFinished(now: Date())
        }
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
        // One card for several sessions: each goes to its own pane, checked again one by one.
        let actions = action.all
        if actions.count > 1 {
            let failed = actions.filter { !send($0) }.map(\.workspaceTitle)
            var lines: [AssistantLine] = []
            if failed.count < actions.count { lines.append(.sentMany(count: actions.count - failed.count)) }
            if !failed.isEmpty { lines.append(.failedIn(failed)) }
            return say(strings.join(lines))
        }
        switch action.kind {
        case .reply, .choose:
            say(send(action) ? strings(.sent(workspace: action.workspaceTitle)) : strings(.failed))
        case .startAgent(let kind, let directory, let task):
            // A new workspace in the folder running the agent, its task as the first prompt (one quoted argument).
            let path = (directory as NSString).expandingTildeInPath
            let info = controller.createWorkspace(cwd: path, command: action.text, select: false)
            recent = (info.id, Date())
            if !queued.isEmpty { createdForQueue.insert(info.id) }
            if task != nil, let pane = controller.workspace(id: info.id)?.orderedPanes.first {
                taskWatch.watch(paneID: pane.id, workspaceID: info.id, agent: kind.displayName, current: .none, now: Date())
            }
            say(strings(.started(agent: kind.displayName, place: action.workspaceTitle)))
        }
    }

    /// Types a reply (then Return) or an option's digit into the action's pane, if it is still in the same workspace.
    private func send(_ action: AssistantAction) -> Bool {
        assistantLog.info("assistant runs a confirmed action in \(action.workspaceID ?? "new", privacy: .public)/\(action.paneID ?? "-", privacy: .public)")
        guard let paneID = action.paneID, let pane = controller.pane(id: paneID), pane.workspaceID == action.workspaceID,
              pane.terminal != nil else { return false }
        do {
            switch action.kind {
            case .choose:
                try controller.typeText(paneID: paneID, text: action.text)
            case .reply:
                try controller.sendText(paneID: paneID, text: action.text)
                DispatchQueue.main.asyncAfter(deadline: .now() + ScheduleRunTiming.enterDelay) { [controller] in
                    try? controller.typeText(paneID: paneID, text: "\r")
                }
                // An instruction to an agent: say when it is done with it.
                if let agent = pane.agentUsage?.agent.displayName {
                    taskWatch.watch(paneID: paneID, workspaceID: pane.workspaceID, agent: agent, current: pane.agentActivity, now: Date())
                }
            case .startAgent:
                return false
            }
            return true
        } catch {
            return false
        }
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

    private func tick() {
        let before = machine.phase
        let step = machine.tick(now: Date())
        if step != .ignore { perform(step) }
        taskWatch.expire(now: Date())
        if !announcements.isEmpty, [.idle, .listening, .paused].contains(machine.phase), !machine.voiceActive {
            speakOnly(announcements.removeFirst())
        }
        if machine.phase != before || hideAt.map({ Date() > $0 }) == true { refresh() }
    }

    /// The HUD shows while the assistant is addressed, thinks, speaks or waits, and a few seconds after.
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
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    var hudContent: AssistantHUDContent {
        let world = AgentOverview.summary(controller)
        let rings = world.entries.compactMap { entry -> AssistantRingsView.Ring? in
            controller.workspace(id: entry.id).map { .init(title: $0.displayTitle, state: entry.state) }
        }
        return AssistantHUDContent(phase: machine.phase, attention: world.needingUserCount > 0,
                                   transcript: machine.transcript, answer: hudNote ?? machine.answer ?? problem,
                                   pending: machine.pending, needsKey: needsKey, rings: rings, style: settings.assistantStyle,
                                   claude: claudeMark)
    }

    /// "Asking Claude" while it works on the answer; "Claude" under an answer that came from it.
    private var claudeMark: AssistantHUDContent.ClaudeMark {
        if machine.phase == .thinking { return claudeWorking ? .working : .none }
        return answerByClaude && machine.answer != nil && hudNote == nil ? .answered : .none
    }

    // MARK: Workspaces changing

    /// A workspace or pane changed: the recognition vocabulary follows the titles, and the sessions given a task are
    /// checked for their agent's state (the state the app already tracks; no screen is read).
    private func stateChanged(_ change: StateChange) {
        switch change {
        case .workspaces, .workspace: updateVocabulary()
        case .pane, .notification: break
        }
        guard !taskWatch.entries.isEmpty else { return }
        for entry in taskWatch.entries {
            guard let pane = controller.pane(id: entry.paneID), pane.workspaceID == entry.workspaceID,
                  let workspace = controller.workspace(id: entry.workspaceID) else {
                taskWatch.forget(paneID: entry.paneID)
                continue
            }
            let question = workspace.notificationPaneID == pane.id ? workspace.notificationText : nil
            if let event = taskWatch.update(paneID: pane.id, activity: pane.agentActivity, question: question, now: Date()) {
                announce(event)
            }
        }
    }

    /// One sentence about a session given a task, when the setting is on: now if the assistant is free, else after.
    private func announce(_ event: AssistantTaskWatch.Event) {
        guard settings.assistantReportTasks, isOn else { return }
        let strings = AssistantStrings.localized
        let text: String
        switch event {
        case .finished(let agent, let id):
            text = strings(.taskDone(agent: agent, workspace: controller.workspace(id: id)?.displayTitle ?? agent))
        case .needsInput(let agent, let id, let question):
            let title = controller.workspace(id: id)?.displayTitle ?? agent
            text = strings(question.map { .taskAsks(agent: agent, workspace: title, question: $0) } ?? .taskNeedsYou(agent: agent, workspace: title))
        }
        assistantLog.info("assistant follow-through on a task it gave")
        announcements.append(text)
        tick()
    }

    /// Hands speech recognition the words to expect: the names, Claude Code, Codex, cmds, the workspaces and agents.
    private func updateVocabulary() {
        let workspaces = controller.workspaces
        let words = AssistantVocabulary.contextualStrings(
            names: names, titles: workspaces.map(\.displayTitle),
            agents: workspaces.compactMap { $0.primaryAgent?.usage.agent.displayName })
        guard words != vocabulary else { return }
        vocabulary = words
        listener.setVocabulary(words)
    }

    #if DEBUG
    var debugUsesMicrophone: Bool { usesMicrophone }
    var debugQueued: [String] { queued.map { String(describing: $0) } }
    var debugWatching: [String] { taskWatch.entries.map(\.paneID) }
    var debugVocabulary: [String] { vocabulary }
    var debugConfirmationKeys: Bool { hotkeys?.confirmationKeysOn ?? false }
    var debugClaudeWorking: Bool { claudeWorking }

    /// `debug.assistant` `speak`: the assistant "says" `text` without a voice and stays speaking until `spoken`, to
    /// test what it hears meanwhile (its own voice, barge-in).
    func debugSpeak(_ text: String) {
        interrupt()
        guard machine.answer(text, now: Date()) else { return }
        answerByClaude = false
        lastSpoken = text
        hudNote = nil
        refresh()
    }

    func debugSpeechEnded() {
        machine.speechFinished(now: Date())
        refresh()
    }
    #endif
}
