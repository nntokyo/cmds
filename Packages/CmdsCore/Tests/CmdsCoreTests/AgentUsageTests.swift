import XCTest
@testable import CmdsCore

final class AgentUsageCodableTests: XCTestCase {
    func testOldPaneJSONDecodesWithoutAgent() throws {
        let json = #"{"id":"p1","kind":"terminal","title":"zsh","focused":true,"attention":false}"#
        let pane = try JSONDecoder().decode(PaneInfo.self, from: Data(json.utf8))
        XCTAssertNil(pane.agent)
        let encoded = String(decoding: try JSONEncoder().encode(pane), as: UTF8.self)
        XCTAssertFalse(encoded.contains("agent"))
    }

    func testUsageRoundTripsWithEpochDates() throws {
        let reset = Date(timeIntervalSince1970: 1_793_258_595)
        let usage = AgentUsage(agent: .claude, model: "Opus", contextUsedPercent: 53, contextTokens: 527_000,
                               contextWindow: 1_000_000, costUSD: 117.99, sessionDurationMs: 12_300_000,
                               limits: [UsageLimit(id: UsageLimit.fiveHour, usedPercent: 40, resetsAt: reset)],
                               updatedAt: Date(timeIntervalSince1970: 1_793_250_000.5))
        let pane = PaneInfo(id: "p1", kind: .terminal, title: "claude", focused: true, attention: false, agent: usage)
        let value = try JSONValue.from(pane)
        XCTAssertEqual(value["agent"]?["limits"]?.arrayValue?.first?["resetsAt"], .number(1_793_258_595))
        XCTAssertEqual(value["agent"]?["limits"]?.arrayValue?.first?["windowMinutes"]?.intValue, 300)
        XCTAssertEqual(value["agent"]?["updatedAt"], .number(1_793_250_000.5))
        XCTAssertNil(value["agent"]?["stale"])
        XCTAssertEqual(try value.decode(PaneInfo.self), pane)
    }

