import AppKit
import CmdsCore
import os

private let assistantLog = Logger(subsystem: "tokyo.n-n.cmds", category: "assistant")

/// Thinking (#243): a request planned against the workspaces as they are now, and its answer worked out (the rules,
/// the on-device model, `claude -p`), one request of an utterance after the other.
@available(macOS 26.0, *)
extension AssistantController {
    /// Plans what was asked against the workspaces as they are now, and carries it out.
    func handle(_ intent: AssistantIntent) {
        // Several requests in one utterance: the first now (its card says what comes next), the rest after it.
        var asked = intent
        if case .sequence(let intents) = intent, let first = intents.first {
            queued = Array(intents.dropFirst())
            createdForQueue = []
            asked = first
        }
        let world = currentWorld()
        let plan = AssistantPlanner.plan(intent, world: world, strings: .localized, directoryExists: Self.isFolder,
                                         folders: projectFolders(named:), executable: Self.agentExecutable)
        remember(plan)
        mark(.routed)
        carryOut(plan, world: world, asked: asked)
    }

    /// The folders of that name in the project folders (Settings › Assistant › Project folders).
    private func projectFolders(named name: String) -> [String] {
        let roots = AssistantPlaces.roots(setting: projectFolders, home: NSHomeDirectory(), exists: Self.isFolder)
        return AssistantPlaces(roots: roots).find(name)
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
    func continueQueue() {
        guard !queued.isEmpty, askedBack == nil, machine.proceed() else { return }
        let next = queued.removeFirst()
        refresh()
        handle(next)
    }

    private func carryOut(_ plan: AssistantPlan, world: AssistantWorld, asked: AssistantIntent) {
        let strings = AssistantStrings.localized
        switch plan {
        case .answer(let text):
            route("rules")
            say(text)
        case .askBack(let text):
            route("askBack")
            say(text)
            askedBack = asked
        case .propose(let action, let prompt):
            route("card")
            needsKey = false
            pendingShownAt = Date()
            say(prompt, proposing: action)
        case .summarize(let workspaceID, let paneID, let detailed, let fallback):
            let screen = paneID.flatMap { try? controller.readText(paneID: $0, scrollback: AssistantTuning.summaryScrollback) } ?? ""
            route(detailed ? "claudeSummary" : "summary")
            think(capped: !detailed) {
                await self.summary(of: workspaceID, facts: fallback, screen: screen, detailed: detailed, streams: true)
            }
        case .summarizeEach(let items, let detailed):
            // One session after the other, a line each (spoken in turn, listed on the HUD).
            route("summaries")
            let screens = items.map { item in item.paneID.flatMap { try? controller.readText(paneID: $0, scrollback: AssistantTuning.summaryScrollback) } ?? "" }
            think {
                var lines: [String] = []
                for (item, screen) in zip(items, screens) {
                    if Task.isCancelled { return nil }
                    let summary = await self.summary(of: item.workspaceID, facts: item.fallback, screen: screen, detailed: detailed,
                                                     streams: false)
                    lines.append(strings(.session(workspace: item.title, summary: summary)))
                }
                return lines.joined(separator: "\n")
            }
        case .ask(let question):
            // A free command for the agents ("api の Claude にテストを書くよう指示して"): the interpreter (`claude -p`, no
            // tools) turns it into a proposal, planned and confirmed like any other command. Else it is a question.
            // How sure the rules are (#248, `AssistantRoute`): a request goes to the interpreter first, a live question
            // naming no workspace to the web at once, and what may be either to the interpreter and the on-device model
            // at the same time (the interpreter decides; the model's answer is ready when it is a question).
            let request = machine.request
            switch AssistantRoute.decide(question, world: world, web: usesWeb, interpreter: usesInterpreter) {
            case .interpreter:
                route("interpreter")
                think(capped: true) {
                    if await self.handleAsCommand(question, world: world, request: request) { return nil }
                    return await self.answer(question, world: world, interpreted: true)
                }
            case .interpreterAndModel:
                route("interpreter|model")
                think(capped: true) {
                    let early = self.earlyModelAnswer(question, world: world)
                    defer { early?.cancel() }
                    if await self.handleAsCommand(question, world: world, request: request) { return nil }
                    return await self.answer(question, world: world, interpreted: true, early: early)
                }
            case .web, .model:
                think(capped: true) { await self.answer(question, world: world, interpreted: false) }
            }
        case .pauseListening:
            pause()
            speakOnly(strings(.paused))
        case .stop:
            let text = strings(.goodbye)
            let wasMuted = muted
            turnOff()
            speakOnly(text, muted: wasMuted)
        case .confirm, .cancel:
            say(strings(.nothingToConfirm))
        }
    }

    /// What a session's agent is doing: by the on-device model, or by `claude -p` when `detailed`; the facts when there
    /// is no screen, no model or it fails.
    /// `streams`: a detailed summary is spoken sentence by sentence as Claude writes it (#248).
    private func summary(of workspaceID: String, facts: String, screen: String, detailed: Bool, streams: Bool) async -> String {
        guard !screen.isEmpty else { return facts }
        do {
            if detailed {
                let request = machine.request
                let sentence = streams ? sentences(for: request) : nil
                let summary = try await askingClaude(answers: true, slow: true) { progress in
                    try await AssistantBrain.detailedSummary(facts: facts, screen: screen, language: language, progress: progress,
                                                             sentence: sentence)
                }
                return AssistantBrevity.first(Self.detailedSentences, of: summary)
            }
            guard AssistantBrain.modelAvailable else { return facts }
            // One sentence a session ("api: テストを実行中。").
            let summary = AssistantBrevity.first(1, of: try await AssistantBrain.summarize(facts: facts, screen: screen, language: language,
                                                                                         progress: progress(for: machine.request)))
            // A marker or a bracketed word ("[START]") is no summary, nor "waiting for input" for a session that does
            // not wait (made up from a quiet screen).
            let waiting = controller.workspace(id: workspaceID).map(AgentActivityStyle.needsUser) ?? true
            return AssistantModelReply.isSummary(summary, waiting: waiting) ? summary : facts
        } catch {
            assistantLog.error("assistant summary of \(workspaceID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return facts
        }
    }

    /// A free question: Claude with web search for weather, news, "search…" (Settings › Assistant, on by default),
    /// else the on-device model, and Claude after all when the model answers that it needs current information. When
    /// the model takes it for an action (or apologises that it cannot act), it is never spoken: the interpreter gets it
    /// (unless it already had it), else the assistant says how to ask. nil: it went on as a command.
    /// `early`: the on-device model's answer, already being worked out (`AssistantRoute.interpreterAndModel`).
    private func answer(_ question: String, world: AssistantWorld, interpreted: Bool,
                        early: Task<String, Error>? = nil) async -> String? {
        let strings = AssistantStrings.localized
        let web = usesWeb
        if web, AssistantWeb.needsWeb(question) {
            route("web")
            return await webAnswer(question)
        }
        guard AssistantBrain.modelAvailable else { return strings(.modelUnavailable) }
        let status = AssistantReport.status(world, strings: .english)
        do {
            route(interpreted ? "interpreter+model" : "model")
            let answer: String
            if let early {
                answer = try await early.value
            } else {
                answer = try await AssistantBrain.answer(question, status: status, language: language, web: web,
                                                         progress: progress(for: machine.request))
            }
            if web, AssistantWeb.answerNeedsWeb(answer) {
                route("model+web")
                return await webAnswer(question)
            }
            if AssistantModelReply.isAction(answer) {
                if !interpreted, usesInterpreter,
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
            let output = try await askingClaude { progress in
                try await AssistantBrain.interpret(utterance: utterance, world: world, language: language, progress: progress)
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
    /// The same question within a few minutes is answered from `webCache` (#248).
    private func webAnswer(_ question: String) async -> String {
        let strings = AssistantStrings.localized
        if let cached = webCache.answer(question, language: language.name, now: Date()) {
            route("web-cache")
            claudeAnswered = true
            return cached
        }
        do {
            let answer = try await askingClaude(answers: true, slow: true) { progress in
                try await AssistantBrain.webAnswer(question: question, language: language, progress: progress)
            }
            webCache.store(answer, for: question, language: language.name, now: Date())
            return answer
        } catch AssistantClaudeProcess.Failure.notFound {
            return strings(.claudeNotFound)
        } catch {
            assistantLog.error("assistant web answer failed: \(String(describing: error), privacy: .public)")
            return strings(.webFailed)
        }
    }


    /// A `claude -p` call for the current request, with "Asking Claude…" on the HUD while it runs (when it ends or is
    /// stopped, a newer request's mark stays). `answers`: what it returns is the answer, labelled as Claude's (not when
    /// the user has moved on since).
    /// `slow` (a web answer, a detailed summary): the short acknowledgement after `AssistantAck.delay` without an answer.
    private func askingClaude<T>(answers: Bool = false, slow: Bool = false,
                                 _ call: (@escaping AssistantBrain.Progress) async throws -> T) async rethrows -> T {
        let request = machine.request
        claudeWorkingFor = request
        refresh()
        if slow { acknowledgeLater(request) }
        defer { if claudeWorkingFor == request { claudeWorkingFor = nil } }
        let result = try await call(progress(for: request))
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

    /// Works out an answer off the main actor's way, then says it (dropped when the user has moved on to another
    /// request; nil: the body already went on another way). `capped`: a long answer is spoken only up to its first
    /// sentence (`AssistantBrevity.spoken`); the HUD shows it all.
    private func think(capped: Bool = false, _ body: @escaping @MainActor () async -> String?) {
        work?.cancel()
        claudeAnswered = false
        let request = machine.request
        work = Task { [weak self] in
            let text = await body()
            guard let self, let text, !Task.isCancelled, self.machine.request == request else { return }
            // Its first sentences are being said already: the rest follows them.
            if let streaming = self.streaming, streaming.request == request { return self.finishStream(text) }
            guard self.machine.phase == .thinking else { return }
            self.say(text, request: request, capped: capped, byClaude: self.claudeAnswered)
        }
    }

    /// Sentences a detailed summary says at most.
    static let detailedSentences = 3

    /// The on-device model's answer to `question`, started now (beside the interpreter); nil when it would not be
    /// asked (no model, or a question for the web).
    private func earlyModelAnswer(_ question: String, world: AssistantWorld) -> Task<String, Error>? {
        guard AssistantBrain.modelAvailable, !(usesWeb && AssistantWeb.needsWeb(question)) else { return nil }
        let status = AssistantReport.status(world, strings: .english)
        let language = language
        let web = usesWeb
        let progress = progress(for: machine.request)
        return Task { try await AssistantBrain.answer(question, status: status, language: language, web: web, progress: progress) }
    }

    /// The acknowledgement (`AssistantAck`) for `request` once Claude has taken `AssistantAck.delay` without answering.
    private func acknowledgeLater(_ request: Int) {
        let started = Date()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(AssistantAck.delay))
            guard let self else { return }
            let thinking = self.machine.request == request && self.machine.phase == .thinking && self.claudeWorkingFor == request
            guard AssistantAck.due(slow: true, elapsed: Date().timeIntervalSince(started), thinking: thinking,
                                   said: self.acknowledged == request, voiceActive: self.machine.voiceActive) else { return }
            self.acknowledge(request)
        }
    }

    /// Sentences reported from `AssistantBrain` on any thread, spoken for `request` on the main actor.
    private func sentences(for request: Int) -> @Sendable (String) -> Void {
        { [weak self] text in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.streamed(text, request: request, limit: Self.detailedSentences) }
            }
        }
    }

    /// A sentence of a detailed summary as Claude writes it (#248): the first is said at once, the next ones (up to
    /// `limit`) after it; nothing when the user has moved on.
    private func streamed(_ sentence: String, request: Int, limit: Int) {
        guard machine.request == request else { return }
        if var current = streaming, current.request == request {
            guard current.sentences.count < limit else { return }
            current.sentences.append(sentence)
            streaming = current
            speakMore(sentence, answer: AssistantBrevity.join(current.sentences))
        } else {
            guard machine.phase == .thinking else { return }
            streaming = (request, [sentence])
            say(sentence, request: request, byClaude: true, open: true)
        }
    }

    /// The whole answer, once Claude is done: the sentences not said yet follow (when it goes on as streamed), the HUD
    /// shows it all, and the voice ends after the last one.
    private func finishStream(_ text: String) {
        guard let current = streaming else { return }
        streaming = nil
        let all = AssistantBrevity.sentences(text)
        let said = current.sentences
        if all.count > said.count, Array(all.prefix(said.count)) == said {
            for index in said.count..<all.count {
                speakMore(all[index], answer: AssistantBrevity.join(Array(all.prefix(index + 1))))
            }
        }
        if machine.extendAnswer(text, request: current.request) { refresh() }
        voice.close()
    }
}
