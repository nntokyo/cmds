import CmdsCore
import Foundation
import UIKit

/// In-process fake Mac for previews and `-mock` launches. Speaks the real protocol (including
/// `ScreenStreamer` diffs) so the client code path is the same as with a real Mac.
///
/// Like a current Mac it streams the rows that scroll off a screen (`SyncFeature.scrollbackStream`); launched with
/// `-mockNoHistoryStream` it answers like cmds 0.3.0 (`requestScrollback` only). `-mockStreamOutput` makes the dotfiles
/// pane print a numbered line five times a second into a full scrollback (`TerminalScreenTests`).
final class MockTransport: SyncTransport {
    var onEvent: ((TransportEvent) -> Void)?

    private var timer: Timer?
    private var outputTimer: Timer?
    private var streamer = ScreenStreamer()
    private var subscribed: Set<String> = []
    private var workspaces: [WorkspaceInfo]
    private var shells: [String: FakeShell]
    private var tick = 0
    private var closed = false
    private var system: SystemStats?
    private var agentLimits: [AgentLimits] = []
    /// `-mockAccounts`: the agent pane runs under the Claude account "work", which is at a limit (#112).
    private var accountLimits: [ServerMessage.State.AccountLimit] = []
    private let startedAt = Date()
    /// This demo Mac streams scrolled-off rows (not with `-mockNoHistoryStream`), and the phone asked for them.
    private let streamsHistory = !ProcessInfo.processInfo.arguments.contains("-mockNoHistoryStream")
    private var phoneStreamsHistory = false
    /// The phone listed `SyncFeature.styles`: its screens come with colours (`MockStyles`), like from a current Mac.
    private var phoneDrawsStyles = false
    /// Panes whose `requestScrollback` was answered: their shell's `historyEpoch`, and its `scrolledCount` when the
    /// last screen update was sent.
    private var historyStreams: [String: (epoch: Int, scrolled: Int)] = [:]
    private static let streamOutputInterval: TimeInterval = 0.2

    init() {
        workspaces = MockData.workspaces
        shells = MockData.shells()
        updateUsage()
    }

    private var currentState: ServerMessage.State {
        .init(workspaces: workspaces, system: system, agentLimits: agentLimits,
              accountLimits: accountLimits.isEmpty ? nil : accountLimits)
    }

    func start() {
        deliver(after: 0.15, .connected)
    }

    func send(_ message: ClientMessage) {
        guard !closed else { return }
        switch message {
        case .hello(let hello):
            phoneStreamsHistory = streamsHistory && hello.features?.contains(SyncFeature.scrollbackStream) == true
            phoneDrawsStyles = hello.features?.contains(SyncFeature.styles) == true
            let features = [SyncFeature.scrollback, SyncFeature.styles]
                + (streamsHistory ? [SyncFeature.scrollbackStream] : [])
            deliver(after: 0.1, .message(.welcome(.init(macName: "Demo Mac", token: "mock-token", features: features))))
            deliver(after: 0.1, .message(.state(currentState)))
            DispatchQueue.main.async { self.startTimer() }
        case .subscribe(let sub):
            let new = Set(sub.paneIDs)
            for paneID in new.subtracting(subscribed) { streamer.reset(paneID: paneID) }
            subscribed = new
            streamer.retain(paneIDs: new)
            historyStreams = historyStreams.filter { new.contains($0.key) }
            pushScreens()
        case .requestScreen(let req):
            if let msg = streamer.fullScreen(paneID: req.paneID) { emit(msg) }
        case .input(let input):
            shells[input.paneID]?.type(input.text)
            clearAttention(paneID: input.paneID)
            pushScreens()
        case .key(let key):
            shells[key.paneID]?.press(key.key)
            clearAttention(paneID: key.paneID)
            pushScreens()
        case .selectWorkspace(let sel):
            for i in workspaces.indices { workspaces[i].selected = workspaces[i].id == sel.id }
            emit(.state(currentState))
        case .focusPane(let focus):
            for w in workspaces.indices {
                for p in workspaces[w].panes.indices {
                    workspaces[w].panes[p].focused = workspaces[w].panes[p].id == focus.id
                }
            }
            emit(.state(currentState))
        case .ping(let ping):
            deliver(after: 0.02, .message(.pong(.init(nonce: ping.nonce))))
        case .requestFile(let request):
            guard request.paneID == "p-chart" else {
                return emit(.error(.init(code: .badRequest, message: "pane \(request.paneID) is not a preview pane")))
            }
            for piece in SyncFile.messages(paneID: request.paneID, name: "chart.png", mime: "image/png", data: MockData.chartPNG()) {
                deliver(after: 0.2, .message(.file(piece)))
            }
        case .requestScrollback(let request):
            // Like the Mac: a full screen, then the rows above it with the same seq.
            guard subscribed.contains(request.paneID), let shell = shells[request.paneID] else {
                return emit(.error(.init(code: .badRequest, message: "pane \(request.paneID) is not streamed")))
            }
            pushScreens()
            guard case .screen(let screen)? = streamer.fullScreen(paneID: request.paneID) else { return }
            emit(.screen(screen))
            let rows = MockData.history(paneID: request.paneID) + shell.scrolledOff
            emit(.scrollback(.init(paneID: request.paneID, seq: screen.seq,
                                   lines: Array(rows.suffix(SyncScrollback.clampedLines(request.lines))))))
            // From here on, like the Mac: the rows that scroll off go with the screen updates.
            if phoneStreamsHistory {
                historyStreams[request.paneID] = (shell.historyEpoch, shell.scrolledCount)
            }
        }
    }

