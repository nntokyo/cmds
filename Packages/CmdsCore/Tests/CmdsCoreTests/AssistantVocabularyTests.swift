import XCTest
@testable import CmdsCore

/// Names as speech recognition hears them, start intents with places and tasks, several requests in one utterance,
/// the on-device model's apologies, places, safe command lines and the follow-through on given tasks (#243).
final class AssistantVocabularyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func world(_ extra: [AssistantWorld.Workspace] = []) -> AssistantWorld {
        AssistantWorld(workspaces: [
            .init(id: "w1", title: "api", state: .working, agent: "Claude", topic: "Add tests", directory: "/tmp/api",
                  panes: [.init(id: "p1", title: "zsh", agent: "Claude")]),
            .init(id: "w2", title: "web", directory: "/tmp/web", panes: [.init(id: "p2", title: "zsh")]),
        ] + extra, now: now)
    }

    private func plan(_ text: String, _ world: AssistantWorld? = nil, folders: @escaping (String) -> [String] = { _ in [] }) -> AssistantPlan {
        AssistantPlanner.plan(AssistantIntent.parse(text), world: world ?? self.world(), strings: .english, folders: folders)
    }

    // MARK: Recognition vocabulary

    func testContextualStrings() {
        let strings = AssistantVocabulary.contextualStrings(names: ["ジャービス", "Jarvis"], titles: ["api", "web", "API", "", "~"],
                                                            agents: ["Claude", "Codex"])
        XCTAssertEqual(strings, ["ジャービス", "Jarvis", "Claude", "Claude Code", "クロードコード", "Codex", "cmds", "api", "web"])
        let many = AssistantVocabulary.contextualStrings(names: [], titles: (0..<300).map { "ws\($0)" })
        XCTAssertEqual(many.count, AssistantVocabulary.maxContextualStrings)
    }

    // MARK: Names as heard

    func testClaudeCodeAsMisheard() {
        for heard in ["クロトコート", "クロードコード", "クロードコート", "cloud code", "claude code", "クラウドコード", "Claude Code"] {
            XCTAssertEqual(AssistantVocabulary.normalizingAgents("\(heard)を立ち上げて"), "Claude Code を立ち上げて", heard)
        }
        XCTAssertEqual(AssistantVocabulary.normalizingAgents("apiは何してる"), "apiは何してる")
    }

    func testReadingsOfASCIINames() {
        let api = AssistantVocabulary.readings("api")
        XCTAssertTrue(api.contains("api"))
        XCTAssertTrue(api.contains("エピアイ"))  // エーピーアイ without the long marks
        XCTAssertEqual(AssistantVocabulary.soundDistance("エーピーアイ", "api"), 0)
        XCTAssertEqual(AssistantVocabulary.soundDistance("えーぴーあい", "API"), 0)
        XCTAssertEqual(AssistantVocabulary.soundDistance("EPA", "api"), 1)
        XCTAssertNil(AssistantVocabulary.soundDistance("docs", "api"))
        XCTAssertNil(AssistantVocabulary.soundDistance("web", "api"))
    }

    func testFuzzyWorkspaceMatchIsConservative() {
        let w = world()
        XCTAssertEqual(w.find("EPA"), .found(w.workspaces[0]))
        XCTAssertEqual(w.find("エーピーアイ"), .found(w.workspaces[0]))
        XCTAssertEqual(w.find("nowhere"), .notFound)
        XCTAssertEqual(w.find("monad"), .notFound)
        // A workspace that is really called epa wins; nothing is ever made up.
        let both = world([.init(id: "w3", title: "epa", directory: "/tmp/epa")])
        XCTAssertEqual(both.find("EPA"), .found(both.workspaces[2]))
        // Two that sound alike: ask which.
        let two = world([.init(id: "w3", title: "apa", directory: "/tmp/apa")])
        if case .ambiguous(let list) = two.find("EPA") { XCTAssertEqual(Set(list.map(\.title)), ["api", "apa"]) } else { XCTFail() }
        XCTAssertEqual(w.mentioned(in: "クロトコートを立ち上げて、 EPAの進捗情報を教えて").map(\.title), ["api"])
        XCTAssertEqual(w.mentioned(in: "what is a monad").map(\.title), [])
    }

    // MARK: Starting agents

    func testStartIntents() {
        let parse = AssistantIntent.parse
        XCTAssertEqual(parse("Claude Codeを立ち上げて"), .startAgent(.claude, place: nil, task: nil))
        XCTAssertEqual(parse("クロトコートを立ち上げて"), .startAgent(.claude, place: nil, task: nil))
        XCTAssertEqual(parse("クロードを起動して"), .startAgent(.claude, place: nil, task: nil))
        XCTAssertEqual(parse("Codexを開いて"), .startAgent(.codex, place: nil, task: nil))
        XCTAssertEqual(parse("webでクロードコードを始めて"), .startAgent(.claude, place: "web", task: nil))
        XCTAssertEqual(parse("cmds のリポジトリで Claude Code を起動して"), .startAgent(.claude, place: "cmds", task: nil))
        XCTAssertEqual(parse("start Claude Code"), .startAgent(.claude, place: nil, task: nil))
        XCTAssertEqual(parse("launch claude"), .startAgent(.claude, place: nil, task: nil))
        XCTAssertEqual(parse("open Claude Code in web"), .startAgent(.claude, place: "web", task: nil))
    }

    func testStartWithATask() {
        let parse = AssistantIntent.parse
        XCTAssertEqual(parse("cmds のリポジトリで Claude Code を起動して、ログイン画面のテストを書かせて"),
                       .startAgent(.claude, place: "cmds", task: "ログイン画面のテストを書いてください"))
        XCTAssertEqual(parse("Claude Codeを起動してテストを直させて"),
                       .startAgent(.claude, place: nil, task: "テストを直してください"))
        XCTAssertEqual(parse("start Claude in api and have it fix the failing tests"),
                       .startAgent(.claude, place: "api", task: "Fix the failing tests."))
        XCTAssertEqual(parse("launch codex in web, then tell it to add a login page"),
                       .startAgent(.codex, place: "web", task: "Add a login page."))
        XCTAssertEqual(parse("api で Claude にこのバグを直させて"), .delegate(.claude, place: "api", task: "このバグを直してください"))
        XCTAssertEqual(parse("api の Claude にログイン画面のテストを書くよう指示して"),
                       .delegate(.claude, place: "api", task: "ログイン画面のテストを書いてください"))
        XCTAssertEqual(parse("webのクロードに修正するように伝えて"), .delegate(.claude, place: "web", task: "修正してください"))
    }

    func testTheExactTranscript() {
        // 「ジャービス、クロードコードを立ち上げて、APIの進捗情報を教えて」 as SpeechTranscriber heard it.
        let intent = AssistantIntent.parse("クロトコートを立ち上げて、 EPAの進捗情報を教えて")
        XCTAssertEqual(intent, .sequence([.startAgent(.claude, place: "EPA", task: nil), .workspaceStatus(target: "EPA")]))
        XCTAssertTrue(intent.acts)
        // First a card to start Claude in api's folder, saying what comes next; after it, api's progress.
        guard case .propose(let action, let prompt) = AssistantPlanner.plan(intent, world: world(), strings: .english) else {
            return XCTFail()
        }
        XCTAssertEqual(action.kind, .startAgent(.claude, directory: "/tmp/api", task: nil))
        XCTAssertEqual(action.text, "claude")
        XCTAssertEqual(prompt, "Start Claude in /tmp/api? Confirm by voice or press Return. Then I'll tell you how api is doing.")
        guard case .summarize(let id, _, false, _) = AssistantPlanner.plan(.workspaceStatus(target: "EPA"), world: world(), strings: .english) else {
            return XCTFail()
        }
        XCTAssertEqual(id, "w1")
        // In English.
        XCTAssertEqual(AssistantIntent.parse("start cloud code, then tell me the status of api"),
                       .sequence([.startAgent(.claude, place: "api", task: nil), .workspaceStatus(target: "api")]))
    }

    func testCompoundsAreConservative() {
        let parse = AssistantIntent.parse
        // Dictated text is never split.
        XCTAssertEqual(parse("tell api to run the tests, then report"), .reply(target: "api", text: "run the tests, then report"))
        XCTAssertEqual(parse("apiに「テスト、実行して」と返信"), .reply(target: "api", text: "テスト、実行して"))
        // A part not understood: the whole is a question (for the interpreter or the model).
        XCTAssertEqual(parse("Claude Codeを起動して、天気はどう"), .question("Claude Codeを起動して、天気はどう"))
        XCTAssertEqual(parse("はい、お願いします"), .question("はい、お願いします"))
        // Both understood, nothing to start: two requests.
        XCTAssertEqual(parse("apiを承認して、webの状況を教えて"), .sequence([.approve(target: "api"), .workspaceStatus(target: "web")]))
    }

    func testStartWithoutAPlace() {
        // The workspace the last request was about, else the selected one, else ask.
        var w = world()
        XCTAssertEqual(plan("Claude Codeを立ち上げて", w), .askBack("Which folder should I start it in?"))
        w.focusedID = "w2"
        if case .propose(let action, _) = plan("Claude Codeを立ち上げて", w) {
            XCTAssertEqual(action.kind, .startAgent(.claude, directory: "/tmp/web", task: nil))
        } else { XCTFail() }
        w.recentID = "w1"
        if case .propose(let action, _) = plan("start claude", w) {
            XCTAssertEqual(action.kind, .startAgent(.claude, directory: "/tmp/api", task: nil))
        } else { XCTFail() }
    }

    func testStartWithATaskIsOneCard() {
        guard case .propose(let action, let prompt) = plan("start Claude in web and have it fix the failing tests") else { return XCTFail() }
        XCTAssertEqual(action.kind, .startAgent(.claude, directory: "/tmp/web", task: "Fix the failing tests."))
        XCTAssertEqual(action.text, "claude 'Fix the failing tests.'")
        XCTAssertEqual(action.confirmation, .voiceOrKey)
        XCTAssertEqual(prompt, "Start Claude in /tmp/web with “Fix the failing tests.”? Confirm by voice or press Return.")
        // A dangerous task needs Return or a click.
        guard case .propose(let danger, _) = plan("start claude in web and have it run git push --force") else { return XCTFail() }
        XCTAssertEqual(danger.confirmation, .keyOrClick)
    }

    func testDelegateGoesToTheRunningAgentElseStartsOne() {
        // api runs Claude: the task is typed there.
        guard case .propose(let reply, _) = plan("api で Claude にこのバグを直させて") else { return XCTFail() }
        XCTAssertEqual(reply.kind, .reply)
        XCTAssertEqual(reply.paneID, "p1")
        XCTAssertEqual(reply.text, "このバグを直してください")
        // EPA heard for api.
        guard case .propose(let misheard, _) = plan("EPA の Claude にテストを書かせて") else { return XCTFail() }
        XCTAssertEqual(misheard.paneID, "p1")
        // web runs none: a new Claude starts there with it.
        guard case .propose(let start, _) = plan("web で Claude にこのバグを直させて") else { return XCTFail() }
        XCTAssertEqual(start.kind, .startAgent(.claude, directory: "/tmp/web", task: "このバグを直してください"))
    }

    // MARK: Places

    private func tree(_ folders: [String: [String]], repos: Set<String>) -> AssistantPlaces.Tree {
        AssistantPlaces.Tree(folders: { folders[$0] ?? [] }, isRepository: { repos.contains($0) })
    }

    func testProjectFolders() {
        let places = AssistantPlaces(roots: ["/h/Source", "/h/src"], tree: tree([
            "/h/Source": ["tools", "cmds-old", "site"],
            "/h/Source/tools": ["cmds", "notes"],
            "/h/Source/tools/cmds": ["Packages"],
            "/h/Source/site": ["docs"],
            "/h/src": ["cmds", "a"],
            "/h/src/a": ["b"], "/h/src/a/b": ["c"], "/h/src/a/b/c": ["deep"],
        ], repos: ["/h/Source/tools/cmds", "/h/src/cmds"]))
        // Two repositories called cmds: both offered (the planner asks which).
        XCTAssertEqual(Set(places.find("cmds")), ["/h/Source/tools/cmds", "/h/src/cmds"])
        XCTAssertEqual(places.find("tools cmds"), ["/h/Source/tools/cmds"])
        XCTAssertEqual(places.find("シーエムディーエス").count, 2)
        XCTAssertEqual(places.find("docs"), ["/h/Source/site/docs"])
        XCTAssertEqual(places.find("notes"), ["/h/Source/tools/notes"])
        // Not inside a repository, not deeper than three levels.
        XCTAssertEqual(places.find("Packages"), [])
        XCTAssertEqual(places.find("deep"), [])
        XCTAssertEqual(places.find("nothing"), [])
    }

    func testProjectFolderRoots() {
        let exists: (String) -> Bool = { ["/h/Source", "/h/src", "/work"].contains($0) }
        XCTAssertEqual(AssistantPlaces.roots(setting: "", home: "/h", exists: exists), ["/h/Source", "/h/src"])
        XCTAssertEqual(AssistantPlaces.roots(setting: "/work, ~/src\n/missing, relative", home: "/h", exists: exists), ["/work", "/h/src"])
    }

    func testStartInAProjectFolder() {
        let folders: (String) -> [String] = { name in
            switch name {
            case "cmds": return ["/h/Source/tools/cmds"]
            case "site": return ["/h/a/site", "/h/b/site", "/h/c/site", "/h/d/site"]
            default: return []
            }
        }
        guard case .propose(let action, let prompt) = plan("cmds のリポジトリで Claude Code を起動して、ログイン画面のテストを書かせて",
                                                           folders: folders) else { return XCTFail() }
        XCTAssertEqual(action.kind, .startAgent(.claude, directory: "/h/Source/tools/cmds", task: "ログイン画面のテストを書いてください"))
        XCTAssertEqual(action.text, "claude 'ログイン画面のテストを書いてください'")
        XCTAssertTrue(prompt.hasPrefix("Start Claude in /h/Source/tools/cmds with “ログイン画面のテストを書いてください”?"))
        XCTAssertEqual(plan("start claude in site", folders: folders), .askBack("Which folder: /h/a/site, /h/b/site, /h/c/site?"))
        XCTAssertEqual(plan("start claude in nothing", folders: folders),
                       .askBack("I don't know a workspace or folder called nothing. Which folder should I start it in?"))
        // The answer to "Which folder?" keeps the task.
        XCTAssertEqual(AssistantIntent.startAgent(.claude, place: nil, task: "Fix it.").retargeted("cmds"),
                       .startAgent(.claude, place: "cmds", task: "Fix it."))
    }

    // MARK: Command lines

    func testCommandLinesAreSafe() {
        XCTAssertEqual(AssistantLaunch.command(.claude, task: nil), "claude")
        XCTAssertEqual(AssistantLaunch.command(.codex, task: "Add tests."), "codex 'Add tests.'")
        XCTAssertEqual(AssistantLaunch.command(.claude, task: "it's $(rm -rf ~); `x` && echo \"hi\" | cat > /tmp/f \\ ${HOME}"),
                       #"claude 'it'\''s $(rm -rf ~); `x` && echo "hi" | cat > /tmp/f \ ${HOME}'"#)
        XCTAssertEqual(AssistantLaunch.command(.claude, task: "one\ntwo\r\tthree\u{7}"), "claude 'one two three'")
        XCTAssertEqual(AssistantLaunch.command(.claude, task: "--dangerously-skip-permissions fix"), "claude 'dangerously-skip-permissions fix'")
        XCTAssertEqual(AssistantLaunch.command(.claude, task: " \n "), "claude")
        XCTAssertEqual(AssistantLaunch.command(.claude, task: String(repeating: "a", count: 500)).count, "claude ''".count + AssistantLaunch.maxTask)
        XCTAssertEqual(AssistantLaunch.command(.claude, task: "hi", executable: "/tmp/my stub"), "'/tmp/my stub' 'hi'")
    }

    func testCommandLinesSurviveTheShell() throws {
        // What sh makes of the command line: the task arrives as one argument, exactly.
        let task = "it's $(echo pwned); `id` && \"q\" | > x \\ ${HOME} * ? ~ # ; 日本語"
        let line = AssistantLaunch.command(.claude, task: task, executable: "/usr/bin/printf").replacingOccurrences(of: "'/usr/bin/printf' ", with: "/usr/bin/printf '%s' ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", line]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), task)
    }

    func testTasksAsRequests() {
        XCTAssertEqual(AssistantLaunch.request("ログイン画面のテストを書かせて"), "ログイン画面のテストを書いてください")
        XCTAssertEqual(AssistantLaunch.request("このバグを直させて"), "このバグを直してください")
        XCTAssertEqual(AssistantLaunch.request("ビルドを実行させて"), "ビルドを実行してください")
        XCTAssertEqual(AssistantLaunch.request("READMEを読ませて"), "READMEを読んでください")
        XCTAssertEqual(AssistantLaunch.request("テストを作らせて"), "テストを作ってください")
        XCTAssertEqual(AssistantLaunch.request("原因を調べるように指示して"), "原因を調べてください")
        XCTAssertEqual(AssistantLaunch.request("テストを書いて"), nil)
        XCTAssertEqual(AssistantLaunch.request("テストを書いて", plainRequest: true), "テストを書いてください")
        XCTAssertEqual(AssistantLaunch.request("have it fix the failing tests"), "Fix the failing tests.")
        XCTAssertEqual(AssistantLaunch.request("and tell it to add docs."), "Add docs.")
        XCTAssertNil(AssistantLaunch.request("天気はどう"))
    }

    // MARK: Interpreter and the on-device model

    func testWhatGoesToTheInterpreter() {
        let w = world()
        for text in ["クロトコートを立ち上げて、 EPAの進捗情報を教えて", "EPAのテストどうなった", "launch something for me",
                     "エーピーアイのやつ見て"] {
            XCTAssertTrue(AssistantInterpretation.mightBeCommand(text, world: w), text)
        }
        for text in ["what is a monad", "明日の天気は", "モナドって何"] {
            XCTAssertFalse(AssistantInterpretation.mightBeCommand(text, world: w), text)
        }
        let prompt = AssistantClaude.interpreterPrompt(utterance: "EPAのテストどうなった", world: w, language: "Japanese")
        XCTAssertTrue(prompt.contains("- \"EPA\" is probably \"api\""))
        XCTAssertFalse(AssistantClaude.interpreterPrompt(utterance: "api", world: w, language: "Japanese").contains("misheard"))
    }

    func testInterpretedStart() {
        let w = world()
        XCTAssertEqual(AssistantInterpretation.parse(#"{"kind":"start","agent":"claude","targets":["cmds"],"text":"Write the login tests."}"#)?
            .intent(in: w), .startAgent(.claude, place: "cmds", task: "Write the login tests."))
        XCTAssertEqual(AssistantInterpretation(kind: .start, agent: "codex").intent(in: w), .startAgent(.codex, place: nil, task: nil))
    }

    func testOnDeviceApologiesAreNotSpoken() {
        XCTAssertTrue(AssistantModelReply.isAction("[[ACTION]]"))
        XCTAssertTrue(AssistantModelReply.isAction("[ACTION]"))
        XCTAssertTrue(AssistantModelReply.isAction("申し訳ありませんが、アプリの起動はできません。EPAの進捗は、経済連携協定のことですか"))
        XCTAssertTrue(AssistantModelReply.isAction("I'm sorry, but I can't start apps."))
        XCTAssertFalse(AssistantModelReply.isAction("A monad is a design pattern."))
        XCTAssertFalse(AssistantModelReply.isAction("東京の人口は約1400万人です。"))
        XCTAssertTrue(AssistantClaude.modelInstructions(language: "Japanese", web: false, actions: true).contains(AssistantModelReply.actionMarker))
        XCTAssertTrue(AssistantClaude.modelInstructions(language: "Japanese", web: true, actions: true).contains("Never apologise"))
        // Summaries never get it (a summary came back as "[START]").
        XCTAssertFalse(AssistantClaude.modelInstructions(language: "Japanese", web: false).contains(AssistantModelReply.actionMarker))
    }

    func testOnDeviceSummariesThatAreNoSummary() {
        XCTAssertTrue(AssistantModelReply.isSummary("Running the unit tests in api."))
        XCTAssertTrue(AssistantModelReply.isSummary("[WIP] running the tests."))
        XCTAssertTrue(AssistantModelReply.isSummary("テストを実行中。"))
        XCTAssertFalse(AssistantModelReply.isSummary(""))
        XCTAssertFalse(AssistantModelReply.isSummary("[START]"))
        XCTAssertFalse(AssistantModelReply.isSummary("[[ACTION]]"))
        XCTAssertFalse(AssistantModelReply.isSummary("申し訳ありませんが、操作はできません。"))
        // The prompt's example copied back is no summary.
        XCTAssertFalse(AssistantModelReply.isSummary("Running the tests."))
    }

    func testAWaitingSummaryForASessionThatDoesNotWaitIsMadeUp() {
        // The real case: a working agent with a quiet screen came back as the old prompt's "Waiting for input…".
        for made in ["Waiting for input: asks whether to continue.", "入力待ちです。", "続けるか確認を求めています。",
                     "It is asking you to approve the edit.", "The agent is waiting for feedback.", "指示を待っています。"] {
            XCTAssertFalse(AssistantModelReply.isSummary(made, waiting: false), made)
            XCTAssertTrue(AssistantModelReply.isSummary(made, waiting: true), made)
        }
        XCTAssertTrue(AssistantModelReply.isSummary("テストを書いています。", waiting: false))
        XCTAssertTrue(AssistantModelReply.isSummary("Fixing the login form.", waiting: false))
        XCTAssertTrue(AssistantModelReply.isSummary("Waiting for the build to finish.", waiting: false))
        XCTAssertFalse(AssistantClaude.summaryPrompt(facts: "f", screen: "s").contains("Waiting for input"))
    }

    func testOneLine() {
        XCTAssertEqual(AssistantText.oneLine("  Run\nthe tests?\r\n "), "Run the tests?")
        XCTAssertEqual(AssistantText.oneLine("api"), "api")
    }

    // MARK: Follow-through

    func testFollowThroughOnAStartedTask() {
        var watch = AssistantTaskWatch()
        watch.watch(paneID: "p9", workspaceID: "w9", agent: "Claude", current: .none, now: now)
        XCTAssertNil(watch.update(paneID: "p9", activity: .idle, question: nil, now: now))  // started, not worked yet
        XCTAssertNil(watch.update(paneID: "p9", activity: .busy, question: nil, now: now))
        XCTAssertEqual(watch.update(paneID: "p9", activity: .needsInput, question: "Run the tests?", now: now),
                       .needsInput(agent: "Claude", workspaceID: "w9", question: "Run the tests?"))
        XCTAssertNil(watch.update(paneID: "p9", activity: .needsInput, question: "Run the tests?", now: now))  // said once
        XCTAssertNil(watch.update(paneID: "p9", activity: .busy, question: nil, now: now))
        XCTAssertEqual(watch.update(paneID: "p9", activity: .idle, question: nil, now: now), .finished(agent: "Claude", workspaceID: "w9"))
        XCTAssertFalse(watch.isWatching(paneID: "p9"))
        XCTAssertNil(watch.update(paneID: "p9", activity: .busy, question: nil, now: now))
        // Other panes are never announced.
        XCTAssertNil(watch.update(paneID: "p1", activity: .idle, question: nil, now: now))
    }

    func testFollowThroughEnds() {
        var watch = AssistantTaskWatch()
        watch.watch(paneID: "a", workspaceID: "w", agent: "Claude", current: .idle, now: now)
        XCTAssertNil(watch.update(paneID: "a", activity: .busy, question: nil, now: now))
        XCTAssertNil(watch.update(paneID: "a", activity: .none, question: nil, now: now))  // exited
        XCTAssertFalse(watch.isWatching(paneID: "a"))
        watch.watch(paneID: "b", workspaceID: "w", agent: "Codex", current: .none, now: now)
        watch.expire(now: now.addingTimeInterval(AssistantTaskWatch.startGrace + 1))  // never started
        XCTAssertFalse(watch.isWatching(paneID: "b"))
        watch.watch(paneID: "c", workspaceID: "w", agent: "Claude", current: .busy, now: now)
        XCTAssertNil(watch.update(paneID: "c", activity: .busy, question: nil, now: now))
        watch.expire(now: now.addingTimeInterval(AssistantTaskWatch.lifetime + 1))
        XCTAssertFalse(watch.isWatching(paneID: "c"))
        for index in 0..<20 { watch.watch(paneID: "p\(index)", workspaceID: "w", agent: "Claude", current: .idle, now: now) }
        XCTAssertEqual(watch.entries.count, AssistantTaskWatch.maxEntries)
    }

    func testFollowThroughLines() {
        XCTAssertEqual(AssistantLine.taskDone(agent: "Claude", workspace: "api").english, "Claude in api is done.")
        XCTAssertEqual(AssistantLine.taskAsks(agent: "Claude", workspace: "api", question: "Run the tests?").english,
                       "Claude in api needs you: Run the tests?")
    }
}
