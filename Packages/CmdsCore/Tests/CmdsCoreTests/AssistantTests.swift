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
        XCTAssertEqual(parse("start Claude in cmds"), .startAgent(.claude, place: "cmds", task: nil))
        XCTAssertEqual(parse("launch a new codex session in ~/src/app"), .startAgent(.codex, place: "~/src/app", task: nil))
        XCTAssertEqual(parse("cmdsでクロードを起動して"), .startAgent(.claude, place: "cmds", task: nil))
        XCTAssertEqual(parse("apiでcodexを始めて"), .startAgent(.codex, place: "api", task: nil))
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
        // Compact: counts and names, no agent's question (that is for "what is api doing").
        XCTAssertEqual(plan("status"), .answer("1 waiting: api. 1 working: web."))
        XCTAssertEqual(plan("status", AssistantWorld(workspaces: [])), .answer("No agents are running."))
        let quiet = AssistantWorld(workspaces: [.init(id: "w1", title: "api", state: .done)])
        XCTAssertEqual(plan("status", quiet), .answer("1 agent, nothing needs you."))
    }

    func testStatusReportListsNamesCompactly() {
        let many = AssistantWorld(workspaces: ["a", "b", "c", "d", "e"].map {
            .init(id: $0, title: $0, state: .needsUser, agent: "Claude", panes: [.init(id: "p" + $0, title: "zsh", agent: "Claude", waiting: true, prompt: yesNo)])
        } + [.init(id: "w", title: "web", state: .working, agent: "Codex", topic: "Login form")], now: now)
        XCTAssertEqual(AssistantReport.status(many, strings: .english), "5 waiting: a, b, c, d +1. 1 working: web.")
        let japanese = AssistantStrings(separator: "", listSeparator: "、") { line in
            switch line {
            case .waitingList(let count, let names): return "入力待ち\(count)件: \(names)。"
            case .workingList(let count, let names): return "作業中\(count)件: \(names)。"
            default: return line.english
            }
        }
        let two = AssistantWorld(workspaces: [
            .init(id: "1", title: "api", state: .needsUser), .init(id: "2", title: "api-v2", state: .needsUser),
            .init(id: "3", title: "web", state: .working),
        ], now: now)
        XCTAssertEqual(AssistantReport.status(two, strings: japanese), "入力待ち2件: api、api-v2。作業中1件: web。")
        XCTAssertEqual(AssistantReport.status(two, strings: .english), "2 waiting: api, api-v2. 1 working: web.")
    }

    func testWhatIsItDoing() {
        XCTAssertEqual(plan("what is api doing"), .summarize(
            workspaceID: "w1", paneID: "p1", detailed: false,
            fallback: "Claude in api. api needs you. It asks: Run the tests? 2 options, the first is Yes. Waiting for 5 minutes."))
        // No agent: said at once, never a summary of the screen (a model would make up "waiting for input").
        XCTAssertEqual(plan("docsは何してる"), .answer("No agent is running in docs."))
        XCTAssertEqual(plan("what is nothing doing"), .askBack("I can't find a workspace called nothing."))
    }

    func testAWorkspaceWithoutAnAgentSaysWhatItsShellRuns() {
        func docs(_ shells: [AssistantWorld.Shell?], state: MenuBarSummary.State? = nil) -> AssistantWorld {
            world([]).replacing("w3", with: .init(id: "w3", title: "docs", state: state, directory: "/tmp/docs",
                                                  panes: shells.enumerated().map { .init(id: "p3\($0.offset)", title: "zsh", shell: $0.element) }))
        }
        XCTAssertEqual(plan("what is docs doing", docs([.idle])), .answer("No agent is running in docs. Its shell is idle."))
        XCTAssertEqual(plan("docsは何してる", docs([.running("vim")])), .answer("No agent is running in docs. It is running vim."))
        XCTAssertEqual(plan("summarize docs", docs([.idle, .running("node"), .running("node")])),
                       .answer("No agent is running in docs. It is running node."))
        XCTAssertEqual(plan("summarize docs in detail", docs([.idle, .idle])), .answer("No agent is running in docs. Its shell is idle."))
        // Not known (an SSH pane, a process not read): only that no agent runs.
        XCTAssertEqual(plan("what is docs doing", docs([nil])), .answer("No agent is running in docs."))
        XCTAssertEqual(plan("what is docs doing", docs([.idle, nil])), .answer("No agent is running in docs."))
        // An agent that has finished (its badge stays, the agent is gone): the same.
        XCTAssertEqual(plan("what is docs doing", docs([.idle], state: .done)), .answer("No agent is running in docs. Its shell is idle."))
        // A plain shell asking for the user (a bell): its state as before.
        guard case .summarize = plan("what is docs doing", docs([.idle], state: .needsUser)) else { return XCTFail() }
        // An agent running: summarised from its screen as before.
        guard case .summarize = plan("what is web doing") else { return XCTFail() }
    }

    func testAWorkspaceCreatedInAFolderThatIsAlreadyAWorkspaceIsNumbered() {
        XCTAssertNil(AssistantWorld.uniqueTitle("app", taken: ["api", "web"]))
        XCTAssertEqual(AssistantWorld.uniqueTitle("api", taken: ["api", "web"]), "api-2")
        XCTAssertEqual(AssistantWorld.uniqueTitle("api", taken: ["API", "api-2", "api 3"]), "api-4")
        XCTAssertEqual(AssistantWorld.uniqueTitle("~", taken: ["~"]), "~-2")
        // The base name means the original; the number the new one.
        let two = world([.init(id: "w4", title: "api-2", state: .working, agent: "Claude", directory: "/tmp/api",
                               panes: [.init(id: "p4", title: "zsh", agent: "Claude")])])
        XCTAssertEqual(two.find("api").found?.id, "w1")
        XCTAssertEqual(two.find("API").found?.id, "w1")
        XCTAssertEqual(two.find("api 2").found?.id, "w4")
        XCTAssertEqual(two.find("api-2").found?.id, "w4")
        XCTAssertEqual(two.find("api２").found?.id, "w4")
        guard case .summarize(let id, _, _, _) = plan("what is api doing", two) else { return XCTFail() }
        XCTAssertEqual(id, "w1")
        guard case .summarize(let numbered, _, _, _) = plan("what is api 2 doing", two) else { return XCTFail() }
        XCTAssertEqual(numbered, "w4")
        guard case .propose(let action, _) = plan("apiに「続けて」と返信", two) else { return XCTFail() }
        XCTAssertEqual(action.workspaceID, "w1")
    }

    func testWhatACancelledCardLeavesOut() {
        let reply = AssistantAction(kind: .reply, workspaceID: "w1", workspaceTitle: "api", paneID: "p1", paneTitle: "zsh",
                                    text: "go", reasons: [])
        var choose = reply
        choose.kind = .choose(1)
        let start = AssistantAction(kind: .startAgent(.claude, directory: "/tmp/api", task: nil), workspaceID: nil,
                                    workspaceTitle: "/tmp/api", paneID: nil, paneTitle: nil, text: "claude", reasons: [])
        XCTAssertEqual(AssistantPlanner.skipped(reply), .skippedSend(workspace: "api"))
        XCTAssertEqual(AssistantPlanner.skipped(choose), .skippedChoice(workspace: "api"))
        XCTAssertEqual(AssistantPlanner.skipped(start), .skippedStart(agent: "Claude"))
        XCTAssertEqual(AssistantPlanner.skipped(AssistantAction.batch([reply, reply])!), .skippedMany(count: 2))
        XCTAssertEqual(AssistantStrings.english.join([.skippedStart(agent: "Claude")]), "I won't start Claude.")
    }

    func testReplyIsProposedNeverSent() {
        guard case .propose(let action, let prompt) = plan("reply to api: run the tests") else { return XCTFail() }
        XCTAssertEqual(action.kind, .reply)
        XCTAssertEqual(action.paneID, "p1")
        XCTAssertEqual(action.text, "run the tests")
        XCTAssertEqual(action.confirmation, .voiceOrKey)
        XCTAssertEqual(prompt, "Send “run the tests” to api? Confirm by voice or press Return.")
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
        XCTAssertEqual(action.kind, .startAgent(.claude, directory: "/tmp/web", task: nil))
        XCTAssertEqual(action.text, "claude")
        XCTAssertEqual(prompt, "Start Claude in /tmp/web? Confirm by voice or press Return.")
        XCTAssertEqual(plan("start codex in nowhere"), .askBack("I don't know a workspace or folder called nowhere. Which folder should I start it in?"))
        let path = AssistantPlanner.plan(.startAgent(.codex, place: "/tmp/x", task: nil), world: world(), strings: .english) { $0 == "/tmp/x" }
        if case .propose(let action, _) = path { XCTAssertEqual(action.kind, .startAgent(.codex, directory: "/tmp/x", task: nil)) } else { XCTFail() }
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

    /// An agent's question as it asked it ends in a Latin mark: the next sentence still gets a space ("…now?api-v2が" was
    /// run together).
    func testJapaneseSeparatorAfterALatinQuestion() {
        let strings = AssistantStrings(separator: "") { line in
            switch line {
            case .asks(let question): return "質問：\(question)"
            case .optionsOffered(let count, let first): return "選択肢は\(count)個、1番は「\(first)」です。"
            default: return "。"
            }
        }
        XCTAssertEqual(strings.join([.asks("Run the tests now?"), .optionsOffered(count: 2, first: "Yes")]),
                       "質問：Run the tests now? 選択肢は2個、1番は「Yes」です。")
        XCTAssertEqual(strings.join([.asks("テストを実行しますか？"), .optionsOffered(count: 2, first: "Yes")]),
                       "質問：テストを実行しますか？選択肢は2個、1番は「Yes」です。")
        XCTAssertEqual(AssistantStrings.english.join([.asks("Run the tests now?"), .wake]), "It asks: Run the tests now? Yes?")
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

    // MARK: Its own voice, barge-in, the follow-up window

    private let weather = "15日曜日は曇りです。降水確率は60%前後、最高気温は19度、最低気温は12度の見込みです。"

    /// The real case: a long Claude answer heard back after it was said is not sent to Claude again.
    func testItsOwnLongAnswerHeardLateIsDropped() {
        var machine = on()
        _ = machine.hear("ジャービス、明日の天気は", names: names, now: t0)
        let request = machine.request
        XCTAssertTrue(machine.answer(weather, request: request, now: t0.addingTimeInterval(5)))
        // While speaking: unaddressed speech (its own voice) never counts.
        XCTAssertEqual(machine.hear("15日曜日は曇りです", names: names, now: t0.addingTimeInterval(6)), .ignore)
        machine.speechFinished(now: t0.addingTimeInterval(15))
        XCTAssertEqual(machine.phase, .listening)
        // The transcript arrives 3 s after speech ended: the 1 s guard is over, but it is its own text.
        XCTAssertEqual(machine.hear("15日曜日は曇りです。降水確率は 60%前後最高気温は19度", names: names, now: t0.addingTimeInterval(18)), .ignore)
        XCTAssertEqual(machine.phase, .listening)
        XCTAssertEqual(machine.request, request)
        XCTAssertEqual(machine.transcript, "明日の天気は")
    }

    func testEchoRejection() {
        // Exact, partial, recognised a little differently.
        XCTAssertTrue(AssistantEcho.isEcho(weather, of: weather))
        XCTAssertTrue(AssistantEcho.isEcho("降水確率は60%前後", of: weather))
        XCTAssertTrue(AssistantEcho.isEcho("１５日 日曜日は曇りです 降水確率は６０％前後", of: weather))
        XCTAssertTrue(AssistantEcho.isEcho("api is waiting for you", of: "1 waiting: api. api is waiting for you to answer."))
        // Unrelated text, and short answers to its own question, are not echoes.
        XCTAssertFalse(AssistantEcho.isEcho("大阪の明日の天気を教えて", of: weather))
        XCTAssertFalse(AssistantEcho.isEcho("what is api doing", of: weather))
        XCTAssertFalse(AssistantEcho.isEcho("api-v2", of: "Which one: api, api-v2?"))
        XCTAssertFalse(AssistantEcho.isEcho("はい", of: "apiに送りますか？はいと言うかReturnを押してください。"))
        XCTAssertFalse(AssistantEcho.isEcho("", of: weather))
    }

    func testEchoIsOnlyCheckedAgainstWhatWasJustSaid() {
        var machine = on()
        machine.answer("All quiet, nothing needs you.", now: t0)
        machine.speechFinished(now: t0)
        XCTAssertTrue(machine.isEcho("all quiet nothing needs you", now: t0.addingTimeInterval(5)))
        XCTAssertFalse(machine.isEcho("what is api doing", now: t0.addingTimeInterval(5)))
        XCTAssertFalse(machine.isEcho("all quiet nothing needs you", now: t0.addingTimeInterval(AssistantMachine.echoMemory + 1)))
    }

    func testFollowUpWindowStartsWhenSpeechEnds() {
        var machine = on()
        _ = machine.hear("Jarvis status", names: names, now: t0)
        machine.answer("1 waiting: api.", now: t0)
        // A long answer: still speaking well past the window's length from its start.
        let end = t0.addingTimeInterval(AssistantMachine.followUpWindow + 5)
        XCTAssertEqual(machine.tick(now: end.addingTimeInterval(-1)), .ignore)
        XCTAssertEqual(machine.phase, .speaking)
        machine.speechFinished(now: end)
        XCTAssertEqual(machine.followUpUntil, end.addingTimeInterval(AssistantMachine.followUpWindow))
        // Within the echo guard: needs the name.
        XCTAssertEqual(machine.hear("what is api doing", names: names, now: end.addingTimeInterval(0.5)), .ignore)
        // After it, and within the window measured from the end: a short follow-up counts.
        XCTAssertEqual(machine.hear("what is api doing", names: names, now: end.addingTimeInterval(AssistantMachine.followUpWindow - 1)),
                       .handle(.workspaceStatus(target: "api")))
    }

    func testOnlyShortFollowUpsCountWithoutTheName() {
        var machine = on()
        _ = machine.hear("Jarvis status", names: names, now: t0)
        machine.answer("1 waiting: api.", now: t0)
        machine.speechFinished(now: t0)
        let later = t0.addingTimeInterval(2)
        XCTAssertEqual(machine.hear("so then I told him that we should really move the meeting to Thursday afternoon", names: names, now: later), .ignore)
        XCTAssertEqual(machine.hear("今日の会議の資料はもう全部できているから心配しなくて大丈夫だよ", names: names, now: later), .ignore)
        XCTAssertEqual(machine.phase, .listening)
        XCTAssertEqual(machine.hear("大阪は？", names: names, now: later), .handle(.question("大阪は")))
        XCTAssertTrue(AssistantAddressing.isShortFollowUp("what about tomorrow"))
        XCTAssertFalse(AssistantAddressing.isShortFollowUp(weather))
        // The hotkey and the name alone take any length.
        var keyed = on()
        keyed.hotkey(now: t0)
        XCTAssertEqual(keyed.hear("please explain to me in simple words what a monad is and why people like it so much", names: names, now: later),
                       .handle(.question("please explain to me in simple words what a monad is and why people like it so much")))
    }

    func testBargeInWhileSpeaking() {
        var machine = on()
        _ = machine.hear("ジャービス、明日の天気は", names: names, now: t0)
        let first = machine.request
        machine.answer(weather, request: first, now: t0.addingTimeInterval(5))
        XCTAssertEqual(machine.phase, .speaking)
        // Its name stops the voice and takes the new request at once.
        XCTAssertEqual(machine.hear("ジャービス、apiは何してる", names: names, now: t0.addingTimeInterval(7)),
                       .handle(.workspaceStatus(target: "api")))
        XCTAssertEqual(machine.phase, .thinking)
        XCTAssertEqual(machine.transcript, "apiは何してる")
        XCTAssertGreaterThan(machine.request, first)
        XCTAssertFalse(machine.voiceActive)
        // The rest of the weather answer, heard late, is still its own voice.
        XCTAssertEqual(machine.hear("降水確率は60%前後、最高気温は19度", names: names, now: t0.addingTimeInterval(8)), .ignore)
        // The name alone also stops it, and listens.
        machine.answer("api is running the tests.", request: machine.request, now: t0.addingTimeInterval(9))
        XCTAssertEqual(machine.hear("Jarvis", names: names, now: t0.addingTimeInterval(10)), .wake)
        XCTAssertEqual(machine.phase, .listening)
        XCTAssertEqual(machine.hear("approve api", names: names, now: t0.addingTimeInterval(11)), .handle(.approve(target: "api")))
    }

    func testBargeInWhileThinkingDropsTheStaleAnswer() {
        var machine = on()
        _ = machine.hear("Jarvis, search the weather in Tokyo", names: names, now: t0)
        let slow = machine.request
        XCTAssertEqual(machine.phase, .thinking)
        // Unaddressed talk while it thinks changes nothing.
        XCTAssertEqual(machine.hear("status", names: names, now: t0.addingTimeInterval(1)), .ignore)
        XCTAssertEqual(machine.request, slow)
        // A new topic by name: a new request, shown at once.
        XCTAssertEqual(machine.hear("Jarvis status", names: names, now: t0.addingTimeInterval(2)), .handle(.status))
        let fresh = machine.request
        XCTAssertNotEqual(fresh, slow)
        XCTAssertEqual(machine.transcript, "status")
        // Claude's answer to the old question comes late: dropped.
        XCTAssertFalse(machine.answer("Tokyo: sunny, high 20.", request: slow, now: t0.addingTimeInterval(30)))
        XCTAssertEqual(machine.phase, .thinking)
        XCTAssertNil(machine.answer)
        XCTAssertTrue(machine.answer("1 waiting: api.", request: fresh, now: t0.addingTimeInterval(31)))
        XCTAssertEqual(machine.phase, .speaking)
        XCTAssertEqual(machine.answer, "1 waiting: api.")
    }

    func testYesNoWhileConfirmingStillWorks() {
        var machine = on()
        _ = machine.hear("Jarvis reply to api: run the tests", names: names, now: t0)
        machine.answer("Send “run the tests” to api? Confirm by voice or press Return.", proposing: action, now: t0)
        // While the card is read out, other talk without the name is ignored; yes by name confirms (and stops the voice).
        XCTAssertEqual(machine.hear("lunch?", names: names, now: t0.addingTimeInterval(1)), .ignore)
        XCTAssertEqual(machine.hear("ジャービス、はい", names: names, now: t0.addingTimeInterval(2)), .execute(action))
        XCTAssertFalse(machine.voiceActive)
        // After it was read out: yes / no without the name, other talk ignored, the card kept.
        machine.answer("Send?", proposing: action, now: t0.addingTimeInterval(3))
        machine.speechFinished(now: t0.addingTimeInterval(4))
        XCTAssertEqual(machine.hear("lunch?", names: names, now: t0.addingTimeInterval(6)), .ignore)
        XCTAssertEqual(machine.pending, action)
        XCTAssertEqual(machine.hear("いいえ", names: names, now: t0.addingTimeInterval(7)), .cancelled)
        // The name alone while a card waits keeps it; a new command by name replaces it.
        machine.answer("Send?", proposing: action, now: t0.addingTimeInterval(8))
        XCTAssertEqual(machine.hear("Jarvis", names: names, now: t0.addingTimeInterval(9)), .wake)
        XCTAssertEqual(machine.phase, .confirming)
        XCTAssertEqual(machine.pending, action)
        XCTAssertEqual(machine.hear("yes", names: names, now: t0.addingTimeInterval(10)), .execute(action))
    }

    func testANoteWhileACardWaitsIsAlsoItsOwnVoice() {
        var machine = on()
        machine.answer("Send?", proposing: action, now: t0)
        machine.speechFinished(now: t0)
        machine.voiceStarted("Please press Return or click the button for this one.")
        XCTAssertEqual(machine.hear("what is api doing", names: names, now: t0.addingTimeInterval(1)), .ignore)
        machine.voiceFinished(now: t0.addingTimeInterval(3))
        XCTAssertEqual(machine.hear("please press return or click the button", names: names, now: t0.addingTimeInterval(5)), .ignore)
        XCTAssertEqual(machine.hear("yes", names: names, now: t0.addingTimeInterval(5)), .execute(action))
    }

    // MARK: Answering a card while it is read out

    func testAShortYesOrNoAnswersTheCardWhileItIsReadOut() {
        let card = "Send “run the tests” to api? Confirm by voice or press Return."
        for (word, step) in [("はい", AssistantMachine.Step.execute(action)), ("yes", .execute(action)), ("OK", .execute(action)),
                             ("いいえ", .cancelled), ("no", .cancelled), ("キャンセル", .cancelled)] {
            var machine = on()
            _ = machine.hear("Jarvis reply to api: run the tests", names: names, now: t0)
            machine.answer(card, proposing: action, now: t0)
            XCTAssertEqual(machine.phase, .speaking)
            XCTAssertEqual(machine.hear(word, names: names, now: t0.addingTimeInterval(1)), step, word)
            XCTAssertFalse(machine.voiceActive, word)
            XCTAssertNil(machine.pending, word)
        }
        // Japanese card.
        var machine = on()
        machine.answer("apiに「テストを実行して」を送りますか？声かReturnキーで確定してください。", proposing: action, now: t0)
        XCTAssertEqual(machine.hear("はい", names: names, now: t0.addingTimeInterval(1)), .execute(action))
        // Also in the second after it was read out (the echo guard), and while a note is said over the card.
        machine.answer("Send?", proposing: action, now: t0)
        machine.speechFinished(now: t0.addingTimeInterval(2))
        XCTAssertEqual(machine.hear("はい", names: names, now: t0.addingTimeInterval(2.3)), .execute(action))
    }

    func testTheCardsOwnWordsHeardBackDoNotAnswerIt() {
        // A reply whose text is "yes": the card says it, so "yes" heard while it speaks may be its own voice.
        var machine = on()
        machine.answer("Send “yes” to api? Confirm by voice or press Return.", proposing: action, now: t0)
        XCTAssertEqual(machine.hear("yes", names: names, now: t0.addingTimeInterval(1)), .ignore)
        XCTAssertEqual(machine.pending, action)
        // Other words still answer it; after the guard, yes too.
        XCTAssertEqual(machine.hear("いいえ", names: names, now: t0.addingTimeInterval(2)), .cancelled)
        machine.answer("Send “yes” to api? Confirm by voice or press Return.", proposing: action, now: t0)
        machine.speechFinished(now: t0.addingTimeInterval(3))
        XCTAssertEqual(machine.hear("yes", names: names, now: t0.addingTimeInterval(3.5)), .ignore)
        XCTAssertEqual(machine.hear("yes", names: names, now: t0.addingTimeInterval(5)), .execute(action))
        // A long echo of the card is never taken.
        machine.answer("Send “run the tests” to api? Confirm by voice or press Return.", proposing: action, now: t0)
        XCTAssertEqual(machine.hear("send run the tests to api", names: names, now: t0.addingTimeInterval(1)), .ignore)
        XCTAssertEqual(machine.pending, action)
    }

    func testAnEchoedWordIsAWholeWordInEnglish() {
        XCTAssertTrue(AssistantEcho.isEchoedWord("yes", of: "Send “yes” to api?"))
        XCTAssertTrue(AssistantEcho.isEchoedWord("Yes.", of: "Say YES or press Return."))
        XCTAssertFalse(AssistantEcho.isEchoedWord("no", of: "Nothing is running now, I know."))
        XCTAssertFalse(AssistantEcho.isEchoedWord("yes", of: "Confirm by voice or press Return."))
        XCTAssertTrue(AssistantEcho.isEchoedWord("はい", of: "「はい」と送りますか？"))
        XCTAssertFalse(AssistantEcho.isEchoedWord("はい", of: "声かReturnキーで確定してください。"))
    }

    func testADangerousCardStillNeedsAKeyWhileItIsReadOut() {
        var machine = on()
        var dangerous = action
        dangerous.reasons = [.destructive]
        machine.answer("Send “rm -rf build” to api? This one needs Return or a click.", proposing: dangerous, now: t0)
        XCTAssertEqual(machine.hear("はい", names: names, now: t0.addingTimeInterval(1)), .needsKey)
        XCTAssertEqual(machine.phase, .confirming)
        XCTAssertEqual(machine.pending, dangerous)
        XCTAssertEqual(machine.key(.confirm, now: t0.addingTimeInterval(2)), .execute(dangerous))
    }

    func testCancellingACardRemembersWhatWasCancelled() {
        var machine = on()
        machine.answer("Send?", proposing: action, now: t0)
        machine.speechFinished(now: t0)
        XCTAssertEqual(machine.hear("いいえ", names: names, now: t0.addingTimeInterval(2)), .cancelled)
        XCTAssertEqual(machine.cancelledAction, action)
        // The rest of the utterance goes on once the "cancelled" line has been said.
        machine.answer("I won't send it to api.", now: t0.addingTimeInterval(2))
        XCTAssertFalse(machine.proceed())
        machine.speechFinished(now: t0.addingTimeInterval(3))
        XCTAssertTrue(machine.proceed())
        XCTAssertEqual(machine.phase, .thinking)
    }
}

/// Short answers (#243): only what was asked, the first sentence of a long one spoken.
final class AssistantBrevityTests: XCTestCase {
    func testSentences() {
        XCTAssertEqual(AssistantBrevity.sentences("明日の船橋は晴れ、最高20度、最低9度です。降水確率は10%です。"),
                       ["明日の船橋は晴れ、最高20度、最低9度です。", "降水確率は10%です。"])
        XCTAssertEqual(AssistantBrevity.sentences("It is 19.5 degrees. Rain later! OK?"), ["It is 19.5 degrees.", "Rain later!", "OK?"])
        XCTAssertEqual(AssistantBrevity.sentences("api: waiting\nweb: working"), ["api: waiting", "web: working"])
        XCTAssertEqual(AssistantBrevity.sentences("「本当？」と聞いています。"), ["「本当？」と聞いています。"])
    }

    func testFirstSentences() {
        XCTAssertEqual(AssistantBrevity.first(1, of: "Running the tests. Then it will push."), "Running the tests.")
        XCTAssertEqual(AssistantBrevity.first(3, of: "A. B. C. D."), "A. B. C.")
        XCTAssertEqual(AssistantBrevity.first(1, of: "テストを実行中。次にpushします。"), "テストを実行中。")
        XCTAssertEqual(AssistantBrevity.first(2, of: "Only one."), "Only one.")
    }

    func testOnlyTheFirstSentenceOfALongAnswerIsSpoken() {
        let short = "明日の船橋は晴れ、最高20度、最低9度です。"
        XCTAssertEqual(AssistantBrevity.spoken(short), short)
        let long = short + "午前中は降水確率10%、午後は20%です。北寄りの風がやや強く、朝晩は冷え込むので上着をお持ちください。"
        XCTAssertGreaterThan(AssistantBrevity.spokenLength(long), AssistantBrevity.maxSpokenLength)
        XCTAssertEqual(AssistantBrevity.spoken(long), short)
        XCTAssertEqual(AssistantBrevity.spoken("Two short ones. Fine."), "Two short ones. Fine.")
    }
}

/// How the assistant runs Claude Code (#243): isolated from the user's setup, a fixed model, short answers.
final class AssistantClaudeTests: XCTestCase {
    private let world = AssistantWorld(workspaces: [.init(id: "w1", title: "api", state: .working, agent: "Claude")])

    private func assertIsolated(_ arguments: [String], file: StaticString = #filePath, line: UInt = #line) {
        let joined = arguments.joined(separator: "\u{1}")
        XCTAssertTrue(joined.contains(["--setting-sources", ""].joined(separator: "\u{1}")), file: file, line: line)
        XCTAssertTrue(arguments.contains("--no-session-persistence"), file: file, line: line)
        XCTAssertTrue(arguments.contains("--strict-mcp-config"), file: file, line: line)
        XCTAssertFalse(arguments.contains("--bare"), file: file, line: line)
        XCTAssertFalse(arguments.contains { $0.contains("dangerously") || $0 == "--permission-mode" }, file: file, line: line)
        XCTAssertEqual(arguments.first, "-p", file: file, line: line)
    }

    private func value(_ flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }

    func testWebAnswer() {
        let arguments = AssistantClaude.webArguments(question: "明日の船橋の天気は？", language: "Japanese",
                                                     now: Date(timeIntervalSince1970: 1_800_000_000),
                                                     timeZone: TimeZone(identifier: "Asia/Tokyo")!, locale: Locale(identifier: "ja_JP"))
        assertIsolated(arguments)
        XCTAssertEqual(value("--model", in: arguments), AssistantClaude.webModel)
        XCTAssertEqual(AssistantClaude.webModel, "sonnet")
        XCTAssertEqual(value("--output-format", in: arguments), "stream-json")
        XCTAssertTrue(arguments.contains("--include-partial-messages"))
        XCTAssertEqual(value("--tools", in: arguments), "WebSearch,WebFetch")
        XCTAssertEqual(value("--allowedTools", in: arguments), "WebSearch,WebFetch")
        let prompt = arguments[1]
        XCTAssertTrue(prompt.contains("The user's question: 明日の船橋の天気は？"))
        XCTAssertTrue(prompt.contains("one short sentence (two at most), only what was asked"))
        XCTAssertTrue(prompt.contains("「明日の<場所>は<天気>、最高<N>度、最低<N>度です。」"))
        XCTAssertTrue(prompt.contains("go only after a last line \"Sources:\""))
        XCTAssertTrue(prompt.contains("Asia/Tokyo"))
        XCTAssertFalse(prompt.contains("If you assumed a place"))
    }

    func testDetailedSummaryAndInterpreter() {
        let summary = AssistantClaude.detailedSummaryArguments(facts: "Claude in api", language: "English")
        assertIsolated(summary)
        XCTAssertEqual(value("--model", in: summary), "sonnet")
        XCTAssertEqual(value("--tools", in: summary), "")
        XCTAssertFalse(summary.contains("--allowedTools"))
        XCTAssertTrue(summary[1].contains("at most three short sentences"))
        let interpreter = AssistantClaude.interpreterArguments(utterance: "tell api to add tests", world: world, language: "English")
        assertIsolated(interpreter)
        XCTAssertEqual(value("--model", in: interpreter), AssistantClaude.interpreterModel)
        XCTAssertEqual(AssistantClaude.interpreterModel, "haiku")
        XCTAssertEqual(value("--tools", in: interpreter), "")
    }

    func testOnDeviceInstructionsAskForShortAnswers() {
        XCTAssertTrue(AssistantClaude.modelInstructions(language: "Japanese", web: false).contains("one short sentence (two at most)"))
        XCTAssertTrue(AssistantClaude.modelInstructions(language: "Japanese", web: true).contains(AssistantWeb.marker))
        XCTAssertTrue(AssistantClaude.summaryPrompt(facts: "f", screen: "s").contains("In one short sentence"))
    }

    func testEnvironmentHasNoCmdsVariables() {
        let environment = AssistantClaude.environment([
            "PATH": "/usr/bin", "HOME": "/Users/x", "CMDS_PANE_ID": "p1", "CMDS_WORKSPACE_ID": "w1", "CMDS_SOCKET_PATH": "/tmp/s",
        ])
        XCTAssertEqual(environment, ["PATH": "/usr/bin", "HOME": "/Users/x"])
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

/// Which free questions go to Claude Code with web search, and the on-device model's "needs the web" answer (#243).
final class AssistantWebTests: XCTestCase {
    func testTheUsersRealQuestionGoesToTheWeb() {
        let command = "明日の船橋の天気を教えて。インターネットで検索して教えて"
        XCTAssertEqual(AssistantIntent.parse(command), .question(command))
        XCTAssertTrue(AssistantWeb.needsWeb(command))
    }

    func testExplicitRequestsInJapanese() {
        for question in ["Swift 6.2の新機能を検索して", "このエラーメッセージを調べて", "ぐぐって", "ググってみて", "ネットで探して",
                         "インターネットで確認して", "クロードに聞いて", "Claudeに聞いて", "ウェブで見て"] {
            XCTAssertTrue(AssistantWeb.needsWeb(question), question)
        }
    }

    func testLiveTopicsInJapanese() {
        for question in ["明日の東京の天気は", "今日のニュースを教えて", "トヨタの株価は", "ドル円の為替は", "山手線の運行状況",
                         "最新のXcodeのバージョンは", "天気予報", "台風どこにいる", "今日の試合の結果"] {
            XCTAssertTrue(AssistantWeb.needsWeb(question), question)
        }
    }

    func testExplicitRequestsAndLiveTopicsInEnglish() {
        for question in ["search for the Swift 6.2 release notes", "look it up", "google the error", "ask Claude what a monad is",
                         "check online", "what's the weather in Tokyo tomorrow", "Weather forecast for Osaka", "any news about Apple",
                         "Apple stock price", "exchange rate dollar to yen", "today's headlines", "today’s top stories",
                         "the latest version of Xcode", "who won the game last night", "train status on the Yamanote line"] {
            XCTAssertTrue(AssistantWeb.needsWeb(question), question)
        }
    }

    func testOnlineAndLatestNeedALiveContext() {
        for question in ["is GitHub online", "is Slack down right now", "search online for the Swift 6.2 release notes",
                         "find it on the web", "what's the latest version of Xcode", "latest news about Apple",
                         "the latest release of Node", "current version of Swift", "最新ニュースを教えて", "最新のmacOSのバージョンは"] {
            XCTAssertTrue(AssistantWeb.needsWeb(question), question)
        }
        for question in ["what is an online algorithm", "latest commit in api", "what's the latest commit in api",
                         "explain online learning", "what is the internet", "show me the latest error in web",
                         "apiの最新のコミットは", "is this function pure"] {
            XCTAssertFalse(AssistantWeb.needsWeb(question), question)
        }
    }

    func testOrdinaryQuestionsStayOnDevice() {
        for question in ["what is a monad", "explain binary search", "tell me a joke", "1たす1は", "モナドって何",
                         "おすすめの変数名は", "what does git rebase do", "how do I write a for loop in Swift",
                         "ハンドルの意味は", "Claude Codeとは何", "", "   "] {
            XCTAssertFalse(AssistantWeb.needsWeb(question), question)
        }
    }

    func testTheMarkerAndCantKnowAnswers() {
        XCTAssertTrue(AssistantWeb.answerNeedsWeb("[[NEEDS_WEB]]"))
        XCTAssertTrue(AssistantWeb.answerNeedsWeb(" [NEEDS_WEB] "))
        XCTAssertTrue(AssistantWeb.answerNeedsWeb("NEEDS_WEB"))
        XCTAssertTrue(AssistantWeb.answerNeedsWeb("［［ＮＥＥＤＳ＿ＷＥＢ］］"))
        XCTAssertTrue(AssistantWeb.answerNeedsWeb("申し訳ありませんが、インターネットで検索できません。天気予報アプリをご確認ください。"))
        XCTAssertTrue(AssistantWeb.answerNeedsWeb("リアルタイムの情報にはアクセスできません。"))
        XCTAssertTrue(AssistantWeb.answerNeedsWeb("Sorry, I can't browse the internet."))
        XCTAssertTrue(AssistantWeb.answerNeedsWeb("I don't have access to real-time data."))
        XCTAssertFalse(AssistantWeb.answerNeedsWeb("A monad is a way to chain computations."))
        XCTAssertFalse(AssistantWeb.answerNeedsWeb("apiは入力を待っています。"))
        XCTAssertFalse(AssistantWeb.answerNeedsWeb("I can't run commands, but api is waiting for you."))
    }

    func testTheMarkerIsNeverSpoken() {
        XCTAssertEqual(AssistantWeb.withoutMarker("[[NEEDS_WEB]]"), "")
        XCTAssertEqual(AssistantWeb.withoutMarker("It rains. [[needs_web]]"), "It rains.")
        XCTAssertEqual(AssistantWeb.withoutMarker("A monad chains computations."), "A monad chains computations.")
    }

    func testClaudesAnswerIsMadeSpeakable() {
        let answer = """
        **明日**の船橋市は晴れです。最高気温は20度です。

        Sources:
        - [tenki.jp](https://tenki.jp/forecast/3/15/4510/12204/)
        """
        XCTAssertEqual(AssistantWeb.speakable(answer), "明日の船橋市は晴れです。最高気温は20度です。")
        XCTAssertEqual(AssistantWeb.speakable("See [the forecast](https://example.com/a) (https://example.com/b) today."),
                       "See the forecast today.")
        XCTAssertEqual(AssistantWeb.speakable("# Weather\n- Sunny\n- 20 °C"), "Weather Sunny 20 °C")
        XCTAssertEqual(AssistantWeb.speakable("晴れです。\n\n出典: tenki.jp"), "晴れです。")
    }
}

/// Commands for several sessions and free commands through the interpreter (#243).
final class AssistantManySessionsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let yesNo = AgentPromptOptions(question: "Run the tests?", options: [
        .init(number: 1, label: "Yes", selected: true), .init(number: 2, label: "No", selected: false)])
    private let deleteIt = AgentPromptOptions(question: "Run rm -rf build?", options: [
        .init(number: 1, label: "Yes", selected: true), .init(number: 2, label: "No", selected: false)])

    private func world() -> AssistantWorld {
        AssistantWorld(workspaces: [
            .init(id: "w1", title: "api", state: .needsUser, agent: "Claude", directory: "/tmp/api",
                  panes: [.init(id: "p1", title: "zsh", agent: "Claude", waiting: true, prompt: yesNo)]),
            .init(id: "w2", title: "web", state: .working, agent: "Codex", topic: "Login form", directory: "/tmp/web",
                  panes: [.init(id: "p2", title: "zsh", agent: "Codex")]),
            .init(id: "w3", title: "docs", directory: "/tmp/docs", panes: [.init(id: "p3", title: "zsh")]),
            .init(id: "w4", title: "infra", state: .needsUser, agent: "Claude", directory: "/tmp/infra",
                  panes: [.init(id: "p4", title: "zsh", agent: "Claude", waiting: true, prompt: deleteIt)]),
            .init(id: "w5", title: "app", state: .working, agent: "Claude", directory: "/tmp/app",
                  panes: [.init(id: "p5", title: "claude", agent: "Claude"), .init(id: "p6", title: "codex", agent: "Codex")]),
        ], now: now)
    }

    private func plan(_ intent: AssistantIntent) -> AssistantPlan {
        AssistantPlanner.plan(intent, world: world(), strings: .english)
    }

    func testRulesForEverySession() {
        for text in ["全部のセッションを確認して", "各セッションの状況を順番に教えて", "それぞれのワークスペースをチェックして",
                     "check all sessions", "go through every agent one by one", "check each workspace"] {
            XCTAssertEqual(AssistantIntent.parse(text), .checkAll(.all, detailed: false), text)
        }
        XCTAssertEqual(AssistantIntent.parse("入力待ちのセッションを全部見て"), .checkAll(.waiting, detailed: false))
        XCTAssertEqual(AssistantIntent.parse("作業中のエージェントを確認して"), .checkAll(.working, detailed: false))
        XCTAssertEqual(AssistantIntent.parse("check the waiting sessions"), .checkAll(.waiting, detailed: false))
        XCTAssertEqual(AssistantIntent.parse("各セッションの状況を詳しく教えて"), .checkAll(.all, detailed: true))
        for text in ["入力待ちのものに全部はいと答えて", "全部にはいと答えて", "全部承認して", "approve all", "yes to all",
                     "approve all the waiting ones"] {
            XCTAssertEqual(AssistantIntent.parse(text), .approveMany(.waiting), text)
        }
        // The single-session commands and the overall status stay as they were.
        XCTAssertEqual(AssistantIntent.parse("みんなの状況を教えて"), .status)
        XCTAssertEqual(AssistantIntent.parse("apiを承認して"), .approve(target: "api"))
        XCTAssertTrue(AssistantIntent.parse("approve all").acts)
        XCTAssertFalse(AssistantIntent.parse("check all sessions").acts)
    }

    func testCheckAllGoesThroughEachSessionWithAnAgent() {
        guard case .summarizeEach(let items, let detailed) = plan(.checkAll(.all, detailed: false)) else { return XCTFail() }
        XCTAssertFalse(detailed)
        XCTAssertEqual(items.map(\.title), ["api", "infra", "web", "app › claude", "app › codex"])
        XCTAssertEqual(items.map(\.paneID), ["p1", "p4", "p2", "p5", "p6"])
        guard case .summarizeEach(let waiting, _) = plan(.checkAll(.waiting, detailed: true)) else { return XCTFail() }
        XCTAssertEqual(waiting.map(\.title), ["api", "infra"])
        let quiet = AssistantWorld(workspaces: [.init(id: "w3", title: "docs", panes: [.init(id: "p3", title: "zsh")])], now: now)
        XCTAssertEqual(AssistantPlanner.plan(.checkAll(.waiting, detailed: false), world: quiet, strings: .english),
                       .answer("No session is waiting for you."))
        XCTAssertEqual(AssistantPlanner.plan(.checkAll(.all, detailed: false), world: quiet, strings: .english),
                       .answer("No agents are running."))
    }

    func testApproveAllIsOneCardAndADangerousOneNeedsAKey() {
        guard case .propose(let batch, let prompt) = plan(.approveMany(.waiting)) else { return XCTFail() }
        XCTAssertEqual(batch.all.map(\.workspaceTitle), ["api", "infra"])
        XCTAssertEqual(batch.all.map(\.paneID), ["p1", "p4"])
        XCTAssertEqual(batch.all.map(\.kind), [.choose(1), .choose(1)])
        XCTAssertEqual(batch.reasons, [], "api's own question is harmless")
        XCTAssertEqual(batch.allReasons, [.destructive])
        XCTAssertEqual(batch.confirmation, .keyOrClick, "one dangerous approval makes the whole card need Return or a click")
        XCTAssertEqual(prompt, "Choose option 1 in api, infra? This one needs Return or a click.")
    }

    func testReplyToSeveralNamedSessions() {
        let intent = AssistantIntent.parse("api と web にテストを実行してと伝えて")
        guard case .propose(let batch, let prompt) = AssistantPlanner.plan(intent, world: world(), strings: .english) else {
            return XCTFail("\(intent)")
        }
        XCTAssertEqual(batch.all.map(\.paneID), ["p1", "p2"])
        XCTAssertEqual(Set(batch.all.map(\.text)), ["テストを実行して"])
        XCTAssertEqual(batch.confirmation, .voiceOrKey)
        XCTAssertEqual(prompt, "Send “テストを実行して” to api, web? Confirm by voice or press Return.")
        if case .propose(let english, _) = AssistantPlanner.plan(AssistantIntent.parse("tell api and web to run the tests"),
                                                                 world: world(), strings: .english) {
            XCTAssertEqual(english.all.map(\.workspaceTitle), ["api", "web"])
        } else {
            XCTFail()
        }
    }

    func testSeveralSessionsAskBackOrLeaveOut() {
        // A named workspace that is not clear asks back, never a guess.
        XCTAssertEqual(plan(.replyMany(.named(["api", "app"]), text: "hi")),
                       .askBack("app has several panes (claude, codex). Please use the reply panel."))
        XCTAssertEqual(plan(.replyMany(.named(["api", "nope"]), text: "hi")), .askBack("I can't find a workspace called nope."))
        // "All": the unclear one is left out and said so.
        guard case .propose(let batch, let prompt) = plan(.replyMany(.working, text: "status?")) else { return XCTFail() }
        XCTAssertEqual(batch.all.map(\.workspaceTitle), ["web"])
        XCTAssertEqual(prompt, "Send “status?” to web? Left out: app. Confirm by voice or press Return.")
        // Waiting, but nobody shows a question to approve: said so, not "nobody waits".
        var noPrompt = world()
        noPrompt.workspaces[0].panes[0].prompt = nil
        noPrompt.workspaces[3].panes[0].prompt = nil
        XCTAssertEqual(AssistantPlanner.plan(.approveMany(.waiting), world: noPrompt, strings: .english),
                       .answer("There is nothing to send. Left out: api, infra."))
        noPrompt.workspaces[3].state = .working
        XCTAssertEqual(AssistantPlanner.plan(.approveMany(.waiting), world: noPrompt, strings: .english),
                       .answer("api isn't asking anything."))
        // A dangerous text needs a key for all of them.
        guard case .propose(let push, _) = plan(.replyMany(.named(["api", "web"]), text: "git push")) else { return XCTFail() }
        XCTAssertEqual(push.confirmation, .keyOrClick)
    }

    func testInterpreterOutputIsParsed() {
        let output = """
        ```json
        {"kind": "instruct", "targets": ["api"], "filter": "named", "text": "ログイン画面のテストを書いてください", "detailed": false}
        ```
        """
        let parsed = AssistantInterpretation.parse(output)
        XCTAssertEqual(parsed, AssistantInterpretation(kind: .instruct, targets: ["api"], filter: .named,
                                                       text: "ログイン画面のテストを書いてください"))
        XCTAssertEqual(parsed?.intent(in: world()), .reply(target: "api", text: "ログイン画面のテストを書いてください"))
        XCTAssertNil(AssistantInterpretation.parse("I can't help with that."))
        XCTAssertNil(AssistantInterpretation.parse("{not json}"))
        // Unknown or missing fields fall back to a question.
        XCTAssertEqual(AssistantInterpretation.parse(#"{"kind": "launch"}"#)?.kind, .question)
        XCTAssertNil(AssistantInterpretation.parse(#"{"kind": "question", "targets": [], "filter": "all", "text": ""}"#)?.intent(in: world()))
    }

    func testInterpretationsBecomeIntents() {
        let w = world()
        XCTAssertEqual(AssistantInterpretation(kind: .instruct, targets: ["api", "web"], filter: .named, text: "Please run the tests.")
            .intent(in: w), .replyMany(.named(["api", "web"]), text: "Please run the tests."))
        XCTAssertEqual(AssistantInterpretation(kind: .instruct, targets: [], filter: .waiting, text: "続けてください").intent(in: w),
                       .replyMany(.waiting, text: "続けてください"))
        XCTAssertEqual(AssistantInterpretation(kind: .approve, targets: ["api"], filter: .waiting).intent(in: w), .approveMany(.waiting))
        XCTAssertEqual(AssistantInterpretation(kind: .approve, targets: ["infra"], filter: .named).intent(in: w), .approve(target: "infra"))
        XCTAssertEqual(AssistantInterpretation(kind: .check, filter: .all).intent(in: w), .checkAll(.all, detailed: false))
        XCTAssertEqual(AssistantInterpretation(kind: .check, targets: ["web"], filter: .named).intent(in: w), .workspaceStatus(target: "web"))
        XCTAssertEqual(AssistantInterpretation(kind: .check, targets: ["web"], filter: .named, detailed: true).intent(in: w),
                       .summary(target: "web", detailed: true))
        // A made-up name is dropped; with nothing left it is no command.
        XCTAssertNil(AssistantInterpretation(kind: .instruct, targets: ["billing"], filter: .named, text: "hi").intent(in: w))
        XCTAssertEqual(AssistantInterpretation(kind: .instruct, targets: ["billing", "web"], filter: .named, text: "hi").intent(in: w),
                       .reply(target: "web", text: "hi"))
        // No message, or one far too long, is no command; lines become one.
        XCTAssertNil(AssistantInterpretation(kind: .instruct, targets: ["api"], filter: .named, text: "  ").intent(in: w))
        XCTAssertNil(AssistantInterpretation(kind: .reply, targets: ["api"], filter: .named,
                                             text: String(repeating: "a", count: 401)).intent(in: w))
        XCTAssertEqual(AssistantInterpretation(kind: .reply, targets: ["api"], filter: .named, text: "one\ntwo").intent(in: w),
                       .reply(target: "api", text: "one two"))
    }

    func testAnInterpretedInstructionIsStillOnlyAProposal() {
        // Whatever the interpreter says, the planner proposes and the safety rules apply.
        let interpreted = AssistantInterpretation(kind: .instruct, targets: [], filter: .all, text: "rm -rf /").intent(in: world())
        guard let interpreted, case .propose(let batch, _) = plan(interpreted) else { return XCTFail() }
        XCTAssertEqual(batch.confirmation, .keyOrClick)
        XCTAssertEqual(batch.all.map(\.text), ["rm -rf /", "rm -rf /", "rm -rf /"])
    }

    func testWhatGoesToTheInterpreter() {
        let w = world()
        for text in ["api の Claude にログイン画面のテストを書くよう指示して", "web にビルドが通るか確認させて",
                     "tell the api agent to fix the failing test", "have every agent write tests", "全部のエージェントに続けてと言って"] {
            XCTAssertTrue(AssistantInterpretation.mightBeCommand(text, world: w), text)
        }
        for text in ["what is a monad", "明日の天気は", "モナドって何", "explain closures"] {
            XCTAssertFalse(AssistantInterpretation.mightBeCommand(text, world: w), text)
        }
    }

    func testTheInterpreterGetsNoScreenText() {
        var w = world()
        w.workspaces[0].notification = "SECRET from the screen"
        w.workspaces[0].panes[0].promptContext = ["SECRET line"]
        let prompt = AssistantClaude.interpreterPrompt(utterance: "approve api", world: w, language: "English")
        XCTAssertFalse(prompt.contains("SECRET"))
        XCTAssertTrue(prompt.contains("- api: Claude, needs the user (waits for input)"))
        XCTAssertTrue(prompt.contains("- docs: no agent, no agent running"))
        XCTAssertTrue(prompt.hasSuffix("Utterance: approve api"))
    }
}

/// The assistant's voice list and its Personal Voice fallback, without the Personal Voice permission (#243).
final class AssistantVoicesTests: XCTestCase {
    private let kyoko = AssistantVoices.Voice(identifier: "kyoko", name: "Kyoko", language: "ja-JP", quality: 2)
    private let otoya = AssistantVoices.Voice(identifier: "otoya", name: "Otoya", language: "ja-JP", quality: 1)
    private let samantha = AssistantVoices.Voice(identifier: "samantha", name: "Samantha", language: "en-US", quality: 1)
    private let mine = AssistantVoices.Voice(identifier: "personal.en", name: "Ryo", language: "en-US", isPersonal: true)

    func testTheListHasTheLanguagesSystemVoicesAndPersonalVoicesApart() {
        let voices = [otoya, samantha, mine, kyoko]
        XCTAssertEqual(AssistantVoices.system(voices, language: "ja-JP"), [kyoko, otoya])
        XCTAssertEqual(AssistantVoices.system(voices, language: "en-US"), [samantha])
        XCTAssertEqual(AssistantVoices.personal(voices, language: "en-US"), [mine])
        XCTAssertEqual(AssistantVoices.personal(voices, language: "ja-JP"), [])
    }

    func testAPersonalVoiceThatCannotSpeakTheLanguageFallsBackToTheSystemVoice() {
        let voices = [kyoko, samantha, mine]
        XCTAssertEqual(AssistantVoices.resolve(chosen: "personal.en", among: voices, language: "en-US").voice, mine)
        let japanese = AssistantVoices.resolve(chosen: "personal.en", among: voices, language: "ja-JP")
        XCTAssertNil(japanese.voice)
        XCTAssertTrue(japanese.fellBack)
        // Gone (permission withdrawn, voice deleted): the system voice.
        XCTAssertTrue(AssistantVoices.resolve(chosen: "personal.en", among: [kyoko], language: "en-US").fellBack)
        let system = AssistantVoices.resolve(chosen: nil, among: voices, language: "ja-JP")
        XCTAssertNil(system.voice)
        XCTAssertFalse(system.fellBack)
        XCTAssertEqual(AssistantVoices.resolve(chosen: "kyoko", among: voices, language: "ja_JP").voice, kyoko)
    }

    func testWhatSettingsSaysAboutPersonalVoice() {
        XCTAssertEqual(AssistantVoices.personalVoiceState(.notDetermined, voices: [kyoko], language: "ja-JP"), .notRequested)
        XCTAssertEqual(AssistantVoices.personalVoiceState(.denied, voices: [kyoko], language: "ja-JP"), .denied)
        XCTAssertEqual(AssistantVoices.personalVoiceState(.unsupported, voices: [kyoko], language: "ja-JP"), .unsupported)
        XCTAssertEqual(AssistantVoices.personalVoiceState(.authorized, voices: [kyoko], language: "ja-JP"), .noneCreated)
        XCTAssertEqual(AssistantVoices.personalVoiceState(.authorized, voices: [kyoko, mine], language: "en-US"), .available([mine]))
        XCTAssertEqual(AssistantVoices.personalVoiceState(.authorized, voices: [kyoko, mine], language: "ja-JP"),
                       .otherLanguagesOnly(["en-US"]))
    }
}

/// Which utterance the voice is speaking: late callbacks of a stopped one end nothing (#261).
final class AssistantUtterancesTests: XCTestCase {
    func testNormalFinish() {
        var utterances = AssistantUtterances<String>()
        let first = utterances.start("first")
        XCTAssertEqual(utterances.current, first)
        XCTAssertEqual(utterances.ended(first), "first")
        XCTAssertNil(utterances.current)
        // didFinish after didCancel (the synthesizer may send both): the completion runs once.
        XCTAssertNil(utterances.ended(first))
        XCTAssertNil(utterances.stop())
    }

    func testCancelEndsTheCurrentOne() {
        var utterances = AssistantUtterances<String>()
        let first = utterances.start("first")
        // Cancelled by the system, not by stop(): its didCancel ends it.
        XCTAssertEqual(utterances.ended(first), "first")
        XCTAssertNil(utterances.current)
    }

    func testStopThenSpeakAgainIgnoresTheFirstOnesLateCallbacks() {
        var utterances = AssistantUtterances<String>()
        let first = utterances.start("first")
        // Barge-in or a new answer: stop() ends the first at once…
        XCTAssertEqual(utterances.stop(), "first")
        let second = utterances.start("second")
        XCTAssertNotEqual(first, second)
        // …and its didCancel and didFinish, delivered after the second was queued, do not end the second.
        XCTAssertNil(utterances.ended(first))
        XCTAssertNil(utterances.ended(first))
        XCTAssertEqual(utterances.current, second)
        XCTAssertEqual(utterances.ended(second), "second")
    }

    func testStopWithNothingSpokenIsNil() {
        var utterances = AssistantUtterances<String>()
        XCTAssertNil(utterances.stop())
        XCTAssertNil(utterances.ended(1))
    }
}

private extension AssistantWorld {
    /// The same world with workspace `id` replaced.
    func replacing(_ id: String, with workspace: Workspace) -> AssistantWorld {
        var world = self
        world.workspaces = workspaces.map { $0.id == id ? workspace : $0 }
        return world
    }
}

private extension AssistantWorld.Match {
    var found: AssistantWorld.Workspace? {
        if case .found(let workspace) = self { return workspace }
        return nil
    }
}