    func close() {
        closed = true
        timer?.invalidate()
        timer = nil
        outputTimer?.invalidate()
        outputTimer = nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.step() }
        guard ProcessInfo.processInfo.arguments.contains("-mockStreamOutput") else { return }
        outputTimer?.invalidate()
        outputTimer = Timer.scheduledTimer(withTimeInterval: Self.streamOutputInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.shells[MockData.streamOutputPaneID]?.printNumberedLine()
            self.pushScreens()
        }
    }

    private func step() {
        tick += 1
        shells["p-top"]?.renderTop(tick: tick)
        if tick % 2 == 0 { shells["p-build"]?.appendBuildLine(tick: tick) }
        pushScreens()
        if tick % 2 == 0 {
            // Like the Mac: a usage sample every ~2 s.
            updateUsage()
            emit(.state(currentState))
        }
        if tick == 6 || tick % 45 == 0 {
            if let w = workspaces.firstIndex(where: { $0.id == "w-api" }),
               let p = workspaces[w].panes.firstIndex(where: { $0.id == "p-agent" }) {
                workspaces[w].attention = true
                workspaces[w].panes[p].attention = true
                workspaces[w].notificationText = "Claude is waiting for your input"
                emit(.state(currentState))
            }
            emit(.notification(.init(paneID: "p-agent", workspaceID: "w-api", title: "Claude Code",
                                     body: "Claude is waiting for your input")))
        }
    }

    /// Plausible, slowly drifting CPU/memory figures: a build in `cmds` (sometimes above one core), an idle-ish
    /// API server, a quiet dotfiles shell; the Mac reports memory pressure "warning" for a while every 2 minutes.
    private func updateUsage() {
        let t = Double(tick)
        let gib = 1024.0 * 1024 * 1024
        func tenth(_ value: Double) -> Double { (value * 10).rounded() / 10 }
        for i in workspaces.indices {
            switch workspaces[i].id {
            case "w-cmds":
                workspaces[i].cpuPercent = tenth(82 + 38 * sin(t / 3))
                workspaces[i].memoryBytes = UInt64((2.1 + 0.15 * sin(t / 7)) * gib)
            case "w-api":
                workspaces[i].cpuPercent = tenth(6 + 4 * sin(t / 2 + 1))
                workspaces[i].memoryBytes = UInt64((0.83 + 0.03 * sin(t / 5)) * gib)
            default:
                workspaces[i].cpuPercent = tenth(0.3 + 0.2 * sin(t))
                workspaces[i].memoryBytes = UInt64(46 * 1024 * 1024)
            }
        }
        let warning = (tick / 30) % 4 == 3
        system = SystemStats(cpuPercent: tenth(31 + 17 * sin(t / 4)),
                             memoryUsedBytes: UInt64((warning ? 13.6 : 11.2 + 0.4 * sin(t / 9)) * gib),
                             memoryTotalBytes: UInt64(16 * gib), memoryPressure: warning ? 2 : 1)
        updateAgents()
    }

    /// Claude Code in the API workspace (cost and context creeping up) and Codex in dotfiles, plus account limits:
    /// Claude comfortable, Codex's 5-hour window nearly used up.
    private func updateAgents() {
        let t = Double(tick)
        let now = Date()
        let claudeLimits = [
            UsageLimit(id: UsageLimit.fiveHour, usedPercent: (40 + t / 30).rounded(), resetsAt: startedAt.addingTimeInterval(2 * 3600 + 600)),
            UsageLimit(id: UsageLimit.sevenDay, usedPercent: 12, resetsAt: startedAt.addingTimeInterval(3 * 86400)),
            UsageLimit(id: UsageLimit.spend, usedPercent: 24, usedUSD: 12, limitUSD: 50, period: "monthly"),
        ]
        let codexLimits = [
            UsageLimit(id: UsageLimit.fiveHour, usedPercent: 96, resetsAt: startedAt.addingTimeInterval(3900)),
            UsageLimit(id: UsageLimit.sevenDay, usedPercent: 55, resetsAt: startedAt.addingTimeInterval(4 * 86400)),
        ]
        let claude = AgentUsage(agent: .claude, model: "Opus 4.5", effort: "high",
                                contextUsedPercent: min(99, (53 + t / 20).rounded()), contextTokens: 527_000 + tick * 500,
                                contextWindow: 1_000_000, contextOver200k: true, costUSD: 117.99 + t * 0.02,
                                sessionDurationMs: 12_300_000 + tick * 1000, apiDurationMs: 13_200_000,
                                linesAdded: 17_642 + tick / 3, linesRemoved: 330, cacheHitRatio: 0.98, cacheWarm: true,
                                limits: claudeLimits, updatedAt: now)
        let codex = AgentUsage(agent: .codex, model: "gpt-5-codex", effort: "medium", contextUsedPercent: 31,
                               contextTokens: 151_000, contextWindow: 475_000, inputTokens: 600_000,
                               cachedInputTokens: 450_000, outputTokens: 12_400, limits: codexLimits, plan: "plus",
                               updatedAt: now)
        for w in workspaces.indices {
            for p in workspaces[w].panes.indices {
                switch workspaces[w].panes[p].id {
                case "p-agent": workspaces[w].panes[p].agent = claude
                case "p-dot": workspaces[w].panes[p].agent = codex
                default: break
                }
            }
        }
        agentLimits = [AgentLimits(agent: .claude, limits: claudeLimits, updatedAt: now),
                       AgentLimits(agent: .codex, limits: codexLimits, plan: "plus", updatedAt: now)]
        if ProcessInfo.processInfo.arguments.contains("-mockAccounts") {
            for w in workspaces.indices {
                for p in workspaces[w].panes.indices where workspaces[w].panes[p].id == "p-agent" {
                    workspaces[w].panes[p].account = "work"
                }
            }
            accountLimits = [.init(name: "work", resetsAt: now.addingTimeInterval(2 * 3600 + 600))]
        }
    }

    private func clearAttention(paneID: String) {
        var changed = false
        for w in workspaces.indices {
            for p in workspaces[w].panes.indices where workspaces[w].panes[p].id == paneID && workspaces[w].panes[p].attention {
                workspaces[w].panes[p].attention = false
                workspaces[w].attention = workspaces[w].panes.contains(where: \.attention)
                changed = true
            }
        }
        if changed { emit(.state(currentState)) }
    }

    private func pushScreens() {
        for paneID in subscribed.sorted() {
            guard let shell = shells[paneID] else { continue }
            let snapshot = phoneDrawsStyles ? MockStyles.styled(shell.snapshot) : shell.snapshot
            guard let msg = streamer.update(paneID: paneID, snapshot: snapshot) else { continue }
            emit(withScrolledOffRows(msg, paneID: paneID, shell: shell))
        }
    }

    /// Like the Mac: a streamed pane's update carries the rows that left the top of its screen since the previous
    /// update, or `historyReset` when they do not continue the rows sent (cleared, a page of old rows dropped, or more
    /// rows than the shell kept); then the phone asks again.
    private func withScrolledOffRows(_ msg: ServerMessage, paneID: String, shell: FakeShell) -> ServerMessage {
        guard let stream = historyStreams[paneID] else { return msg }
        let new = shell.scrolledCount - stream.scrolled
        guard shell.historyEpoch == stream.epoch, new >= 0, new <= shell.scrolledOff.count else {
            historyStreams[paneID] = nil
            return msg.withHistory(scrolledOff: nil, reset: true)
        }
        historyStreams[paneID]?.scrolled = shell.scrolledCount
        return new > 0 ? msg.withHistory(scrolledOff: Array(shell.scrolledOff.suffix(new)), reset: false) : msg
    }

    /// Round-trip through the codec so the mock exercises encoding too.
    private func emit(_ message: ServerMessage) {
        let codec = SyncCodec()
        guard let data = try? codec.encode(message), let decoded = try? codec.decodeServerMessage(data) else { return }
        deliver(after: 0.01, .message(decoded))
    }

    private func deliver(after delay: TimeInterval, _ event: TransportEvent) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.closed else { return }
            self.onEvent?(event)
        }
    }
}

