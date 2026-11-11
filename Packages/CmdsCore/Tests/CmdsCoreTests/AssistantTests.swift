import XCTest
@testable import CmdsCore

/// The voice assistant's addressing: only what starts with its name, or follows an answer, counts (#243).
final class AssistantAddressingTests: XCTestCase {
    private let names = AssistantAddressing.defaultNames

    func testNamePrefixInJapaneseAndEnglish() {
        XCTAssertEqual(AssistantAddressing.check("ジャービス、状況は？", names: names, followUpOpen: false), .command("状況は", byName: true))
        XCTAssertEqual(AssistantAddressing.check("ジャーヴィス 状況は", names: names, followUpOpen: false), .command("状況は", byName: true))
        XCTAssertEqual(AssistantAddressing.check("じゃーびす状況", names: names, followUpOpen: false), .command("状況", byName: true))
        XCTAssertEqual(AssistantAddressing.check("Jarvis, status report.", names: names, followUpOpen: false), .command("status report", byName: true))
        XCTAssertEqual(AssistantAddressing.check("hey JARVIS what is api doing", names: names, followUpOpen: false),
                       .command("what is api doing", byName: true))
        XCTAssertEqual(AssistantAddressing.check("ねえジャービス、apiは何してる", names: names, followUpOpen: false),
                       .command("apiは何してる", byName: true))
    }

    func testNameAloneWakes() {
        XCTAssertEqual(AssistantAddressing.check("Jarvis?", names: names, followUpOpen: false), .wake)
        XCTAssertEqual(AssistantAddressing.check("ジャービス。", names: names, followUpOpen: false), .wake)
    }

    func testConversationIsIgnored() {
        XCTAssertEqual(AssistantAddressing.check("I told Jarvis about it", names: names, followUpOpen: false), .ignored)
        XCTAssertEqual(AssistantAddressing.check("今日はいい天気ですね", names: names, followUpOpen: false), .ignored)
        XCTAssertEqual(AssistantAddressing.check("Jarvisa status", names: names, followUpOpen: false), .ignored)
        XCTAssertEqual(AssistantAddressing.check("   ", names: names, followUpOpen: true), .ignored)
    }

    func testFollowUpWindowNeedsNoName() {
        XCTAssertEqual(AssistantAddressing.check("yes", names: names, followUpOpen: true), .command("yes", byName: false))
        XCTAssertEqual(AssistantAddressing.check("はい", names: names, followUpOpen: false), .ignored)
    }

    func testConfiguredNames() {
        let custom = AssistantAddressing.names(configured: "Friday, フライデー")
        XCTAssertEqual(custom, ["Friday", "フライデー"])
        XCTAssertEqual(AssistantAddressing.check("Friday status", names: custom, followUpOpen: false), .command("status", byName: true))
        XCTAssertEqual(AssistantAddressing.check("ふらいでー、状況", names: custom, followUpOpen: false), .command("状況", byName: true))
        XCTAssertEqual(AssistantAddressing.check("Jarvis status", names: custom, followUpOpen: false), .ignored)
        XCTAssertEqual(AssistantAddressing.names(configured: " , "), AssistantAddressing.defaultNames)
    }
}

/// Commands in Japanese and English (#243).
final class AssistantIntentTests: XCTestCase {
    private func parse(_ text: String) -> AssistantIntent { AssistantIntent.parse(text) }

    func testStatus() {
        for text in ["status", "Status report", "what's going on?", "how are things", "any updates", "状況は？", "状況を教えて",
                     "全体の状況は", "どうなってる", "みんな何してる", "進捗は"] {
            XCTAssertEqual(parse(text), .status, text)
        }
    }

    func testWorkspaceStatus() {
        XCTAssertEqual(parse("what is api doing"), .workspaceStatus(target: "api"))
        XCTAssertEqual(parse("What's the web workspace doing right now?"), .workspaceStatus(target: "web"))
        XCTAssertEqual(parse("how is docs doing"), .workspaceStatus(target: "docs"))
        XCTAssertEqual(parse("apiは何してる？"), .workspaceStatus(target: "api"))
        XCTAssertEqual(parse("webって今なにやってる"), .workspaceStatus(target: "web"))
        XCTAssertEqual(parse("cmdsの状況は"), .workspaceStatus(target: "cmds"))
    }

