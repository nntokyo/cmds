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
        carryOut(plan, world: world, asked: asked)
    }

    /// The folders of that name in the project folders (Settings › Assistant › Project folders).
    private func projectFolders(named name: String) -> [String] {
        let roots = AssistantPlaces.roots(setting: settings.assistantProjectFolders, home: NSHomeDirectory(), exists: Self.isFolder)
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
            let wasMuted = muted
            turnOff()
            speakOnly(text, muted: wasMuted)
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
}