/// A tiny line-based shell imitation for the mock.
struct FakeShell {
    var rows: Int
    var cols: Int
    var lines: [String]
    var prompt: String
    var current = ""
    var ctrlHistory: [String] = []
    /// Fixed screen (a full-screen TUI), ignoring `lines`/`prompt`.
    var fixed: ScreenSnapshot?
    /// Lines dropped from the front of `lines` to keep it short.
    var droppedLines = 0
    /// Bumped when the rows above the screen no longer continue the ones sent before (cleared, `prunedPages`).
    var historyEpoch = 0
    /// Next number of `printNumberedLine`.
    var nextNumber = 1
    /// A full scrollback that resets the stream whenever it drops a page of its oldest rows (more often than a Mac,
    /// which follows the pruning and resets only once the phone's last rows are pruned too, so that the phone's
    /// handling of `historyReset` gets exercised): `printNumberedLine` keeps at most `limit` lines, drops `page` of
    /// them at a time and bumps `historyEpoch`.
    var prunedPages: (limit: Int, page: Int)?

    init(rows: Int = 24, cols: Int = 80, prompt: String, lines: [String] = []) {
        self.rows = rows
        self.cols = cols
        self.prompt = prompt
        self.lines = lines
    }

    /// Rows that scrolled off the top of `snapshot`, oldest first.
    var scrolledOff: [String] {
        guard fixed == nil else { return [] }
        return (lines + [prompt + current]).dropLast(rows).map { String($0.prefix(cols)) }
    }