    func testSummaries() {
        XCTAssertEqual(parse("summarize api"), .summary(target: "api", detailed: false))
        XCTAssertEqual(parse("give me a detailed summary of api"), .summary(target: "api", detailed: true))
        XCTAssertEqual(parse("summarise web in detail"), .summary(target: "web", detailed: true))
        XCTAssertEqual(parse("apiを要約して"), .summary(target: "api", detailed: false))
        XCTAssertEqual(parse("apiを詳しく要約して"), .summary(target: "api", detailed: true))
        XCTAssertEqual(parse("webの要約"), .summary(target: "web", detailed: false))
    }

    func testReplies() {
        XCTAssertEqual(parse("reply to api: run the tests"), .reply(target: "api", text: "run the tests"))
        XCTAssertEqual(parse("tell web to commit the fix"), .reply(target: "web", text: "commit the fix"))
        XCTAssertEqual(parse("send \"continue\" to docs"), .reply(target: "docs", text: "continue"))
        XCTAssertEqual(parse("apiに「テストを実行して」と返信して"), .reply(target: "api", text: "テストを実行して"))
        XCTAssertEqual(parse("webにコミットしてと伝えて"), .reply(target: "web", text: "コミットして"))
        XCTAssertEqual(parse("「続けて」と返信"), .reply(target: nil, text: "続けて"))
    }

    func testApproveAndChoose() {
        XCTAssertEqual(parse("approve"), .approve(target: nil))
        XCTAssertEqual(parse("approve api"), .approve(target: "api"))
        XCTAssertEqual(parse("approve it for web"), .approve(target: "web"))
        XCTAssertEqual(parse("apiを承認して"), .approve(target: "api"))
        XCTAssertEqual(parse("許可して"), .approve(target: nil))
        XCTAssertEqual(parse("webにはいと答えて"), .approve(target: "web"))
        XCTAssertEqual(parse("choose option 2 for api"), .choose(target: "api", option: 2))
        XCTAssertEqual(parse("pick three"), .choose(target: nil, option: 3))
        XCTAssertEqual(parse("apiで2番を選んで"), .choose(target: "api", option: 2))
        XCTAssertEqual(parse("二番を選んで"), .choose(target: nil, option: 2))
        XCTAssertEqual(parse("３番"), .choose(target: nil, option: 3))
    }

    func testStartAgent() {
        XCTAssertEqual(parse("start Claude in cmds"), .startAgent(.claude, place: "cmds"))
        XCTAssertEqual(parse("launch a new codex session in ~/src/app"), .startAgent(.codex, place: "~/src/app"))
        XCTAssertEqual(parse("cmdsでクロードを起動して"), .startAgent(.claude, place: "cmds"))
        XCTAssertEqual(parse("apiでcodexを始めて"), .startAgent(.codex, place: "api"))
    }

    func testYesNoPauseStop() {
        for text in ["yes", "Yes please", "OK", "go ahead", "はい", "お願いします", "うん"] { XCTAssertEqual(parse(text), .confirm, text) }
        for text in ["no", "cancel", "never mind", "stop", "いいえ", "キャンセル", "やめて"] { XCTAssertEqual(parse(text), .cancel, text) }
        for text in ["pause listening", "stop listening", "聞き取りを一時停止して", "一時停止"] { XCTAssertEqual(parse(text), .pauseListening, text) }
        for text in ["turn off", "goodbye", "おやすみ", "アシスタントを終了"] { XCTAssertEqual(parse(text), .stop, text) }
    }

    func testAnswerToWhichOneRetargets() {
        XCTAssertEqual(AssistantIntent.approve(target: "ap").retargeted("api-v2"), .approve(target: "api-v2"))
        XCTAssertEqual(AssistantIntent.reply(target: nil, text: "go").retargeted("the web workspace"), .reply(target: "web", text: "go"))
        XCTAssertEqual(AssistantIntent.choose(target: nil, option: 2).retargeted("apiの"), .choose(target: "api", option: 2))
        XCTAssertNil(AssistantIntent.status.retargeted("api"))
    }

