# cmds architecture

Native macOS terminal multiplexer for coding agents. Swift + AppKit, terminal rendering via libghostty
(GhosttyKit.xcframework built from `vendor/ghostty`). GPL-3.0.

## Layout

| Path | Contents |
|---|---|
| `Packages/CmdsCore` | SwiftPM package shared by macOS app, CLI and iOS: RPC wire types, snapshot models, sync protocol. Also the `cmds` CLI executable (`Sources/cmds-cli`). |
| `App/Sources/Terminal` | `TerminalSurface.swift` (contract) + `Ghostty/` (libghostty implementation). |
| `App/Sources/Workspace` | Workspace/pane model, split tree, `AppController` (single source of truth, main actor). |
| `App/Sources/Sidebar` | Vertical tabs: title, git branch, cwd, listening ports, coding agent (model, context, cost, 5-hour limit), CPU/memory, latest notification text, attention dot. Footer: account limits per agent (Claude, Codex) and Mac-wide CPU and memory meters. |
| `App/Sources/Panes` | Split container views, pane container with notification ring. |
| `App/Sources/Browser` | WKWebView browser pane. |
| `App/Sources/Shortcuts` | Main menu + key equivalents. |
| `App/Sources/API` | Unix-socket JSON-lines server dispatching to `AppController`. |
| `App/Sources/Sync` | Companion server (Bonjour `_cmds._tcp`, WebSocket over TLS, keychain sync identity, pairing window) for the iOS app. |
| `iOS/Sources` | SwiftUI iOS/iPadOS companion. |
| `vendor/ghostty` | Ghostty source (git submodule). `vendor/GhosttyKit.xcframework` is a symlink/copy of `vendor/ghostty/macos/GhosttyKit.xcframework` (gitignored). Build: `cd vendor/ghostty && zig build -Demit-xcframework=true -Dxcframework-target=native -Demit-macos-app=false -Doptimize=ReleaseFast` |

Project file is generated: `xcodegen generate` (do not commit `cmds.xcodeproj`).

## Key concepts

- **Workspace** = one vertical tab. Holds a split tree of panes. Each workspace has a primary working directory.
- **Pane** = terminal (`TerminalSurface`) or browser (`WKWebView`). IDs are short stable strings (e.g. `p1`, `w1`).
- **Attention / notification ring**: a pane lights up (colored ring border) when its program sends OSC 9/777,
  rings the bell, or `cmds notify` targets it — and the pane is not the focused pane of the key window.
  Focusing the pane clears it. The workspace row in the sidebar shows a dot + the latest notification text.