    /// Rows that have left the top of the screen in this `historyEpoch`, including the dropped ones.
    var scrolledCount: Int {
        fixed == nil ? droppedLines + max(0, lines.count + 1 - rows) : 0
    }

    /// Like `seq`: the next numbered output line.
    mutating func printNumberedLine() {
        appendOutput(String(format: "line %05d", nextNumber), keepingAtMost: 5000)
        nextNumber += 1
        if let prunedPages, lines.count > prunedPages.limit {
            lines.removeFirst(prunedPages.page)
            droppedLines += prunedPages.page
            historyEpoch += 1
        }
    }

    private mutating func appendOutput(_ line: String, keepingAtMost limit: Int) {
        lines.append(line)
        if lines.count > limit {
            droppedLines += lines.count - limit
            lines.removeFirst(lines.count - limit)
        }
    }

    private mutating func clearLines() {
        lines = []
        droppedLines = 0
        historyEpoch += 1
    }

    var snapshot: ScreenSnapshot {
        if let fixed { return fixed }
        var visible = lines + [prompt + current]
        if visible.count > rows { visible = Array(visible.suffix(rows)) }
        let cursorRow = visible.count - 1
        while visible.count < rows { visible.append("") }
        let cursorCol = min(cols - 1, TerminalCells.width(of: prompt + current))  // cells, as the Mac sends it
        return ScreenSnapshot(rows: rows, cols: cols, lines: visible.map { String($0.prefix(cols)) },
                              cursorRow: cursorRow, cursorCol: cursorCol)
    }

