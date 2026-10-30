# Architecture

> How the code is organised: targets, packages, the main concepts and how the pieces fit together.

cmds is a native macOS terminal workspace for coding agents. Swift + AppKit, terminal rendering via libghostty
(GhosttyKit.xcframework built from `vendor/ghostty`), an iOS/iPadOS companion in SwiftUI. GPL-3.0.

## Repository layout

| Path | Contents |
|---|---|
| `Packages/CmdsCore` | SwiftPM package shared by the macOS app, the CLI and iOS: RPC wire types, snapshot models, sync protocol, agent usage parsing, preview renderers, keep-awake logic, workspace export bundles. Also the `cmds` CLI executable (`Sources/cmds-cli`) and the unit tests (`CmdsCoreTests`, `CmdsCLITests`). |
| `Packages/CmdsSSH` | SSH client for the companion's remote access (swift-nio-ssh); only the iOS app links it, so the Mac app and CLI do not pull in SwiftNIO. `Scripts/test-relay-sshd.sh` runs a throwaway sshd for its tests. |
| `App/Sources/App` | App delegate, main window, language menu (`AppLanguage`), keep-awake (`KeepAwake.swift`), localized texts for core errors. |
| `App/Sources/Terminal` | `TerminalSurface.swift` (contract) + `Ghostty/` (libghostty implementation, plus a standalone debug harness). |
| `App/Sources/Workspace` | Workspace/pane model, split tree, `AppController` (single source of truth, main actor), session store, export/import, SSH sessions, metadata/CPU sampling, Codex session watcher. |
| `App/Sources/Sidebar` | Vertical tabs: title, git branch, cwd, listening ports, coding agent (model, context, cost, 5-hour limit), CPU/memory, latest notification text, attention dot. Footer: account limits per agent (Claude, Codex) and Mac-wide CPU and memory meters. Compact rail variant. |
| `App/Sources/Panes` | Split container views, pane container with notification ring, SSH connect sheet and overlay, agent resume banner. |
| `App/Sources/Browser` | WKWebView browser pane. |
| `App/Sources/Preview` | File preview pane (`PreviewPane`: header, Quick Look / image view / rendered HTML, file watcher). Renderers in `CmdsCore/Preview` (`MarkdownHTML`, `DiffHTML`, `PreviewHTML`). |
| `App/Sources/Shortcuts` | Main menu + key equivalents (`MainMenu`), menu actions (`CommandRouter`). |
| `App/Sources/API` | Unix-socket JSON-lines server dispatching to `AppController`; the bundled CLI and its installer. |
| `App/Sources/Sync` | Companion server (Bonjour `_cmds._tcp`, WebSocket over TLS, keychain sync identity, pairing window, Bluetooth L2CAP relay, remote access via SSH) for the iOS app. |
| `App/Resources`, `iOS/Resources` | Asset catalogs (app icons) and String Catalogs (`Localizable.xcstrings`, `InfoPlist.xcstrings`). |
| `Shared/Sources` | Localized UI text for CmdsCore values, compiled into both apps. |
| `iOS/Sources` | SwiftUI iOS/iPadOS companion (`Connection/` transports and client, `Views/`, `Support/`). |
| `iOS/UITests` | `CmdsDeviceDriver` UI test target: `DeviceDriverTests` (scripted driver) and `TerminalScreenTests`. |
| `integrations/claude` | Claude Code skill for working inside cmds. |
| `design/icon` | App icon artwork and the scripts that generate every icon size ([README](../../design/icon/README.md)). |
| `scripts` | `l10n-sync.sh` (String Catalog sync), `check-links.py` (Markdown link check). |
| `vendor/ghostty` | Ghostty source (submodule). `vendor/GhosttyKit.xcframework` is a symlink/copy of `vendor/ghostty/macos/GhosttyKit.xcframework` (ignored); build steps in the [README](../../README.md#build-from-source). |

The Xcode project is generated from `project.yml` with `xcodegen generate` (do not commit `cmds.xcodeproj`).
Targets: `cmds` (Mac app; scheme `CmdsApp`), `cmds-cli` (the CLI, embedded at `cmds.app/Contents/Resources/bin/cmds`),
`CmdsCompanion` (iOS app; scheme `CmdsCompanion`), `CmdsDeviceDriver` (iOS UI tests; scheme `CmdsDeviceDriver`).

## Key concepts

- **Workspace** = one vertical tab. Holds a split tree of panes. Each workspace has a primary working directory.
- **Pane** = terminal (`TerminalSurface`), browser (`WKWebView`) or preview (a local file). IDs are short strings (e.g. `p1`, `w1`), stable while the app runs and reassigned on launch.
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
- **SSH pane** ([ssh.md](ssh.md)): a terminal running the user's `ssh` with the pane's own restricted API socket
  forwarded to the server (`ssh -R`); `PaneInfo.remote` = `{host, connected, branch?}`, `WorkspaceInfo.remoteHost`
  while the focused pane is one (its cwd/branch are then remote). Survives `ssh` exiting (Reconnect overlay).
- **Tiled view** (`Workspace/AppController+Tiling.swift`, `Panes/TileViews.swift`, grid math in
  `CmdsCore/TileLayout.swift`): `tileMode` (off / all visible sidebar rows / a chosen set) decides which workspaces
  `WorkspaceContentViewController` shows as `WorkspaceTileView`s in a `TileGridView`; the selected workspace is the
  active tile. Pane containers are re-parented, never recreated; `GhosttySurfaceView.viewDidMoveToWindow` re-reads
  size, scale, occlusion and whether it really is first responder. Divider ratios are kept per tiling set and grid
  shape; `session.json` stores `tiling` and `tileLayouts` (optional, by workspace index).
- **Attention / notification ring**: a pane lights up (colored ring border) when its program sends OSC 9/777,
  rings the bell, or `cmds notify` targets it — and the pane is not the focused pane of the key window.
  Focusing the pane clears it. The workspace row in the sidebar shows a dot + the latest notification text.
- Every terminal gets env `CMDS_SOCKET_PATH`, `CMDS_WORKSPACE_ID`, `CMDS_PANE_ID` so the CLI targets its own pane by
  default ([reference/environment.md](../reference/environment.md)).
- **Session restore** (`Workspace/SessionStore.swift`): `session.json` in the support directory keeps the workspaces
  with their split layout, per-pane cwd / URL / preview file / SSH host and remote cwd, the focused pane and the
  remembered agent sessions. Pane and workspace ids are not persisted; they are reassigned on launch. Terminal
  contents and running processes are not restored. **Export/import** (`AppController+Transfer.swift`,
  `CmdsCore/WorkspaceTransfer.swift`) writes the same information as a portable bundle
  ([reference/cli.md](../reference/cli.md#moving-workspaces-to-another-cmds)).

### Resource usage

Code: `Workspace/MetadataMonitor.swift`, `SystemSampler.swift`; math in `CmdsCore/ResourceSampling.swift`,
`ProcessAttribution.swift`.

- Every 2 s one background scan finds each workspace's processes and reads their listening ports and
  `proc_pid_rusage`.
- A process belongs to a workspace by (1) `CMDS_WORKSPACE_ID` in its environment with our `CMDS_SOCKET_PATH` — macOS
  hides the environment of Apple platform binaries (`/bin/zsh`, `make`, `git`), so this only covers third-party ones
  (node, python…); (2) its controlling tty, found from each pane's pty foreground process group
  (`TerminalSurface.foregroundProcessGroupID`); (3) its nearest attributed ancestor (detached children).
- Workspace CPU = growth of own + reaped-children CPU time (catches processes that start and exit between scans) over
  wall time, Activity Monitor style (100 % = one core, capped at all cores); memory = sum of `ri_phys_footprint`.
- Mac-wide: `host_statistics` CPU ticks (0–100 % of all cores); memory used = app (internal − purgeable) + wired +
  compressed pages (Activity Monitor's "Memory Used"); pressure = `kern.memorystatus_vm_pressure_level` (1 normal,
  2 warning, 4 critical).
- Updates go through `AppController.usageChanges`, not `changes`: only the usage labels redraw (no reloads, session
  saves or socket events).

### Agent usage

Code: `CmdsCore/AgentUsage.swift`, `AgentFormat.swift`, `ClaudeStatusLine.swift`, `CodexRollout.swift`; app:
`Workspace/CodexSessionWatcher.swift`, `AppController` "Agents". Per terminal pane an optional `AgentUsage`
(`PaneInfo.agent`) plus the latest account limits per agent kind (`AgentLimits`). Setup for users:
[guide/ai-agents.md](../guide/ai-agents.md#usage-and-limits).

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
- Session resume (`AppController+AgentSessions.swift`, `CmdsCore/AgentSession.swift`) remembers the session id per
  pane in `session.json`; behaviour: [guide/ai-agents.md](../guide/ai-agents.md#resuming-sessions).

## Keeping the Mac awake

What the user sees: [guide/workspaces-and-panes.md](../guide/workspaces-and-panes.md#keeping-the-mac-awake).

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

## Socket API and CLI

`App/Sources/API/APIServer.swift` maps JSON-lines requests on `cmds.sock` onto `AppController`; the `cmds` CLI
(`Packages/CmdsCore/Sources/cmds-cli`) is a thin client. Methods, events and types:
[reference/api.md](../reference/api.md); commands: [reference/cli.md](../reference/cli.md). SSH panes get a
restricted per-pane socket ([ssh.md](ssh.md)).

## iOS companion sync

The Mac runs a WebSocket server over TLS 1.3 (Network.framework) advertised as `_cmds._tcp`, presenting its own
self-signed certificate (ECDSA P-256 key in the login keychain). Pairing: "Pair iPhone/iPad…" shows a QR code with the
certificate fingerprint and a 6-digit code; the phone pins the fingerprint (from the QR code, or after the user compared
a short fingerprint) before it sends the code, and afterwards accepts only that certificate. Messages are JSON
(`CmdsCore/Sync`). The Mac pushes workspace snapshots and per-pane screen text (only changed panes, ~10 Hz); the phone
sends `input` (text/keys) and `select`/`focus` commands. The same TLS session can also run over Bluetooth LE or
through an SSH relay host. Protocol, pairing and threat model: [sync-protocol.md](sync-protocol.md).

## See also

- [ssh.md](ssh.md): SSH panes, the forwarded socket and its allowlist.
- [localization.md](localization.md): String Catalogs, language selection, what stays English.
- [testing.md](testing.md): unit tests, isolated instances, device tests.
- [release.md](release.md): versioning, signing, building a release.