    func testLenientDecoding() throws {
        let json = #"""
        {"agent":"gemini","contextUsedPercent":"12.5","costUSD":"x","linesAdded":3.0,
         "limits":[{"id":"five_hour","usedPercent":10,"resetsAt":"2026-10-29T10:00:00Z"},{"id":"broken"},
                   {"id":"seven_day","usedPercent":5,"resetsAt":1793258595000}]}
        """#
        let usage = try JSONDecoder().decode(AgentUsage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.agent, .other)
        XCTAssertEqual(usage.contextUsedPercent, 12.5)
        XCTAssertNil(usage.costUSD)
        XCTAssertEqual(usage.linesAdded, 3)
        XCTAssertEqual(usage.limits.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(usage.limits[0].resetsAt, ISO8601DateFormatter().date(from: "2026-10-29T10:00:00Z"))
        XCTAssertEqual(usage.limits[1].resetsAt, Date(timeIntervalSince1970: 1_793_258_595))
    }

    func testStateAndStatsCarryAgentLimitsOptionally() throws {
        let codec = SyncCodec()
        let limits = [AgentLimits(agent: .codex, limits: [UsageLimit(id: UsageLimit.fiveHour, usedPercent: 96)],
                                  plan: "plus", updatedAt: Date(timeIntervalSince1970: 1000))]
        let message = ServerMessage.state(.init(workspaces: [], agentLimits: limits))
        XCTAssertEqual(try codec.decodeServerMessage(codec.encode(message)), message)
        let old = #"{"type":"state","workspaces":[]}"#
        guard case .state(let state) = try codec.decodeServerMessage(Data(old.utf8)) else { return XCTFail() }
        XCTAssertNil(state.agentLimits)
        XCTAssertEqual(String(decoding: try codec.encode(.state(.init(workspaces: []))), as: UTF8.self),
                       #"{"type":"state","workspaces":[]}"#)
        let stats = StatsSnapshot(system: nil, workspaces: [], agentLimits: limits)
        XCTAssertEqual(try JSONValue.from(stats).decode(StatsSnapshot.self), stats)
    }

    func testActiveLimitsDropResetWindows() {
        let now = Date(timeIntervalSince1970: 10_000)
        let limits = AgentLimits(agent: .claude, limits: [
            UsageLimit(id: UsageLimit.sevenDay, usedPercent: 12, resetsAt: now.addingTimeInterval(100)),
            UsageLimit(id: UsageLimit.fiveHour, usedPercent: 40, resetsAt: now.addingTimeInterval(-1)),
        ])
        XCTAssertEqual(limits.active(at: now)?.limits.map(\.id), ["seven_day"])
        XCTAssertNil(AgentLimits(agent: .claude, limits: [limits.limits[1]]).active(at: now))
        XCTAssertEqual(AgentLimits(agent: .claude, limits: [
            UsageLimit(id: "spend", usedPercent: 1), UsageLimit(id: "seven_day", usedPercent: 1),
            UsageLimit(id: "five_hour", usedPercent: 1)]).ordered.map(\.id), ["five_hour", "seven_day", "spend"])
    }

    func testPrimaryAgentPrefersFocusedThenLatest() {
        let old = AgentUsage(agent: .claude, updatedAt: Date(timeIntervalSince1970: 1))
        let new = AgentUsage(agent: .codex, updatedAt: Date(timeIntervalSince1970: 2))
        var ws = WorkspaceInfo(id: "w", title: "t", selected: true, panes: [
            PaneInfo(id: "a", kind: .terminal, title: "", focused: false, attention: false, agent: old),
            PaneInfo(id: "b", kind: .terminal, title: "", focused: false, attention: false, agent: new),
            PaneInfo(id: "c", kind: .terminal, title: "", focused: true, attention: false),
        ])
        XCTAssertEqual(ws.primaryAgent?.pane.id, "b")
        ws.panes[0].focused = true
        XCTAssertEqual(ws.primaryAgent?.pane.id, "a")
    }
}

final class ClaudeStatusLineTests: XCTestCase {
    func testParsesFullStatusLineInput() throws {
        let json = #"""
        {"session_id":"abc","cwd":"/x","transcript_path":"/secret","model":{"id":"claude-opus","display_name":"Opus"},
         "effort":{"level":"high"},
         "context_window":{"context_window_size":1000000,"total_input_tokens":527000,"used_percentage":53.2},
         "exceeds_200k_tokens":true,
         "cost":{"total_cost_usd":117.99,"total_duration_ms":12300000,"total_api_duration_ms":13200000,
                 "total_lines_added":17642,"total_lines_removed":330},
         "prompt_cache":{"hit_ratio":0.98,"warm":true},
         "rate_limits":{"five_hour":{"used_percentage":40,"resets_at":1793258595},
                        "seven_day":{"used_percentage":12.4,"resets_at":"2026-11-02T00:00:00Z"},
                        "spend_limit":{"used_percentage":24,"used_usd":12,"limit_usd":50,"period":"monthly"}}}
        """#
        let now = Date(timeIntervalSince1970: 1_793_250_000)
        let usage = try XCTUnwrap(ClaudeStatusLine.usage(fromJSON: Data(json.utf8), now: now))
        XCTAssertEqual(usage.agent, .claude)
        XCTAssertEqual(usage.model, "Opus")
        XCTAssertEqual(usage.effort, "high")
        XCTAssertEqual(usage.contextTokens, 527_000)
        XCTAssertEqual(usage.contextOver200k, true)
        XCTAssertEqual(usage.sessionDurationMs, 12_300_000)
        XCTAssertEqual(usage.cacheHitRatio, 0.98)
        XCTAssertEqual(usage.limits.map(\.id), ["five_hour", "seven_day", "spend"])
        XCTAssertEqual(usage.limits[0].resetsAt, Date(timeIntervalSince1970: 1_793_258_595))
        XCTAssertNotNil(usage.limits[1].resetsAt)
        XCTAssertEqual(usage.limits[2].limitUSD, 50)
        XCTAssertEqual(usage.updatedAt, now)
        XCTAssertEqual(AgentFormat.statusLine(usage),
                       "ctx 53% 527k/1M >200k │ $117.99 ($34.53/h) │ ⏱ 3h25m api 3h40m(107%) │ +17642 -330 │ cache ●98%")
        XCTAssertEqual(AgentFormat.summary(usage), "Claude Opus · ctx 53% · $117.99 · 5h 40%")
        let encoded = String(decoding: try JSONEncoder().encode(usage), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret"))
    }

    func testDerivesTokensAndRejectsJunk() {
        let json = #"{"context_window":{"context_window_size":200000,"used_percentage":50}}"#
        XCTAssertEqual(ClaudeStatusLine.usage(fromJSON: Data(json.utf8))?.contextTokens, 100_000)
        XCTAssertNil(ClaudeStatusLine.usage(fromJSON: Data("not json".utf8)))
        XCTAssertNil(ClaudeStatusLine.usage(fromJSON: Data(#"{"foo":1}"#.utf8)))
        XCTAssertNil(ClaudeStatusLine.usage(fromJSON: Data("[1]".utf8)))
    }
}

final class CodexRolloutTests: XCTestCase {
    static let lines = [
        #"{"timestamp":"2026-10-29T05:39:13.961Z","type":"session_meta","payload":{"id":"01a1862b-6622-7b01-ace9-050fb70ff358","cwd":"/private/tmp/proj","base_instructions":"x"}}"#,
        #"{"timestamp":"2026-10-29T05:39:14.000Z","type":"turn_context","payload":{"cwd":"/tmp","model":"gpt-6.1-sol","effort":"low","summary":"auto"}}"#,
        #"{"timestamp":"2026-10-29T05:39:15.000Z","type":"response_item","payload":{"type":"message","content":[{"type":"input_text","text":"talk about \"token_count\" here"}]}}"#,
        #"{"timestamp":"2026-10-29T05:39:17.671Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":117006,"cached_input_tokens":80000,"output_tokens":487,"reasoning_output_tokens":83,"total_tokens":117493},"last_token_usage":{"input_tokens":28851,"cached_input_tokens":25856,"output_tokens":97,"reasoning_output_tokens":17,"total_tokens":28948},"model_context_window":475000},"rate_limits":{"limit_id":"codex","primary":{"used_percent":96.0,"window_minutes":300,"resets_at":1793258595},"secondary":{"used_percent":55.0,"window_minutes":10080,"resets_at":1793790157},"plan_type":"plus"}}}"#,
        #"{"timestamp":"2026-10-29T05:40:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"premium","primary":null,"secondary":null,"plan_type":null}}}"#,
    ]

    func testParsesUsageLimitsAndModel() throws {
        let data = Data((Self.lines.joined(separator: "\n") + "\n{\"partial").utf8)
        let (snapshot, consumed) = CodexRollout.parse(data)
        XCTAssertEqual(consumed, data.count - "{\"partial".utf8.count)
        XCTAssertEqual(snapshot.model, "gpt-6.1-sol")
        XCTAssertEqual(snapshot.effort, "low")
        XCTAssertEqual(snapshot.limits.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(snapshot.limits[0].usedPercent, 96)
        XCTAssertEqual(snapshot.plan, "plus")
        let usage = try XCTUnwrap(snapshot.usage(sessionID: "s", fallbackDate: Date()))
        XCTAssertEqual(usage.contextTokens, 28_931)
        XCTAssertEqual(usage.contextWindow, 475_000)
        // Codex: (28931-12000)/(475000-12000) = 3.66% used → "96% context left".
        XCTAssertEqual(usage.contextUsedPercent, 4)
        XCTAssertEqual(usage.inputTokens, 117_006)
        XCTAssertEqual(usage.updatedAt, try Date("2026-10-29T05:39:17.671Z", strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        XCTAssertEqual(snapshot.accountLimits(fallbackDate: Date())?.agent, .codex)
    }

    func testMergeKeepsOlderFiguresWhenNewerLackThem() {
        var base = CodexRollout.parse(Data((Self.lines.joined(separator: "\n") + "\n").utf8)).snapshot
        let newer = CodexRollout.parse(Data((Self.lines[4] + "\n").utf8)).snapshot
        XCTAssertFalse(newer.hasUsage)
        base.merge(newer)
        XCTAssertTrue(base.hasUsage)
        XCTAssertEqual(base.limits.count, 2)
        XCTAssertEqual(base.model, "gpt-6.1-sol")
    }

    func testSessionMetaAndPaths() {
        let meta = CodexRollout.sessionMeta(firstLine: Data(Self.lines[0].utf8))
        XCTAssertEqual(meta?.cwd, "/private/tmp/proj")
        XCTAssertNotNil(meta?.timestamp)
        XCTAssertNil(CodexRollout.sessionMeta(firstLine: Data(Self.lines[1].utf8)))
        let path = "/Users/me/.codex/sessions/2026/10/29/rollout-2026-10-29T14-39-13-01a1862b-6622-7b01-ace9-050fb70ff358.jsonl"
        XCTAssertTrue(CodexRollout.isRolloutPath(path))
        XCTAssertFalse(CodexRollout.isRolloutPath("/x/history.jsonl"))
        XCTAssertEqual(CodexRollout.sessionID(fromPath: path), "01a1862b-6622-7b01-ace9-050fb70ff358")
    }

    func testContextFormula() {
        XCTAssertEqual(CodexRollout.contextUsedPercent(tokens: 12_000, window: 112_000), 0)
        XCTAssertEqual(CodexRollout.contextUsedPercent(tokens: 62_000, window: 112_000), 50)
        XCTAssertEqual(CodexRollout.contextUsedPercent(tokens: 500_000, window: 112_000), 100)
    }
}

final class CodexSessionMatcherTests: XCTestCase {
    private func t(_ s: Double) -> Date { Date(timeIntervalSince1970: s) }
    private func file(_ path: String, cwd: String? = "/p", created: Double, modified: Double, usage: Bool = true) -> CodexSessionMatcher.File {
        .init(path: path, cwd: cwd, created: t(created), modified: t(modified), hasUsage: usage)
    }

    func testHeldFileWins() {
        let panes = [CodexSessionMatcher.Pane(paneID: "a", started: t(0), cwd: "/p", openFiles: ["f1"])]
        let result = CodexSessionMatcher.match(panes: panes, files: [file("f1", created: 1, modified: 2), file("f2", created: 5, modified: 9)])
        XCTAssertEqual(result, ["a": "f1"])
    }

    func testDaemonFilesByDirectoryAndTime() {
        let panes = [
            CodexSessionMatcher.Pane(paneID: "a", started: t(0), cwd: "/p"),
            CodexSessionMatcher.Pane(paneID: "b", started: t(10), cwd: "/tmp/p"),
            CodexSessionMatcher.Pane(paneID: "c", started: t(20), cwd: "/other"),
        ]
        let files = [
            file("fa", created: 5, modified: 30),
            file("fb", cwd: "/private/tmp/p", created: 12, modified: 25),
            file("old", created: -100, modified: -50),          // earlier session: nobody's
            file("empty", cwd: "/other", created: 21, modified: 22, usage: false),
        ]
        XCTAssertEqual(CodexSessionMatcher.match(panes: panes, files: files), ["a": "fa", "b": "fb"])
    }

    func testResumedSessionAndNewSession() {
        let panes = [CodexSessionMatcher.Pane(paneID: "a", started: t(100), cwd: "/p")]
        // Resumed: created long before the process, written after it started.
        XCTAssertEqual(CodexSessionMatcher.match(panes: panes, files: [file("r", created: 1, modified: 150)]), ["a": "r"])
        // /new: the newest file of the pane wins.
        XCTAssertEqual(CodexSessionMatcher.match(panes: panes, files: [file("r", created: 1, modified: 150),
                                                                       file("n", created: 160, modified: 170)]), ["a": "n"])
    }
}

final class AgentProcessTests: XCTestCase {
    func testClassifier() {
        XCTAssertEqual(AgentProcessClassifier.agent(executablePath: "/Users/me/.local/share/claude/versions/2.1.312",
                                                    arguments: ["claude"]), .claude)
        XCTAssertEqual(AgentProcessClassifier.agent(executablePath: "/opt/homebrew/bin/node",
                                                    arguments: ["node", "/opt/homebrew/bin/claude"]), .claude)
        XCTAssertEqual(AgentProcessClassifier.agent(executablePath: "/x/bin/codex", arguments: ["codex"]), .codex)
        XCTAssertEqual(AgentProcessClassifier.agent(executablePath: "/bin/sleep", arguments: ["codex", "100"]), .codex)
        XCTAssertNil(AgentProcessClassifier.agent(executablePath: "/bin/zsh", arguments: ["-zsh"]))
        XCTAssertEqual(AgentProcessClassifier.codexRole(arguments: ["codex"]), .session)
        XCTAssertEqual(AgentProcessClassifier.codexRole(arguments: ["codex", "-m", "o3", "fix login"]), .session)
        XCTAssertEqual(AgentProcessClassifier.codexRole(arguments: ["codex", "exec", "hi"]), .session)
        XCTAssertEqual(AgentProcessClassifier.codexRole(arguments: ["codex", "app-server", "--listen", "unix://"]), .service)
        XCTAssertEqual(AgentProcessClassifier.codexRole(arguments: ["node", "/x/codex.js", "app-server"]), .service)
        XCTAssertEqual(AgentProcessClassifier.codexRole(arguments: ["codex", "login"]), .utility)
    }

    func testProcArgsParser() {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(2)) { bytes += $0 }
        bytes += Array("/bin/codex".utf8) + [0, 0, 0]
        bytes += Array("codex".utf8) + [0] + Array("exec".utf8) + [0]
        bytes += Array("A=1".utf8) + [0] + Array("CMDS_PANE_ID=p7".utf8) + [0, 0]
        let parsed = bytes.withUnsafeBytes { ProcessArguments.parse($0, environmentNames: ["CMDS_PANE_ID"]) }
        XCTAssertEqual(parsed?.executable, "/bin/codex")
        XCTAssertEqual(parsed?.arguments, ["codex", "exec"])
        XCTAssertEqual(parsed?.environment, ["CMDS_PANE_ID": "p7"])
    }
}

final class AgentFormatTests: XCTestCase {
    func testNumbers() {
        XCTAssertEqual(AgentFormat.tokens(950), "950")
        XCTAssertEqual(AgentFormat.tokens(527_000), "527k")
        XCTAssertEqual(AgentFormat.tokens(999_600), "1M")
        XCTAssertEqual(AgentFormat.tokens(1_500_000), "1.5M")
        XCTAssertEqual(AgentFormat.duration(milliseconds: 42_000), "42s")
        XCTAssertEqual(AgentFormat.duration(milliseconds: 12_300_000), "3h25m")
        XCTAssertEqual(AgentFormat.duration(milliseconds: 97_200_000), "1d3h")
        XCTAssertEqual(AgentFormat.usd(0.4), "$0.40")
        XCTAssertEqual(AgentFormat.usd(1234.7), "$1235")
    }

    func testSummaryUsesAccountLimitsAndLevels() {
        let usage = AgentUsage(agent: .codex, model: "gpt-6.1-sol", contextUsedPercent: 85)
        let parts = AgentFormat.summaryParts(usage, limits: [UsageLimit(id: "seven_day", usedPercent: 55),
                                                              UsageLimit(id: "five_hour", usedPercent: 96)])
        XCTAssertEqual(parts.map(\.text).joined(), "Codex gpt-6.1-sol · ctx 85% · 5h 96%")
        XCTAssertEqual(parts.first { $0.text == "85%" }?.level, .warning)
        XCTAssertEqual(parts.last?.level, .critical)
        XCTAssertEqual(AgentFormat.name(AgentUsage(agent: .claude, model: "Claude Opus 4")), "Claude Opus 4")
        XCTAssertEqual(AgentFormat.limitsSummary([UsageLimit(id: "spend", usedPercent: 24, usedUSD: 12, limitUSD: 50),
                                                  UsageLimit(id: "five_hour", usedPercent: 40)]), "5h 40% · spend $12/$50")
    }

    func testResetTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_793_250_000) // 2026-10-29 05:00 UTC
        XCTAssertEqual(AgentFormat.resetTime(now.addingTimeInterval(7800), now: now, calendar: calendar), "07:10 (in 2h10m)")
        XCTAssertEqual(AgentFormat.resetTime(now.addingTimeInterval(3 * 86400), now: now, calendar: calendar), "Sun 05:00")
        XCTAssertEqual(AgentFormat.resetTime(now.addingTimeInterval(10 * 86400), now: now, calendar: calendar), "11/8 05:00")
    }
}