    mutating func type(_ text: String) {
        for ch in text {
            if ch == "\n" || ch == "\r" { press(.enter) } else { current.append(ch) }
        }
    }

    mutating func press(_ key: SyncKey) {
        switch key {
        case .enter: run()
        case .backspace: if !current.isEmpty { current.removeLast() }
        case .ctrlC:
            lines.append(prompt + current + "^C")
            current = ""
        case .ctrlL: clearLines()
        case .tab: current += "  "
        default: break
        }
    }

    private mutating func run() {
        let cmd = current.trimmingCharacters(in: .whitespaces)
        lines.append(prompt + current)
        current = ""
        switch cmd {
        case "": break
        case "ls": lines += ["App  docs  iOS  LICENSE  Packages  project.yml  README.md  vendor"]
        case "pwd": lines += ["/Users/demo/Source/tools/cmds"]
        case "git status":
            lines += ["On branch main", "Your branch is up to date with 'origin/main'.", "", "nothing to commit, working tree clean"]
        case "clear": clearLines()
        default:
            let name = cmd.split(separator: " ").first.map(String.init) ?? cmd
            lines += ["zsh: command not found: \(name)"]
        }
    }

    mutating func renderTop(tick: Int) {
        let load = String(format: "%.2f %.2f %.2f", 1.2 + Double(tick % 7) / 10, 1.4, 1.6)
        let procs: [(String, Double, Double)] = [
            ("node", 12.3 + Double(tick % 5), 3.1), ("cmds", 4.2 + Double(tick % 3), 1.8), ("claude", 2.0 + Double(tick % 4), 2.4),
            ("postgres", 0.8, 1.1), ("WindowServer", 6.5, 0.9), ("zsh", 0.0, 0.1),
        ]
        var out = [
            "Processes: 512 total, 3 running   Load Avg: \(load)   tick \(tick)",
            "CPU usage: \(String(format: "%.1f", 8 + Double(tick % 9)))% user, 6.2% sys   PhysMem: 15G used",
            "",
            "PID    COMMAND        %CPU   %MEM",
        ]
        for (i, p) in procs.enumerated() {
            out.append(String(format: "%-6d %-14@ %5.1f  %5.1f", 1000 + i * 37, p.0 as NSString, p.1, p.2))
        }
        lines = out
        prompt = ""
    }

    mutating func appendBuildLine(tick: Int) {
        let files = ["Workspace.swift", "SplitView.swift", "SyncServer.swift", "Ghostty.swift", "Sidebar.swift"]
        appendOutput("[\(tick / 2)/120] Compiling CmdsApp \(files[(tick / 2) % files.count])", keepingAtMost: 200)
    }
}