    func testAnythingElseIsAQuestion() {
        XCTAssertEqual(parse("what is a monad"), .question("what is a monad"))
        XCTAssertEqual(parse("今日の天気は？"), .question("今日の天気は"))
        XCTAssertFalse(parse("what is a monad").acts)
        XCTAssertTrue(parse("approve api").acts)
    }
}

/// Which actions a spoken yes may confirm (#243).
final class AssistantSafetyTests: XCTestCase {
    func testOrdinaryTextNeedsOnlyAYes() {
        XCTAssertEqual(AssistantSafety.reasons(text: "run the tests", sshPane: false), [])
        XCTAssertEqual(AssistantSafety.reasons(text: "テストを実行して", sshPane: false), [])
        XCTAssertEqual(AssistantSafety.confirmation(for: []), .voiceOrKey)
        XCTAssertEqual(AssistantSafety.reasons(text: "inform the user", sshPane: false), [])  // "rm" inside a word
    }

    func testDangerousTextNeedsAKey() {
        XCTAssertEqual(AssistantSafety.reasons(text: "rm -rf build", sshPane: false), [.destructive])
        XCTAssertEqual(AssistantSafety.reasons(text: "then git push origin main", sshPane: false), [.publish])
        XCTAssertEqual(AssistantSafety.reasons(text: "deploy it", sshPane: false), [.deploy])
        XCTAssertEqual(AssistantSafety.reasons(text: "本番にデプロイして", sshPane: false), [.deploy])
        XCTAssertEqual(AssistantSafety.reasons(text: "claude --dangerously-skip-permissions", sshPane: false), [.permissions])
        XCTAssertEqual(AssistantSafety.reasons(text: "古いファイルを削除して", sshPane: false), [.destructive])
        XCTAssertEqual(AssistantSafety.reasons(text: "ls", sshPane: true), [.sshPane])
        XCTAssertEqual(AssistantSafety.confirmation(for: [.sshPane]), .keyOrClick)
    }

    func testApprovingADangerousPromptNeedsAKey() {
        let context = ["Bash command", "  rm -rf dist", "Do you want to proceed?", "Yes"]
        XCTAssertEqual(AssistantSafety.reasons(text: "", context: context, sshPane: false), [.destructive])
        XCTAssertEqual(AssistantSafety.reasons(text: "", context: ["Do you want to proceed?", "Yes, and don't ask again for npm test"],
                                               sshPane: false), [.permissions])
    }
}

