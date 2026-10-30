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
| `App/Sources/Preview` | File preview pane (`PreviewPane`: header, Quick Look / image view / rendered HTML, file watcher). Renderers in `CmdsCore/Preview` (`MarkdownHTML`, `DiffHTML`, `PreviewHTML`). |
| `App/Sources/Shortcuts` | Main menu + key equivalents. |
| `App/Sources/API` | Unix-socket JSON-lines server dispatching to `AppController`. |
| `App/Sources/Sync` | Companion server (Bonjour `_cmds._tcp`, WebSocket over TLS, keychain sync identity, pairing window, Bluetooth L2CAP relay fallback) for the iOS app. |
| `iOS/Sources` | SwiftUI iOS/iPadOS companion. |
| `vendor/ghostty` | Ghostty source (git submodule). `vendor/GhosttyKit.xcframework` is a symlink/copy of `vendor/ghostty/macos/GhosttyKit.xcframework` (gitignored). Build: `cd vendor/ghostty && zig build -Demit-xcframework=true -Dxcframework-target=native -Demit-macos-app=false -Doptimize=ReleaseFast` |

Project file is generated: `xcodegen generate` (do not commit `cmds.xcodeproj`).

## Key concepts

- **Workspace** = one vertical tab. Holds a split tree of panes. Each workspace has a primary working directory.
- **Pane** = terminal (`TerminalSurface`), browser (`WKWebView`) or preview (a local file). IDs are short stable strings (e.g. `p1`, `w1`).
- **Preview pane** (`PaneKind.preview`, `PaneInfo.file` = absolute path): header (name, folder → Reveal in Finder,
  Open in Default App, Reload/⌘R). Images: `NSImageView`; Markdown (`.md`): `MarkdownHTML` (GitHub-flavoured subset,
  raw HTML escaped, only http(s)/mailto/file/relative links) and unified diffs (`.diff`/`.patch` or `format: diff`):
  `DiffHTML`, both in a WKWebView with JavaScript off, a CSP, light/dark CSS, and local images of the Markdown's folder
  served by a `cmds-preview:` scheme handler (images/media inside that folder only); text without a known type as
  `<pre>`; everything else `QLPreviewView`. Rendered text is capped at 8 MB. A vnode `DispatchSource` reloads on
  writes (coalesced, scroll position kept); on delete/rename (atomic save) it re-attaches to the new file, and while
  the file is missing the pane shows a placeholder and polls once a second. Opened by `pane.open_file`, File › Open in
  Preview… (⇧⌘O) and ⌘-click on a file path in a terminal: libghostty detects links (its default regex covers URLs and
  paths, resolving relative paths against the shell's OSC 7 directory when the file exists) and reports
  `GHOSTTY_ACTION_OPEN_URL`; `TerminalSurfaceDelegate.terminalSurface(_:openLink:)` turns an existing local file
  (also `path:line[:col]`) into a preview (reusing the workspace's preview pane, keyboard stays in the terminal);
  URLs, folders and missing files keep the default (open with the default app). In SSH panes a path link only beeps
  (the file is on the server). Session restore keeps preview panes (path, forced format).
- **SSH pane** ([SSH.md](SSH.md)): a terminal running the user's `ssh` with the pane's own restricted API socket
  forwarded to the server (`ssh -R`); `PaneInfo.remote` = `{host, connected, branch?}`, `WorkspaceInfo.remoteHost`
  while the focused pane is one (its cwd/branch are then remote). Survives `ssh` exiting (Reconnect overlay).
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

## Keeping the Mac awake

`App/Sources/App/KeepAwake.swift` (`KeepAwakeManager`); command strings, `pmset -g` parsing and the lid state machine
in `CmdsCore/KeepAwake.swift` (`SleepDisabledCommand`, `LidSleepController`, unit-tested with a fake `pmset`).

- **Idle sleep (automatic, no admin)**: while cmds runs it holds an IOKit `PreventUserIdleSystemSleep` assertion named
  "cmds: keeping AI agent sessions running" (cmds › Prevent Idle Sleep, default on; `UserDefaults`
  `KeepAwakePreventIdleSleep`). cmds › Keep Display Awake (default off, `KeepAwakeKeepDisplayOn`) adds
  `PreventUserIdleDisplaySleep`. Assertions belong to the process, so they end when cmds quits, crashes or is killed.
  Check with `pmset -g assertions`. **They do not prevent sleep when the lid is closed.**
- **Lid closed (opt-in, needs an administrator)**: macOS has no unprivileged API against clamshell sleep. cmds › Keep
  Awake With Lid Closed… shows a warning, then runs `/usr/bin/pmset -a disablesleep 1` through
  `NSAppleScript("do shell script … with administrator privileges")`: macOS shows its own password dialog, cmds never
  sees the password and only ever runs these two fixed commands. Unchecking it (or clicking the footer indicator)
  runs `/usr/bin/pmset -a disablesleep 0`; so does quitting cmds (`applicationWillTerminate`, one more dialog). The
  setting is system-wide (`pmset -g` shows `SleepDisabled 1`) and is not tied to the cmds process.
  - cmds only turns `SleepDisabled` off again if it turned it on itself: it writes `lid-sleep-disabled.json` in the
    support directory *before* the dialog and removes it only after sleep is restored. If `SleepDisabled` was already
    on (another tool, or the user), the menu item shows a mixed state and cmds leaves it alone.
  - Next launch with the marker still there (crash, force quit, cancelled dialog at quit): if `SleepDisabled` is still
    1, an alert offers "Restore Sleep" (one dialog); if it is already 0, the marker is just removed.
  - Switching to battery while cmds keeps a closed Mac awake: a notification and an alert offer to turn it off.
    cmds cannot turn it off without the password, and nothing reacts to a low battery with the lid closed (no root
    helper; a closed Mac shows no dialogs) — macOS still sleeps/shuts down at its critical battery level.
  - **Caveat**: if cmds crashes or is killed, the lid keeps not sleeping the Mac until cmds starts again (and the
    user restores) or the user runs `sudo pmset -a disablesleep 0`. A closed laptop that never sleeps keeps running in
    a bag: it can overheat and drain the battery.
  - Status: the sidebar footer shows "Awake (lid closed OK)" (orange, a moon icon in the compact rail) whenever
    `SleepDisabled` is 1; `cmds stats` has an `awake` line, `system.stats` a `keepAwake` object. `pmset -g` is re-read
    every 60 s (unprivileged).
  - Isolated instances (`CMDS_SUPPORT_DIR`) hold the idle assertion (settings in memory only) but never prompt or run
    `pmset` with privileges; the lid menu item is disabled.

## Socket API (JSON lines, see `CmdsCore/RPC.swift`)

Socket: `~/Library/Application Support/cmds/cmds.sock` (mode 0600).

| Method | Params | Result |
|---|---|---|
| `system.ping` | – | `{"pong": true}` |
| `system.identify` | – | `{"version", "build", "pid", "socketPath", "cliPath"}` |
| `system.stats` | – | `{"system": SystemStats, "workspaces": [{"id", "cpuPercent", "memoryBytes"}], "agentLimits"?: [AgentLimits], "keepAwake": KeepAwakeStatus}` (`system` is omitted until two samples exist, ~1 s after launch; workspace fields until sampled or without processes; `agentLimits` while any is known; `keepAwake` = `idleAssertion`, `displayAssertion`, `lidCloseDisabled` (system `SleepDisabled`), `lidCloseByCmds`, `lidCloseAvailable`, `onBattery`, see [Keeping the Mac awake](#keeping-the-mac-awake)) |
| `sync.status` | – | `SyncStatusReport` (iOS sync: `enabled`, `state`, `port`, `fingerprint`, `bonjour`, `pairingWindowOpen`, `pairedDevices`, `bluetooth` {`allowed`, `disabledByEnvironment`, `authorization`, `managerState`, `advertising`, `psm`, `channels`, `status`}, `remote` {`enabled`, `host`, `relayPort`, `forwarding`, `status`}, `clients` [{`deviceName`, `authenticated`, `peer`, `path`, `subscribedPanes`, `bytesSent`, `bytesReceived`, `connectedSince`, `connectedSeconds`}]); local socket only, see [SYNC.md](SYNC.md#testing-on-a-device) |
| `agent.report` | `pane?`, `usage` (`AgentUsage`), `pid?` (agent process) | – (sets the pane's agent usage; its `limits` become that agent's account limits) |
| `agent.claude_hook` | `pane?`, `input` (Claude Code hook JSON, object or JSON text) | – (notifies like `cmds hook claude`; never reads the transcript) |
| `agent.claude_status` | `pane?`, `input` (status-line JSON) | – (like `cmds hook claude-status`, without a pid) |
| `agent.sessions` | `pane?` (default: all panes) | `AgentSessionList` `{"mode": "ask"/"always"/"never", "sessions": [{"workspace", "pane", "state", "session": AgentSession, "command"?}]}` |
| `agent.resume` | `pane?` or `all: true` | `{"queued": [pane], "skipped": [{"pane", "reason"}]}` (types the resume command once the pane's prompt is ready; [AGENTS.md](AGENTS.md#resuming-sessions)) |
| `remote.location` | `pane?`, `cwd?`, `branch?` | – (SSH panes: remote cwd/branch from `cmds-remote.sh prompt`) |
| `agent.list` | – | `{"panes": [{"workspace", "pane", "usage": AgentUsage}], "limits": [AgentLimits]}` |
| `workspace.list` | – | `[WorkspaceInfo]` |
| `workspace.create` | `title?`, `cwd?`, `command?` or `ssh` (host), `remoteCwd?` | `WorkspaceInfo` |
| `workspace.select` | `id` | – |
| `workspace.close` | `id` | – |
| `workspace.rename` | `id`, `title` | – |
| `pane.list` | `workspace?` | `[PaneInfo]` |
| `pane.split` | `pane?`, `direction` (`right`/`down`), `kind?` (`terminal`/`browser`), `url?`, `cwd?`, `command?`, `focus?` (default true), `ssh?` (host), `remoteCwd?` | `PaneInfo` |
| `pane.open_file` | `path` (absolute, existing file), `pane?` (to split from; a preview pane shows the file itself instead), `direction?` (`right`/`down`), `focus?` (default true), `format?` (`markdown`/`diff`/`quicklook`) | `PaneInfo` (kind `preview`); refused (403) on SSH panes' sockets |
| `pane.reconnect` | `pane?` | – (restarts an SSH pane's `ssh`) |
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
Methods without a result return `{}`. CLI usage: [CLI.md](CLI.md). The per-pane sockets of SSH panes accept only an
allowlist of these, pinned to their pane/workspace ([SSH.md](SSH.md#what-the-server-may-do-enforced-in-the-app)).
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
| New SSH workspace… | ⇧⌘N |
| Reconnect SSH pane (when disconnected; otherwise browser / preview reload) | ⌘R |
| Close pane | ⌘W |
| Close workspace | ⇧⌘W |
| Select workspace 1–9 | ⌘1 … ⌘9 |
| Next / previous workspace | ⌃Tab / ⌃⇧Tab, ⇧⌘] / ⇧⌘[ |
| Split right / down | ⌘D / ⇧⌘D |
| Focus pane left/right/up/down | ⌥⌘←/→/↑/↓ |
| Open browser split | ⇧⌘B |
| Open in Preview… (file picker) | ⇧⌘O |
| Preview a file path in a terminal | ⌘-click |
| Browser: focus address bar / reload / back / forward | ⌘L / ⌘R / ⌘[ / ⌘] |
| Jump to latest attention pane | ⇧⌘U |
| Toggle sidebar | ⌘B |
| Compact sidebar (52 pt rail: workspace numbers, attention dot, status colour, tiny meters; also the button at the top of the sidebar; remembered in `UserDefaults` `SidebarCompact`, not by isolated instances, which start compact with `CMDS_SIDEBAR_COMPACT=1`) | ⌃⌘S |
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
- A window that is not on screen (another Space, hidden) is not drawn, so `screencapture` shows nothing. DEBUG
  builds answer `debug.preview_snapshot {pane}` → `{"png_base64"}` with a picture of a preview pane drawn off screen
  (web content via WKWebView's snapshot; Quick Look's out-of-process view stays blank).

## Localization

English is the development language; Japanese (`ja`) is the other localization. Each app has its own String
Catalogs: `App/Resources/Localizable.xcstrings` + `InfoPlist.xcstrings` (Mac) and the same in `iOS/Resources`
(permission texts: local network, Bluetooth, camera). `CFBundleLocalizations` is `[en, ja]`.

- **Language**: follows the system (macOS: System Settings › General › Language & Region, which also has per-app
  languages; iOS: device language or Settings › cmds › Language). The Mac app also has cmds › Language › System /
  日本語 / English (`AppLanguage`): it sets `AppleLanguages` in the app's own defaults domain (System removes it) and
  offers to relaunch. An isolated instance never writes it; launch it with `-AppleLanguages '(ja)'` or `'(en)'`.
- **Adding a string**: AppKit takes `String`, so write `String(localized: "Split Right")`; SwiftUI `Text("…")`,
  `Button("…")`, `Label`, `navigationTitle` take `LocalizedStringKey` and need nothing. Interpolate instead of
  concatenating (`String(localized: "Resume All (\(count))")` → key `Resume All (%lld)`; String → `%@`, Int → `%lld`);
  translations reorder with `%1$@`/`%2$lld`. Format numbers to strings first (a `Double` becomes `%lf`). Helpers
  that take `String.LocalizationValue` (`MainMenu.item`) are extracted at their call sites. Then build and run
  `scripts/l10n-sync.sh` (or build in Xcode, which syncs the catalogs itself) and add the Japanese in Xcode's catalog
  editor or the JSON. English plurals go in the catalog's plural variations (`%lld processes…`).
- **Stays English**: the socket API, `cmds` CLI output and its error messages (scripts parse them; also what
  `--json` and AGENTS.md document), sync protocol strings, identifiers, file names, commands and log lines. Status
  texts that the UI shows and the API reports (`SyncServer`/`SyncBluetoothPeripheral`/`SyncRemoteAccess` status) are
  a `LocalizedStatus`: `.localized` for the UI, `.english` for `sync.status`. Default pane/workspace titles
  ("Terminal", "Browser") and text from `CmdsCore` formatters (agent usage lines, `AgentSession.summary`, error
  descriptions) are shared with the CLI and stay English; the banner builds its own localized summary.
- **Japanese style**: Apple's current terms (設定, ウインドウ, しまう, 取り消す/やり直す, すべてを選択), full-width
  （）and ：in prose, keyboard shortcuts unchanged, product/protocol names (cmds, SSH, Wi‑Fi, Bluetooth, TLS) as is.
- **UI tests** find elements by accessibility identifier, never by visible (localized) text.

## iOS companion sync

Mac runs a WebSocket server over TLS 1.3 (Network.framework) advertised as `_cmds._tcp`, presenting its own
self-signed certificate (ECDSA P-256 key in the login keychain). Pairing: "Pair iPhone/iPad…" shows a QR code with the
certificate fingerprint and a 6-digit code; the phone pins the fingerprint (from the QR code, or after the user compared
a short fingerprint) before it sends the code, and afterwards accepts only that certificate. Messages are JSON
(`CmdsCore/Sync`). The Mac pushes workspace snapshots and per-pane screen text (only changed panes, ~10 Hz); the phone
sends `input` (text/keys) and `select`/`focus` commands. Protocol, pairing and threat model: [SYNC.md](SYNC.md).