enum MockData {
    static let workspaces: [WorkspaceInfo] = [
        WorkspaceInfo(
            id: "w-cmds", title: "cmds", selected: true, gitBranch: "main",
            workingDirectory: "~/Source/tools/cmds", ports: [3000],
            notificationText: "Build succeeded", attention: false,
            panes: [
                PaneInfo(id: "p-shell", kind: .terminal, title: "zsh", focused: true, attention: false, workingDirectory: "~/Source/tools/cmds"),
                PaneInfo(id: "p-build", kind: .terminal, title: "xcodebuild", focused: false, attention: false),
                PaneInfo(id: "p-top", kind: .terminal, title: "top", focused: false, attention: false),
            ],
            layout: .split(axis: .horizontal, ratio: 0.55, first: .pane(id: "p-shell"),
                           second: .split(axis: .vertical, ratio: 0.5, first: .pane(id: "p-build"), second: .pane(id: "p-top")))),
        WorkspaceInfo(
            id: "w-api", title: "api-server", selected: false, gitBranch: "feature/auth-tokens",
            workingDirectory: "~/Source/web/api", ports: [8080, 5432],
            notificationText: "Tests passed (142)", attention: false,
            panes: [
                PaneInfo(id: "p-agent", kind: .terminal, title: "claude", focused: true, attention: false),
                PaneInfo(id: "p-api-shell", kind: .terminal, title: "zsh", focused: false, attention: false),
            ],
            layout: .split(axis: .vertical, ratio: 0.7, first: .pane(id: "p-agent"), second: .pane(id: "p-api-shell"))),
        WorkspaceInfo(
            id: "w-dot", title: "dotfiles", selected: false, gitBranch: "master",
            workingDirectory: "~/.dotfiles", ports: [], notificationText: nil, attention: false,
            panes: [PaneInfo(id: "p-dot", kind: .terminal, title: "codex", focused: true, attention: false)],
            layout: .pane(id: "p-dot")),
        WorkspaceInfo(
            id: "w-report", title: "report", selected: false, gitBranch: "main",
            workingDirectory: "~/Source/report", ports: [], notificationText: "Opened chart.png", attention: false,
            panes: [
                PaneInfo(id: "p-report-shell", kind: .terminal, title: "zsh", focused: false, attention: false),
                PaneInfo(id: "p-chart", kind: .preview, title: "chart.png", focused: true, attention: false,
                         file: "/Users/demo/Source/report/out/chart.png"),
                PaneInfo(id: "p-notes", kind: .preview, title: "NOTES.md", focused: false, attention: false,
                         file: "/Users/demo/Source/report/NOTES.md"),
            ],
            layout: .split(axis: .horizontal, ratio: 0.5, first: .pane(id: "p-report-shell"),
                           second: .split(axis: .vertical, ratio: 0.6, first: .pane(id: "p-chart"), second: .pane(id: "p-notes")))),
    ]