/// From intent to plan and the spoken status (#243).
final class AssistantPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let yesNo = AgentPromptOptions(question: "Run the tests?", options: [
        .init(number: 1, label: "Yes", selected: true), .init(number: 2, label: "No", selected: false)])

    private func world(_ extra: [AssistantWorld.Workspace] = []) -> AssistantWorld {
        AssistantWorld(workspaces: [
            .init(id: "w1", title: "api", state: .needsUser, agent: "Claude", topic: "Add tests",
                  waitingSince: now.addingTimeInterval(-300), directory: "/tmp/api",
                  panes: [.init(id: "p1", title: "zsh", agent: "Claude", waiting: true, prompt: yesNo)]),
            .init(id: "w2", title: "web", state: .working, agent: "Codex", topic: "Login form", directory: "/tmp/web",
                  panes: [.init(id: "p2", title: "zsh", agent: "Codex")]),
            .init(id: "w3", title: "docs", directory: "/tmp/docs", panes: [.init(id: "p3", title: "zsh")]),
        ] + extra, now: now)
    }

    private func plan(_ text: String, _ world: AssistantWorld? = nil) -> AssistantPlan {
        AssistantPlanner.plan(AssistantIntent.parse(text), world: world ?? self.world(), strings: .english)
    }

    func testStatusReport() {
        XCTAssertEqual(plan("status"), .answer("1 needs you, 1 working. api needs you. It asks: Run the tests? web is working on Login form."))
        XCTAssertEqual(plan("status", AssistantWorld(workspaces: [])), .answer("No agents are running."))
        let quiet = AssistantWorld(workspaces: [.init(id: "w1", title: "api", state: .done)])
        XCTAssertEqual(plan("status", quiet), .answer("1 agent, nothing needs you."))
    }

    func testWhatIsItDoing() {
        XCTAssertEqual(plan("what is api doing"), .summarize(
            workspaceID: "w1", paneID: "p1", detailed: false,
            fallback: "Claude in api. api needs you. It asks: Run the tests? 2 options, the first is Yes. Waiting for 5 minutes."))
        XCTAssertEqual(plan("docsは何してる"), .summarize(workspaceID: "w3", paneID: "p3", detailed: false,
                                                     fallback: "No agent is running in docs."))
        XCTAssertEqual(plan("what is nothing doing"), .askBack("I can't find a workspace called nothing."))
    }

    func testReplyIsProposedNeverSent() {
        guard case .propose(let action, let prompt) = plan("reply to api: run the tests") else { return XCTFail() }
        XCTAssertEqual(action.kind, .reply)
        XCTAssertEqual(action.paneID, "p1")
        XCTAssertEqual(action.text, "run the tests")
        XCTAssertEqual(action.confirmation, .voiceOrKey)
        XCTAssertEqual(prompt, "Send “run the tests” to api? Say yes or press Return.")
    }

    func testDangerousReplyNeedsAKey() {
        guard case .propose(let action, let prompt) = plan("tell api to git push --force") else { return XCTFail() }
        XCTAssertEqual(action.confirmation, .keyOrClick)
        XCTAssertTrue(prompt.hasSuffix("This one needs Return or a click."))
    }

    func testApproveWithoutANameGoesToTheOneThatWaits() {
        guard case .propose(let action, _) = plan("approve") else { return XCTFail() }
        XCTAssertEqual(action.kind, .choose(1))
        XCTAssertEqual(action.workspaceID, "w1")
        XCTAssertEqual(action.label, "Yes")
        XCTAssertEqual(plan("choose 5 for api"), .answer("api has no option 5."))
        XCTAssertEqual(plan("approve web"), .answer("web isn't asking anything."))
    }

    func testJapaneseChooseWithAPartialName() {
        let two = world([.init(id: "w4", title: "api-v2", state: .needsUser, panes: [.init(id: "p4", title: "zsh", waiting: true, prompt: yesNo)])])
        XCTAssertEqual(AssistantIntent.parse("apで1番を選んで"), .choose(target: "ap", option: 1))
        XCTAssertEqual(plan("apで1番を選んで", two), .askBack("Which one: api, api-v2?"))
    }

    func testAmbiguousTargetsAskBack() {
        let two = world([.init(id: "w4", title: "api-v2", state: .needsUser, panes: [.init(id: "p4", title: "zsh", waiting: true, prompt: yesNo)])])
        XCTAssertEqual(plan("approve", two), .askBack("Which one: api, api-v2?"))
        XCTAssertEqual(plan("approve ap", two), .askBack("Which one: api, api-v2?"))
        if case .propose(let action, _) = plan("approve api", two) { XCTAssertEqual(action.workspaceID, "w1") } else { XCTFail() }
        let panes = AssistantWorld(workspaces: [.init(id: "w1", title: "api", state: .needsUser, panes: [
            .init(id: "p1", title: "left", waiting: true), .init(id: "p2", title: "right", waiting: true)])])
        XCTAssertEqual(plan("reply to api: ok", panes),
                       .askBack("api has several panes (left, right). Please use the reply panel."))
        XCTAssertEqual(plan("approve", AssistantWorld(workspaces: [])), .askBack("No workspace is waiting for you. Which one do you mean?"))
    }

    func testFindsByNumberAgentAndFoldedTitle() {
        let world = world()
        XCTAssertEqual(world.find("2"), .found(world.workspaces[1]))
        XCTAssertEqual(world.find("codex"), .found(world.workspaces[1]))
        XCTAssertEqual(world.find("ＡＰＩ"), .found(world.workspaces[0]))
        XCTAssertEqual(world.find("doc"), .found(world.workspaces[2]))
    }

    func testSSHPaneNeedsAKey() {
        let ssh = AssistantWorld(workspaces: [.init(id: "w1", title: "server", state: .idle,
                                                    panes: [.init(id: "p1", title: "ssh", isSSH: true, agent: "Claude")])])
        guard case .propose(let action, _) = plan("tell server to ls", ssh) else { return XCTFail() }
        XCTAssertEqual(action.reasons, [.sshPane])
    }

    func testStartAgentInAWorkspacesFolder() {
        guard case .propose(let action, let prompt) = plan("start claude in web") else { return XCTFail() }
        XCTAssertEqual(action.kind, .startAgent(.claude, directory: "/tmp/web"))
        XCTAssertEqual(action.text, "claude")
        XCTAssertEqual(prompt, "Start Claude in /tmp/web? Say yes or press Return.")
        XCTAssertEqual(plan("start codex in nowhere"), .askBack("I don't know a workspace or folder called nowhere."))
        let path = AssistantPlanner.plan(.startAgent(.codex, place: "/tmp/x"), world: world(), strings: .english) { $0 == "/tmp/x" }
        if case .propose(let action, _) = path { XCTAssertEqual(action.kind, .startAgent(.codex, directory: "/tmp/x")) } else { XCTFail() }
    }

    func testQuestionsGoToTheModel() {
        XCTAssertEqual(plan("what is a monad"), .ask("what is a monad"))
    }

    func testJapaneseSeparator() {
        let strings = AssistantStrings(separator: "") { line in
            if case .needsYou(let workspace) = line { return "\(workspace)が応答待ちです。" }
            return line.english
        }
        let text = AssistantReport.workspace(world().workspaces[0], now: now, strings: strings)
        XCTAssertTrue(text.contains("apiが応答待ちです。It asks"), text)
    }
}

