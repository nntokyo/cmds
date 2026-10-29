import CmdsCore
import Foundation

/// In-process fake Mac for previews and `-mock` launches. Speaks the real protocol (including
/// `ScreenStreamer` diffs) so the client code path is the same as with a real Mac.
final class MockTransport: SyncTransport {
    var onEvent: ((TransportEvent) -> Void)?

    private var timer: Timer?
    private var streamer = ScreenStreamer()
    private var subscribed: Set<String> = []
    private var workspaces: [WorkspaceInfo]
    private var shells: [String: FakeShell]
    private var tick = 0
    private var closed = false
    private var system: SystemStats?
    private var agentLimits: [AgentLimits] = []
    private let startedAt = Date()

    init() {
        workspaces = MockData.workspaces
        shells = MockData.shells()
        updateUsage()
    }

    private var currentState: ServerMessage.State { .init(workspaces: workspaces, system: system, agentLimits: agentLimits) }

    func start() {
        deliver(after: 0.15, .connected)
    }

    func send(_ message: ClientMessage) {
        guard !closed else { return }
        switch message {
        case .hello:
            deliver(after: 0.1, .message(.welcome(.init(macName: "Demo Mac", token: "mock-token"))))
            deliver(after: 0.1, .message(.state(currentState)))
            DispatchQueue.main.async { self.startTimer() }
        case .subscribe(let sub):
            let new = Set(sub.paneIDs)
            for paneID in new.subtracting(subscribed) { streamer.reset(paneID: paneID) }
            subscribed = new
            streamer.retain(paneIDs: new)
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
        }
    }

    func close() {
        closed = true
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.step() }
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
            guard let shell = shells[paneID], let msg = streamer.update(paneID: paneID, snapshot: shell.snapshot) else { continue }
            emit(msg)
        }
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

    init(rows: Int = 24, cols: Int = 80, prompt: String, lines: [String] = []) {
        self.rows = rows
        self.cols = cols
        self.prompt = prompt
        self.lines = lines
    }

    var snapshot: ScreenSnapshot {
        if let fixed { return fixed }
        var visible = lines + [prompt + current]
        if visible.count > rows { visible = Array(visible.suffix(rows)) }
        let cursorRow = visible.count - 1
        while visible.count < rows { visible.append("") }
        let cursorCol = min(cols - 1, (prompt + current).count)
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
        case .ctrlL: lines = []
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
        case "clear": lines = []
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
        lines.append("[\(tick / 2)/120] Compiling CmdsApp \(files[(tick / 2) % files.count])")
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
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
    ]

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
        return shells
    }

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