    /// A small bar chart for the mock preview pane.
    static func chartPNG() -> Data {
        let size = CGSize(width: 640, height: 400)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.pngData { context in
            UIColor(white: 0.1, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let values: [CGFloat] = [0.35, 0.6, 0.45, 0.8, 0.7, 0.95]
            let colors: [UIColor] = [.systemBlue, .systemTeal, .systemGreen, .systemOrange, .systemPink, .systemPurple]
            let barWidth = size.width / CGFloat(values.count * 2)
            for (index, value) in values.enumerated() {
                colors[index].setFill()
                let height = (size.height - 80) * value
                context.fill(CGRect(x: barWidth * (CGFloat(index) * 2 + 0.5), y: size.height - 40 - height,
                                    width: barWidth, height: height))
            }
            let title = "Build time per day" as NSString
            title.draw(at: CGPoint(x: 24, y: 12), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 22),
                                                                   .foregroundColor: UIColor.white])
        }
    }

    /// Earlier output above the demo screens (`requestScrollback`), so the phone has something to scroll back to.
    static func history(paneID: String) -> [String] {
        switch paneID {
        case "p-agent":
            // The shell before `claude` started (its header box is the first row of the demo screen).
            return [
                "demo@mac api % git switch -c feature/auth-tokens",
                "Switched to a new branch 'feature/auth-tokens'",
                "demo@mac api % npm test -- test/auth",
                "",
                "> api@1.4.0 test",
                "> vitest run test/auth",
                "",
                " ✓ test/auth/login.test.ts (6 tests) 41ms",
                " ✗ test/auth/middleware.test.ts (8 tests | 1 failed) 63ms",
                "   ✗ rejects an expired token",
                "     AssertionError: expected 200 to be 401",
                "",
                " Test Files  1 failed | 1 passed (2)",
                "      Tests  1 failed | 13 passed (14)",
                "demo@mac api % claude",
            ]
        case "p-shell":
            return [
                "demo@mac cmds % swift test --package-path Packages/CmdsCore",
                "Building for debugging...",
                "Build complete! (12.48s)",
                "Test Suite 'All tests' passed at 2026-10-29 09:10:02.317.",
                "\t Executed 412 tests, with 0 failures (0 unexpected) in 3.902 (4.118) seconds",
                "demo@mac cmds % git status --short",
                " M App/Sources/Sync/SyncServer.swift",
                "demo@mac cmds % git commit -qam \"Sync: stream the screen of new panes\"",
            ]
        default:
            return []
        }
    }

    static func shells() -> [String: FakeShell] {
        let prompt = "demo@mac cmds % "
        var shells = [
            "p-shell": FakeShell(prompt: prompt, lines: [
                "Last login: Thu Oct 29 09:12:44 on ttys003",
                prompt + "git log --oneline -3",
                "fdf7e93 Build: explicit schemes, arm64, bundle Ghostty resources",
                "c1d9efc Implement libghostty terminal engine",
                "1c3ae42 Initial skeleton: CmdsCore package, terminal contract",
            ]),
            "p-build": FakeShell(rows: 18, cols: 100, prompt: "", lines: ["$ xcodebuild -scheme CmdsApp build"]),
            "p-top": FakeShell(rows: 12, cols: 60, prompt: ""),
            "p-agent": FakeShell(prompt: "> ", lines: [
                "╭──────────────────────────────────────────────╮",
                "│ ✻ Claude Code                                │",
                "╰──────────────────────────────────────────────╯",
                "",
                "● I updated the token validation in auth/middleware.ts",
                "  and added tests for expired tokens.",
                "",
                "  Do you want me to run the full test suite? (y/n)",
            ]),
            "p-api-shell": FakeShell(prompt: "demo@mac api % ", lines: ["npm run dev", "> api@1.4.0 dev", "listening on :8080"]),
            "p-dot": FakeShell(prompt: "demo@mac .dotfiles % "),
        ]
        if ProcessInfo.processInfo.arguments.contains("-mockFullScreenTUI") {
            shells["p-agent"]?.fixed = fullScreenTUI()
        }
        if ProcessInfo.processInfo.arguments.contains("-mockJapanese") {
            // Rows with wide (Japanese) characters and the cursor after them, to check the layout on the cell grid
            // (#115). The dotfiles workspace, like -mockStreamOutput.
            let prompt = "demo@mac 日本語 % "
            var shell = FakeShell(prompt: prompt, lines: [
                prompt + "ls -l",
                "合計 2",
                "-rw-r--r--  1 demo  staff  1204 11月  6 14:32 設定メモ.md",
                "-rw-r--r--  1 demo  staff   880 11月  6 14:30 readme.md",
                "|名前      |状態    |",
                "|api-server|作業中  |",
                "|docs      |完了    |",
            ])
            shell.current = "echo こんにちは"
            shells[streamOutputPaneID] = shell
        }
        if ProcessInfo.processInfo.arguments.contains("-mockStreamOutput") {
            // A command printing numbered lines, 300 of them already, into a full scrollback (a reset every 30 lines).
            var shell = FakeShell(prompt: "", lines: ["demo@mac .dotfiles % ./print-lines.sh"])
            for _ in 0..<300 { shell.printNumberedLine() }
            shell.prunedPages = (limit: 330, page: 30)
            shells[streamOutputPaneID] = shell
        }
        return shells
    }

    /// The pane that prints numbered lines with `-mockStreamOutput` (the only pane of the dotfiles workspace).
    static let streamOutputPaneID = "p-dot"

    /// Like Claude Code in a large Mac pane: 56×150, a header at the top, the prompt and status lines at the
    /// bottom, empty rows in between, cursor (hidden on the Mac) on the prompt row.
    static func fullScreenTUI(rows: Int = 56, cols: Int = 150) -> ScreenSnapshot {
        let rule = String(repeating: "─", count: cols)
        let header = ["", " ▐▛███▜▌   Claude Code v2.1", "▝▜█████▛▘  Opus · Claude Team", "  ▘▘ ▝▝    ~/Source/web/api"]
        let footer = [
            String(repeating: " ", count: cols - 20) + "◐ medium · /effort",
            rule, "❯\u{a0}", rule,
            "  ◆ Opus (medium) │ 📁 api │ ctx ░░░░░░░░ 12% │ 日本語",
            "  ⏵⏵ auto mode on (shift+tab to cycle)",
        ]
        let lines = header + Array(repeating: "", count: rows - header.count - footer.count) + footer
        return ScreenSnapshot(rows: rows, cols: cols, lines: lines, cursorRow: rows - 4, cursorCol: 2)
    }
}