/// The HUD's states and when an action may run (#243).
final class AssistantMachineTests: XCTestCase {
    private let names = AssistantAddressing.defaultNames
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let action = AssistantAction(kind: .reply, workspaceID: "w1", workspaceTitle: "api", paneID: "p1",
                                         paneTitle: "zsh", text: "run the tests", reasons: [])

    private func on() -> AssistantMachine {
        var machine = AssistantMachine()
        machine.turnOn()
        return machine
    }

    func testUnaddressedSpeechChangesNothing() {
        var machine = on()
        XCTAssertEqual(machine.hear("let's get lunch", names: names, now: t0), .ignore)
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertNil(machine.transcript)
    }

    func testOffAndPausedHearNothing() {
        var machine = AssistantMachine()
        XCTAssertEqual(machine.hear("Jarvis status", names: names, now: t0), .ignore)
        machine.turnOn()
        machine.pause()
        XCTAssertEqual(machine.hear("Jarvis status", names: names, now: t0), .ignore)
        machine.resume()
        XCTAssertEqual(machine.hear("Jarvis status", names: names, now: t0), .handle(.status))
        XCTAssertEqual(machine.phase, .thinking)
        XCTAssertEqual(machine.transcript, "status")
    }

    func testAnswerThenFollowUpWithoutName() {
        var machine = on()
        _ = machine.hear("Jarvis status", names: names, now: t0)
        machine.answer("All quiet.", now: t0)
        XCTAssertEqual(machine.phase, .speaking)
        XCTAssertEqual(machine.hear("what is api doing", names: names, now: t0), .ignore)  // its own voice
        machine.speechFinished(now: t0)
        XCTAssertEqual(machine.phase, .listening)
        XCTAssertEqual(machine.hear("what is api doing", names: names, now: t0.addingTimeInterval(0.2)), .ignore)  // echo
        XCTAssertEqual(machine.hear("what is api doing", names: names, now: t0.addingTimeInterval(3)),
                       .handle(.workspaceStatus(target: "api")))
        machine.answer("Working.", now: t0.addingTimeInterval(4))
        machine.speechFinished(now: t0.addingTimeInterval(5))
        XCTAssertEqual(machine.tick(now: t0.addingTimeInterval(20)), .ignore)
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.hear("what is api doing", names: names, now: t0.addingTimeInterval(21)), .ignore)
    }

    func testVoiceYesConfirmsOrdinaryAction() {
        var machine = on()
        _ = machine.hear("Jarvis reply to api: run the tests", names: names, now: t0)
        machine.answer("Send?", proposing: action, now: t0)
        machine.speechFinished(now: t0)
        XCTAssertEqual(machine.phase, .confirming)
        XCTAssertEqual(machine.hear("lunch?", names: names, now: t0.addingTimeInterval(1)), .ignore)
        XCTAssertEqual(machine.hear("はい", names: names, now: t0.addingTimeInterval(2)), .execute(action))
        XCTAssertNil(machine.pending)
    }

    func testVoiceYesIsNotEnoughForDangerousAction() {
        var machine = on()
        var dangerous = action
        dangerous.reasons = [.destructive]
        _ = machine.hear("Jarvis tell api to rm -rf x", names: names, now: t0)
        machine.answer("Send?", proposing: dangerous, now: t0)
        machine.speechFinished(now: t0)
        XCTAssertEqual(machine.hear("yes", names: names, now: t0.addingTimeInterval(2)), .needsKey)
        XCTAssertEqual(machine.phase, .confirming)
        XCTAssertEqual(machine.key(.confirm, now: t0.addingTimeInterval(3)), .execute(dangerous))
    }

    func testNoAndEscCancel() {
        var machine = on()
        machine.answer("Send?", proposing: action, now: t0)
        machine.speechFinished(now: t0)
        XCTAssertEqual(machine.hear("いいえ", names: names, now: t0.addingTimeInterval(2)), .cancelled)
        XCTAssertNil(machine.pending)
        machine.answer("Send?", proposing: action, now: t0)
        XCTAssertEqual(machine.key(.cancel, now: t0), .cancelled)
        XCTAssertEqual(machine.key(.confirm, now: t0), .ignore)
    }

    func testANewCommandByNameReplacesThePendingAction() {
        var machine = on()
        machine.answer("Send?", proposing: action, now: t0)
        machine.speechFinished(now: t0)
        XCTAssertEqual(machine.hear("Jarvis status", names: names, now: t0.addingTimeInterval(2)), .handle(.status))
        XCTAssertNil(machine.pending)
    }

    func testUnconfirmedActionExpires() {
        var machine = on()
        machine.answer("Send?", proposing: action, now: t0)
        machine.speechFinished(now: t0)
        XCTAssertEqual(machine.tick(now: t0.addingTimeInterval(AssistantMachine.confirmationTimeout + 1)), .expired)
        XCTAssertNil(machine.pending)
    }

    func testHotkeyTakesOneCommandEvenWhilePaused() {
        var machine = on()
        machine.pause()
        machine.hotkey(now: t0)
        XCTAssertEqual(machine.phase, .listening)
        XCTAssertEqual(machine.hear("status", names: names, now: t0.addingTimeInterval(1)), .handle(.status))
        machine.settle()
        XCTAssertEqual(machine.phase, .paused)
    }

    func testWakeOpensTheWindow() {
        var machine = on()
        XCTAssertEqual(machine.hear("Jarvis", names: names, now: t0), .wake)
        XCTAssertEqual(machine.phase, .listening)
        XCTAssertEqual(machine.hear("approve api", names: names, now: t0.addingTimeInterval(2)), .handle(.approve(target: "api")))
    }
}

/// The paid-feature gate (#244): free during the beta, then a licence (or a development build).
final class PaidFeaturesTests: XCTestCase {
    private struct Licensed: LicenceProvider {
        func isUnlocked(_ feature: PaidFeature) -> Bool { feature == .assistant }
    }

    func testTheAssistantIsFreeDuringTheBeta() {
        XCTAssertTrue(PaidFeatures.betaFree.contains(.assistant))
        XCTAssertEqual(PaidFeatures.unlock(.assistant, betaFree: PaidFeatures.betaFree, developmentBuild: false,
                                           provider: NoLicenceProvider()), .beta)
        XCTAssertTrue(PaidFeatures.isUnlocked(.assistant))
    }

    func testAfterTheBetaALicenceOrADevelopmentBuildUnlocks() {
        XCTAssertNil(PaidFeatures.unlock(.assistant, betaFree: [], developmentBuild: false, provider: NoLicenceProvider()))
        XCTAssertEqual(PaidFeatures.unlock(.assistant, betaFree: [], developmentBuild: true, provider: NoLicenceProvider()),
                       .developmentBuild)
        XCTAssertEqual(PaidFeatures.unlock(.assistant, betaFree: [], developmentBuild: false, provider: Licensed()), .licence)
    }
}