- Every terminal gets env `CMDS_SOCKET_PATH`, `CMDS_WORKSPACE_ID`, `CMDS_PANE_ID` so the CLI targets its own pane by default.
- **Resource usage** (`Workspace/MetadataMonitor.swift`, `SystemSampler.swift`; math in `CmdsCore/ResourceSampling.swift`,
  `ProcessAttribution.swift`): every 2 s one background scan finds each workspace's processes and reads their
  listening ports and `proc_pid_rusage`. A process belongs to a workspace by (1) `CMDS_WORKSPACE_ID` in its
  environment with our `CMDS_SOCKET_PATH` — macOS hides the environment of Apple platform binaries (`/bin/zsh`,
  `make`, `git`), so this only covers third-party ones (node, python…); (2) its controlling tty, found from each
  pane's pty foreground process group (`TerminalSurface.foregroundProcessGroupID`); (3) its nearest attributed
  ancestor (detached children). Workspace CPU = growth of own + reaped-children CPU time (catches processes that
  start and exit between scans) over wall time, Activity Monitor style (100 % = one core, capped at all cores);
  memory = sum of `ri_phys_footprint`. Mac-wide: `host_statistics` CPU ticks (0–100 % of all cores); memory used =
  app (internal − purgeable) + wired + compressed pages (Activity Monitor's "Memory Used"); pressure =
  `kern.memorystatus_vm_pressure_level` (1 normal, 2 warning, 4 critical). Updates go through
  `AppController.usageChanges`, not `changes`: only the usage labels redraw (no reloads, session saves or socket events).
- **Agent usage** (`CmdsCore/AgentUsage.swift`, `AgentFormat.swift`, `ClaudeStatusLine.swift`, `CodexRollout.swift`;
  app: `Workspace/CodexSessionWatcher.swift`, `AppController` "Agents"): per terminal pane an optional `AgentUsage`
  (`PaneInfo.agent`) plus the latest account limits per agent kind (`AgentLimits`).
  - Claude Code: its status-line command runs `cmds hook claude-status`, which parses the status-line JSON and sends
    `agent.report` with the Claude process id (nearest ancestor recognised as Claude, else the nearest non-shell).
    The usage is dropped when that process exits (without a pid: after 30 min without updates).
  - Codex: the metadata scan finds `codex` processes (exec path / argv; `app-server`/`exec-server`/`mcp-server` are
    services, `login`/`features`… are ignored) and places sessions in panes by `CMDS_PANE_ID` (else pane tty). A
    session process that holds its `rollout-*.jsonl` open owns it. Codex ≥ 0.16x TUIs run their sessions in the shared
    app-server daemon, which holds the files instead; such a file is matched by `session_meta.cwd` and time
    (`CodexSessionMatcher`: the most recently started Codex pane before the session was created, else before its last
    write, for resumed sessions). Files are read only when size/mtime change, only the appended bytes (≤ 256 KB tail);
    only lines mentioning `token_count`/`turn_context` are decoded, into types holding just the usage fields. Context
    % uses Codex's own formula (12k baseline). Usage is dropped when the pane has no Codex process left.
  - Usage without updates for 3 min is marked `stale` (idle agent, dimmed). Limits whose `resetsAt` passed are left
    out. Report-driven updates go through `usageChanges` (coalesced to 4/s); only appearing/disappearing agents emit
    `pane` changes (row height).

## Socket API (JSON lines, see `CmdsCore/RPC.swift`)

Socket: `~/Library/Application Support/cmds/cmds.sock` (mode 0600).

| Method | Params | Result |
|---|---|---|
| `system.ping` | – | `{"pong": true}` |
| `system.identify` | – | `{"version", "build", "pid", "socketPath", "cliPath"}` |
| `system.stats` | – | `{"system": SystemStats, "workspaces": [{"id", "cpuPercent", "memoryBytes"}], "agentLimits"?: [AgentLimits]}` (`system` is omitted until two samples exist, ~1 s after launch; workspace fields until sampled or without processes; `agentLimits` while any is known) |
| `agent.report` | `pane?`, `usage` (`AgentUsage`), `pid?` (agent process) | – (sets the pane's agent usage; its `limits` become that agent's account limits) |
| `agent.list` | – | `{"panes": [{"workspace", "pane", "usage": AgentUsage}], "limits": [AgentLimits]}` |
| `workspace.list` | – | `[WorkspaceInfo]` |
| `workspace.create` | `title?`, `cwd?`, `command?` | `WorkspaceInfo` |
| `workspace.select` | `id` | – |
| `workspace.close` | `id` | – |
| `workspace.rename` | `id`, `title` | – |
| `pane.list` | `workspace?` | `[PaneInfo]` |
| `pane.split` | `pane?`, `direction` (`right`/`down`), `kind?` (`terminal`/`browser`), `url?`, `cwd?`, `command?`, `focus?` (default true) | `PaneInfo` |
| `pane.focus` | `pane` | – |
| `pane.close` | `pane` | – |
| `pane.send_text` | `pane?`, `text` | – |
| `pane.read_text` | `pane?`, `scrollback?` (lines) | `{"text": ...}` |
| `notify` | `pane?`, `title?`, `body` | – |
| `sidebar.set_status` | `workspace?`, `text` | – (sets notification text without ringing) |
| `browser.open` | `pane?` (terminal to split from), `url`, `focus?` (default true) | `PaneInfo` |
| `browser.navigate` | `pane`, `url` | – |
| `browser.eval` | `pane`, `script` | `{"value": ...}` (JSON-serializable result) |
| `browser.get_url` | `pane` | `{"url", "title"}` |
| `browser.snapshot` | `pane` | `{"png_base64"}` |
| `events.subscribe` | – | then server pushes `RPCEvent`s (`notification`, `workspace.changed`, `pane.changed`, `workspaces.changed`) |

`pane?` / `workspace?` default to `CMDS_PANE_ID` / `CMDS_WORKSPACE_ID` (sent by the CLI), else the focused one.
`browser.*` without `pane` use the focused (else first) browser pane of `workspace?` (default: selected).
Methods without a result return `{}`. CLI usage: [CLI.md](CLI.md).
`WorkspaceInfo` (so also `workspace.list`, events and sync) has optional `cpuPercent` (100 = one core) and
`memoryBytes` (physical footprint). `SystemStats` = `cpuPercent` (0–100, all cores), `memoryUsedBytes`,
`memoryTotalBytes`, `memoryPressure` (1/2/4, optional).
`PaneInfo.agent?` = `AgentUsage`: `agent` (`claude`/`codex`/`other`), `updatedAt`, `limits` and optional `model`,
`effort`, `sessionID`, `contextUsedPercent`, `contextTokens`, `contextWindow`, `contextOver200k`, `costUSD`,
`sessionDurationMs`, `apiDurationMs`, `linesAdded`, `linesRemoved`, `cacheHitRatio` (0–1), `cacheWarm`,
`inputTokens`, `cachedInputTokens`, `outputTokens`, `reasoningTokens`, `plan`, `stale` (only when true).
`UsageLimit` = `id` (`five_hour`, `seven_day`, `spend`, …), `usedPercent`, optional `resetsAt`, `windowMinutes`,
`usedUSD`, `limitUSD`, `period`. `AgentLimits` = `agent`, `limits`, `plan?`, `updatedAt`. Dates are Unix epoch
seconds (decoding also takes milliseconds and ISO 8601); unknown agent names decode as `other`, malformed fields are
dropped instead of failing.

## Keyboard shortcuts (defaults)

| Action | Key |
|---|---|
| New workspace | ⌘N |
| Close pane | ⌘W |
| Close workspace | ⇧⌘W |
| Select workspace 1–9 | ⌘1 … ⌘9 |
| Next / previous workspace | ⌃Tab / ⌃⇧Tab, ⇧⌘] / ⇧⌘[ |
| Split right / down | ⌘D / ⇧⌘D |
| Focus pane left/right/up/down | ⌥⌘←/→/↑/↓ |
| Open browser split | ⇧⌘B |
| Browser: focus address bar / reload / back / forward | ⌘L / ⌘R / ⌘[ / ⌘] |
| Jump to latest attention pane | ⇧⌘U |
| Toggle sidebar | ⌘B |
| Rename workspace | ⇧⌘R |
| Zoom pane (toggle) | ⇧⌘↩ |

## Testing with an isolated instance

Never test against the instance you work in. Start a second one from your build:

```sh
CMDS_SUPPORT_DIR=/tmp/cmds-test CMDS_SYNC_DISABLED=1 build/dd/Build/Products/Debug/cmds.app/Contents/MacOS/cmds &
cmds --socket /tmp/cmds-test/cmds.sock ls
```

- `CMDS_SUPPORT_DIR` replaces `~/Library/Application Support/cmds` (session.json, sync-devices.json, cmds.sock) and
  wins over an inherited `CMDS_SOCKET_PATH`, so neither the instance nor a CLI given the variable can reach the
  live app. Such an instance also leaves the saved window/sidebar frames alone and does not activate itself on
  launch (it never takes keyboard focus from the app in use). Its terminals get the resolved absolute path.
- `CMDS_SYNC_DISABLED=1` skips the iOS sync server (no Bonjour advert, no port). To test sync instead, give the
  instance its own port and no advert: `CMDS_SYNC_PORT=47911 CMDS_SYNC_NO_BONJOUR=1` (DEBUG builds: add
  `CMDS_SYNC_TEST_PAIRING=1` for loopback-only pairing without the window, see [SYNC.md](SYNC.md#testing-with-an-isolated-instance)).
  The instance's sync identity lives in separate keychain items derived from `CMDS_SUPPORT_DIR`.
- Launch the binary directly; `open` does not pass the environment reliably.

## iOS companion sync

Mac runs a WebSocket server over TLS 1.3 (Network.framework) advertised as `_cmds._tcp`, presenting its own
self-signed certificate (ECDSA P-256 key in the login keychain). Pairing: "Pair iPhone/iPad…" shows a QR code with the
certificate fingerprint and a 6-digit code; the phone pins the fingerprint (from the QR code, or after the user compared
a short fingerprint) before it sends the code, and afterwards accepts only that certificate. Messages are JSON
(`CmdsCore/Sync`). The Mac pushes workspace snapshots and per-pane screen text (only changed panes, ~10 Hz); the phone
sends `input` (text/keys) and `select`/`focus` commands. Protocol, pairing and threat model: [SYNC.md](SYNC.md).
