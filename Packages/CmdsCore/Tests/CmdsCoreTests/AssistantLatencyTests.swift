import XCTest
@testable import CmdsCore

/// The assistant's stage times (#248).
final class AssistantTimelineTests: XCTestCase {
    func testStagesInMillisecondsFromHeard() {
        let start = Date(timeIntervalSince1970: 1000)
        var timeline = AssistantTimeline(request: 3, start: start)
        timeline.mark(.heard, at: start)
        timeline.mark(.speechEnd, at: start.addingTimeInterval(-0.6))
        timeline.mark(.routed, at: start.addingTimeInterval(0.004))
        timeline.mark(.claudeSpawn, at: start.addingTimeInterval(0.01))
        timeline.mark(.ack, at: start.addingTimeInterval(0.8))
        timeline.mark(.speechStart, at: start.addingTimeInterval(7.25))
        timeline.route = "web"
        XCTAssertEqual(timeline.milliseconds, ["heard": 0, "speechEnd": -600, "routed": 4, "claudeSpawn": 10, "ack": 800,
                                               "speechStart": 7250])
        XCTAssertEqual(timeline.firstSound, 800)
        XCTAssertEqual(timeline.summary, "web: speechEnd -600 heard 0 routed 4 claudeSpawn 10 ack 800 speechStart 7250 ms")
    }

    func testFirstMarkCountsExceptForTheEndOfACall() {
        let start = Date(timeIntervalSince1970: 0)
        var timeline = AssistantTimeline(request: 1, start: start)
        timeline.mark(.modelStart, at: start.addingTimeInterval(1))
        timeline.mark(.modelStart, at: start.addingTimeInterval(2))
        timeline.mark(.modelDone, at: start.addingTimeInterval(1.5))
        timeline.mark(.modelDone, at: start.addingTimeInterval(3))
        XCTAssertEqual(timeline.milliseconds["modelStart"], 1000)
        XCTAssertEqual(timeline.milliseconds["modelDone"], 3000)
        XCTAssertNil(timeline.firstSound)
        XCTAssertEqual(timeline.summary, "-: modelStart 1000 modelDone 3000 ms")
    }
}

/// The end of an utterance, from the microphone's level (#248).
final class AssistantEndpointTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testSpeechThenQuietFinalisesOnce() {
        var endpoint = AssistantEndpoint()
        XCTAssertFalse(endpoint.shouldFinalize(now: at(0)), "nothing said")
        for tick in stride(from: 0.0, through: 1.5, by: 0.05) { endpoint.loud(at: at(tick)) }
        XCTAssertFalse(endpoint.shouldFinalize(now: at(1.6)), "a pause shorter than quiet")
        XCTAssertFalse(endpoint.shouldFinalize(now: at(1.5 + AssistantEndpoint.quiet - 0.01)))
        XCTAssertTrue(endpoint.shouldFinalize(now: at(1.5 + AssistantEndpoint.quiet + 0.01)))
        XCTAssertFalse(endpoint.shouldFinalize(now: at(3)), "once per stretch of speech")
        XCTAssertNil(endpoint.speechStarted)
    }

    func testAPauseInsideASentenceKeepsItTogether() {
        var endpoint = AssistantEndpoint()
        endpoint.loud(at: at(0))
        endpoint.loud(at: at(1))
        XCTAssertFalse(endpoint.shouldFinalize(now: at(1.5)))
        endpoint.loud(at: at(1.6))
        XCTAssertFalse(endpoint.shouldFinalize(now: at(2.2)))
        XCTAssertTrue(endpoint.shouldFinalize(now: at(2.45)))
    }

    func testAClickIsNoSpeechAndIsForgotten() {
        var endpoint = AssistantEndpoint()
        endpoint.loud(at: at(0))
        endpoint.loud(at: at(0.1))
        XCTAssertFalse(endpoint.shouldFinalize(now: at(1)), "0.1 s of sound is no speech")
        XCTAssertNil(endpoint.speechStarted, "forgotten")
        endpoint.loud(at: at(5))
        XCTAssertFalse(endpoint.shouldFinalize(now: at(6)), "the click does not join later sound")
    }

    func testTheRecognisersOwnFinalStartsOver() {
        var endpoint = AssistantEndpoint()
        endpoint.loud(at: at(0))
        endpoint.loud(at: at(1))
        endpoint.finalized()
        XCTAssertFalse(endpoint.shouldFinalize(now: at(3)))
    }

    func testANoisyRoomNeverFinalisesEarly() {
        var endpoint = AssistantEndpoint()
        for tick in stride(from: 0.0, through: 30, by: 0.05) {
            endpoint.loud(at: at(tick))
            XCTAssertFalse(endpoint.shouldFinalize(now: at(tick)))
        }
    }
}