/// Colours for the demo screens, by what the rows say (a prompt, a commit hash, a passed or failed test, Claude Code's
/// header and status lines), so the demo shows a screen as a current Mac sends it (`SyncFeature.styles`, #113).
enum MockStyles {
    static func styled(_ snapshot: ScreenSnapshot) -> ScreenSnapshot {
        var styled = snapshot
        for (row, line) in snapshot.lines.enumerated() { styled.setRuns(runs(line), row: row) }
        return styled
    }

    private static func run(_ column: Int, _ length: Int, _ attributes: TerminalStyle.Attributes = [],
                            fg: UInt8? = nil, bg: TerminalColor? = nil) -> StyleRun {
        StyleRun(column: column, length: length,
                 style: TerminalStyle(attributes: attributes, foreground: fg.map { .palette($0) }, background: bg))
    }

    static func runs(_ line: String) -> [StyleRun] {
        let width = TerminalCells.width(of: line)
        if line.hasPrefix("demo@mac "), let percent = line.firstIndex(of: "%") {
            // demo@mac <dir> % : user bold green, directory blue.
            let dirStart = 9
            let dirWidth = TerminalCells.width(of: String(line[line.index(line.startIndex, offsetBy: 9)..<percent])) - 1
            return [run(0, 8, .bold, fg: 2), run(dirStart, max(dirWidth, 0), fg: 4)]
        }
        if line.count > 8, line.prefix(7).allSatisfy(\.isHexDigit), line.dropFirst(7).first == " " {
            return [run(0, 7, fg: 3)]
        }
        let trimmed = line.drop { $0 == " " }
        let indent = line.count - trimmed.count
        if trimmed.hasPrefix("✓") { return [run(indent, 1, fg: 2)] }
        if trimmed.hasPrefix("✗") { return [run(indent, width - indent, .bold, fg: 1)] }
        if trimmed.hasPrefix("AssertionError") { return [run(indent, width - indent, fg: 1)] }
        if trimmed.hasPrefix("●") { return [run(indent, 1, fg: 2)] }
        if trimmed.hasPrefix("> ") { return [run(indent, width - indent, .faint)] }
        if trimmed.hasPrefix("M ") || line.hasPrefix(" M ") { return [run(1, 1, fg: 1)] }
        if line.hasPrefix("listening on") { return [run(0, width, fg: 2)] }
        if line.hasPrefix("Build complete!") { return [run(0, 15, .bold, fg: 2)] }
        if line.hasPrefix("│ ✻") { return [run(0, 1, fg: 208), run(2, 1, fg: 208), run(4, 11, .bold), run(width - 1, 1, fg: 208)] }
        if line.hasPrefix("╭") || line.hasPrefix("╰") || line.hasPrefix("│") { return [run(0, width, fg: 208)] }
        if line.hasPrefix(" ▐▛") || line.hasPrefix("▝▜") || line.hasPrefix("  ▘▘") { return [run(0, 10, fg: 208)] }
        if line.hasPrefix("  ◆ ") { return [run(2, width - 2, .inverse, fg: 4)] }
        if line.hasPrefix("  ⏵⏵") { return [run(2, width - 2, fg: 5)] }
        if line.hasPrefix("─") { return [run(0, width, .faint)] }
        return []
    }
}