/// `claude -p` stream-json read as it comes, and the answer's sentences as they are written (#248).
final class AssistantClaudeStreamTests: XCTestCase {
    private func delta(_ text: String) -> String {
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}},"parent_tool_use_id":null}"#
    }

    func testEvents() {
        XCTAssertEqual(AssistantClaudeStream.events(inLine: delta("明日は")), [.text("明日は")])
        XCTAssertEqual(AssistantClaudeStream.events(inLine: #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","name":"WebSearch"}},"parent_tool_use_id":null}"#),
                       [.toolUse])
        XCTAssertEqual(AssistantClaudeStream.events(inLine: #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#), [])
        XCTAssertEqual(AssistantClaudeStream.events(inLine: #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}}"#), [])
        XCTAssertEqual(AssistantClaudeStream.events(inLine: #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn"}}}"#),
                       [.turnEnded("end_turn")])
        XCTAssertEqual(AssistantClaudeStream.events(inLine: #"{"duration_api_ms":1039,"type":"result","subtype":"success","is_error":false,"result":"Answer."}"#),
                       [.result("Answer.", isError: false)])
        XCTAssertEqual(AssistantClaudeStream.events(inLine: #"{"type":"result","subtype":"error_max_turns","is_error":true}"#),
                       [.result(nil, isError: true)])
        // A subagent's text, other lines and junk are nothing.
        XCTAssertEqual(AssistantClaudeStream.events(inLine: delta("x").replacingOccurrences(of: #""parent_tool_use_id":null"#, with: #""parent_tool_use_id":"toolu_1""#)), [])
        XCTAssertEqual(AssistantClaudeStream.events(inLine: #"{"type":"system","subtype":"init"}"#), [])
        XCTAssertEqual(AssistantClaudeStream.events(inLine: "not json"), [])
    }

    func testLinesAcrossChunks() {
        var lines = AssistantClaudeStream.Lines()
        XCTAssertEqual(lines.append(Data(#"{"type":"res"#.utf8)), [])
        XCTAssertEqual(lines.append(Data("ult\"}\n{\"a\":1}\n{\"b\"".utf8)), [#"{"type":"result"}"#, #"{"a":1}"#])
        // A character split between chunks is whole in its line.
        let japanese = Array("晴れ\n".utf8)
        XCTAssertEqual(lines.append(Data(":2}\n".utf8) + Data(japanese.prefix(2))), [#"{"b":2}"#])
        XCTAssertEqual(lines.append(Data(japanese.dropFirst(2))), ["晴れ"])
        XCTAssertEqual(lines.append(Data("\n".utf8)), [""])
    }

    func testOnlyACallWithoutToolsStreamsSentences() {
        XCTAssertTrue(AssistantClaude.streamsSentences(AssistantClaude.detailedSummaryArguments(facts: "api", language: "English")))
        XCTAssertFalse(AssistantClaude.streamsSentences(AssistantClaude.webArguments(question: "weather", language: "English")))
    }

    func testSentencesAsTheyAreWritten() {
        var stream = AssistantSpokenStream(streaming: true)
        XCTAssertEqual(stream.take(.text("エージェントはテストを")), [])
        XCTAssertEqual(stream.take(.text("実行中です。失敗が")), ["エージェントはテストを実行中です。"])
        XCTAssertEqual(stream.take(.text("1件あります。")), [], "the last one may go on (「。」」, 19.5)")
        XCTAssertEqual(stream.take(.text("確認が必要")), ["失敗が1件あります。"])
        XCTAssertEqual(stream.take(.turnEnded("end_turn")), ["確認が必要"])
        XCTAssertEqual(stream.take(.result("…", isError: false)), [])
    }

    func testANumberIsNoSentenceEndAndALineBreakIs() {
        var stream = AssistantSpokenStream(streaming: true)
        XCTAssertEqual(stream.take(.text("High 19.")), [])
        XCTAssertEqual(stream.take(.text("5 degrees. Low")), ["High 19.5 degrees."])
        var lines = AssistantSpokenStream(streaming: true)
        XCTAssertEqual(lines.take(.text("Tests pass.\n")), ["Tests pass."])
    }

    func testSourcesLinksAndMarkdownAreNotSpoken() {
        var stream = AssistantSpokenStream(streaming: true)
        XCTAssertEqual(stream.take(.text("**明日の東京**は晴れです。\nSou")), ["明日の東京は晴れです。"])
        XCTAssertEqual(stream.take(.text("rces:\n- https://tenki.jp/x\n")), [])
        XCTAssertEqual(stream.take(.turnEnded("end_turn")), [])
    }

    func testWithToolsNothingBeforeTheLastTurnAndAPreambleIsDropped() {
        var stream = AssistantSpokenStream(streaming: false)
        XCTAssertEqual(stream.take(.text("I'll search for that. One moment.")), [])
        XCTAssertEqual(stream.take(.toolUse), [])
        XCTAssertEqual(stream.take(.turnEnded("tool_use")), [])
        XCTAssertEqual(stream.take(.text("Tomorrow in Tokyo: sunny, high 20, low 9.\nSources:")), [])
        XCTAssertEqual(stream.take(.turnEnded("end_turn")), ["Tomorrow in Tokyo: sunny, high 20, low 9."])
        var streaming = AssistantSpokenStream(streaming: true)
        XCTAssertEqual(streaming.take(.text("Let me check. ")), [])
        XCTAssertEqual(streaming.take(.turnEnded("tool_use")), [], "a turn that goes on with a tool says nothing")
        XCTAssertEqual(streaming.take(.text("Done. ")), [])
        XCTAssertEqual(streaming.take(.turnEnded("end_turn")), ["Done."])
    }
}

/// Which way a free question goes (#248).
final class AssistantRouteTests: XCTestCase {
    private let world = AssistantWorld(workspaces: [.init(id: "w1", title: "api", state: .working, agent: "Claude"),
                                                    .init(id: "w2", title: "web", state: .needsUser, agent: "Codex")])

    private func route(_ question: String, web: Bool = true, interpreter: Bool = true) -> AssistantRoute {
        AssistantRoute.decide(question, world: world, web: web, interpreter: interpreter)
    }

    func testNoCommandAsBefore() {
        XCTAssertEqual(route("明日の東京の天気は？"), .web)
        XCTAssertEqual(route("明日の東京の天気は？", web: false), .model)
        XCTAssertEqual(route("ユニットテストって何？"), .model)
        XCTAssertEqual(route("what's the weather in Tokyo tomorrow"), .web)
    }

    func testARequestGoesToTheInterpreterFirst() {
        XCTAssertEqual(route("apiのエージェントにREADMEも更新してもらって"), .interpreter)
        XCTAssertEqual(route("ask claude what the weather is tomorrow"), .interpreter)
        XCTAssertEqual(route("tell the api agent to fix the failing test"), .interpreter)
        XCTAssertEqual(route("クロードを起動して"), .interpreter)
    }

    func testALiveQuestionNamingNoWorkspaceSkipsTheInterpreter() {
        XCTAssertEqual(route("Claude Codeの最新バージョンは？"), .web)
        XCTAssertEqual(route("what's the latest version of Claude Code"), .web)
        XCTAssertEqual(route("Claude Codeの最新バージョンは？", web: false), .interpreterAndModel)
    }

    func testAQuestionAboutSessionsAsksBothAtOnce() {
        XCTAssertEqual(route("全部のセッションってどんな感じ？"), .interpreterAndModel)
        XCTAssertEqual(route("how are the sessions"), .interpreterAndModel)
        XCTAssertEqual(route("apiの最新のニュースは？"), .interpreterAndModel, "names a workspace")
    }

    func testInterpreterOff() {
        XCTAssertEqual(route("apiのエージェントにREADMEも更新してもらって", interpreter: false), .model)
        XCTAssertEqual(route("Claude Codeの最新バージョンは？", interpreter: false), .web)
    }
}

/// The acknowledgement of a slow answer and the web answers kept for a while (#248).
final class AssistantAckAndCacheTests: XCTestCase {
    func testAcknowledgementOnlyForASlowAnswerNotYetGiven() {
        XCTAssertTrue(AssistantAck.due(slow: true, elapsed: 0.8, thinking: true, said: false, voiceActive: false))
        XCTAssertFalse(AssistantAck.due(slow: true, elapsed: 0.5, thinking: true, said: false, voiceActive: false), "too early")
        XCTAssertFalse(AssistantAck.due(slow: false, elapsed: 2, thinking: true, said: false, voiceActive: false), "a fast path")
        XCTAssertFalse(AssistantAck.due(slow: true, elapsed: 2, thinking: false, said: false, voiceActive: false), "answered or moved on")
        XCTAssertFalse(AssistantAck.due(slow: true, elapsed: 2, thinking: true, said: true, voiceActive: false), "once")
        XCTAssertFalse(AssistantAck.due(slow: true, elapsed: 2, thinking: true, said: false, voiceActive: true), "never over its voice")
        XCTAssertEqual(AssistantLine.checking.english, "Checking.")
    }

    func testCacheKeepsAnAnswerForTenMinutesOfTheSameDay() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 17:00 in Tokyo
        var cache = AssistantWebCache()
        cache.store("明日の東京は晴れです。", for: "明日の東京の天気は？", language: "Japanese", now: now, timeZone: tokyo)
        XCTAssertEqual(cache.answer("明日の東京の天気は", language: "Japanese", now: now.addingTimeInterval(60), timeZone: tokyo),
                       "明日の東京は晴れです。", "the same words, folded")
        XCTAssertNil(cache.answer("明日の大阪の天気は？", language: "Japanese", now: now, timeZone: tokyo))
        XCTAssertNil(cache.answer("明日の東京の天気は？", language: "English", now: now, timeZone: tokyo))
        XCTAssertNil(cache.answer("明日の東京の天気は？", language: "Japanese", now: now.addingTimeInterval(AssistantWebCache.lifetime), timeZone: tokyo))
        // Just before midnight: "tomorrow" means another day after it.
        let late = Date(timeIntervalSince1970: 1_800_025_000) // 23:56:40
        cache.store("明日は雨です。", for: "明日の天気は？", language: "Japanese", now: late, timeZone: tokyo)
        XCTAssertEqual(cache.answer("明日の天気は？", language: "Japanese", now: late.addingTimeInterval(150), timeZone: tokyo), "明日は雨です。")
        XCTAssertNil(cache.answer("明日の天気は？", language: "Japanese", now: late.addingTimeInterval(300), timeZone: tokyo))
    }

    func testCacheIsBounded() {
        var cache = AssistantWebCache()
        let now = Date()
        for index in 0..<(AssistantWebCache.capacity + 5) {
            cache.store("answer \(index)", for: "question \(index)", language: "English", now: now)
        }
        XCTAssertNil(cache.answer("question 0", language: "English", now: now))
        XCTAssertEqual(cache.answer("question \(AssistantWebCache.capacity + 4)", language: "English", now: now), "answer \(AssistantWebCache.capacity + 4)")
        cache.store("", for: "empty", language: "English", now: now)
        XCTAssertNil(cache.answer("empty", language: "English", now: now))
    }
}

/// An answer spoken in parts while it is written (#248).
final class AssistantUtterancePartsTests: XCTestCase {
    func testAnOpenUtteranceEndsAfterCloseAndItsLastPart() {
        var utterances = AssistantUtterances<String>()
        let number = utterances.start("answer", open: true)
        XCTAssertNil(utterances.ended(number), "the first sentence was said; more to come")
        XCTAssertEqual(utterances.add(), number)
        XCTAssertEqual(utterances.add(), number)
        XCTAssertNil(utterances.ended(number))
        XCTAssertNil(utterances.close(), "one part is still being said")
        XCTAssertEqual(utterances.ended(number), "answer")
        XCTAssertNil(utterances.current)
    }

    func testClosingWhenAllWasSaidEndsAtOnce() {
        var utterances = AssistantUtterances<String>()
        let number = utterances.start("answer", open: true)
        XCTAssertNil(utterances.ended(number))
        XCTAssertEqual(utterances.close(), "answer")
        XCTAssertNil(utterances.close())
    }

    func testAQueuedAnswerReplacesTheAcknowledgement() {
        var utterances = AssistantUtterances<String>()
        let ack = utterances.start("ack")
        let answer = utterances.start("answer")
        XCTAssertNil(utterances.ended(ack), "the acknowledgement's end is not the answer's")
        XCTAssertEqual(utterances.ended(answer), "answer")
        XCTAssertNil(utterances.add(), "nothing to add to")
    }

    func testMachineTakesMoreOfTheAnswerOnlyWhileSpeakingIt() {
        var machine = AssistantMachine()
        machine.turnOn()
        let now = Date()
        guard case .handle = machine.hear("Jarvis, api in detail", names: AssistantAddressing.defaultNames, now: now) else {
            return XCTFail("not handled")
        }
        let request = machine.request
        XCTAssertFalse(machine.extendAnswer("x", request: request), "nothing said yet")
        XCTAssertTrue(machine.answer("First.", request: request, now: now))
        XCTAssertTrue(machine.extendAnswer("First. Second.", request: request))
        XCTAssertEqual(machine.answer, "First. Second.")
        XCTAssertFalse(machine.extendAnswer("First. Second. Third.", request: request + 1))
        machine.speechFinished(now: now)
        XCTAssertFalse(machine.extendAnswer("First. Second. Third.", request: request))
    }
}
