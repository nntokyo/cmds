# cmds architecture

Native macOS terminal multiplexer for coding agents. Swift + AppKit, terminal rendering via libghostty
(GhosttyKit.xcframework built from `vendor/ghostty`). GPL-3.0.

## Layout

| Path | Contents |
|---|---|
| `Packages/CmdsCore` | SwiftPM package shared by macOS app, CLI and iOS: RPC wire types, snapshot models, sync protocol. Also the `cmds` CLI executable (`Sources/cmds-cli`). |
| `App/Sources/Terminal` | `TerminalSurface.swift` (contract) + `Ghostty/` (libghostty implementation). |
| `App/Sources/Workspace` | Workspace/pane model, split tree, `AppController` (single source of truth, main actor). |
| `App/Sources/Sidebar` | Vertical tabs: title, git branch, cwd, listening ports, CPU/memory, latest notification text, attention dot. Footer: Mac-wide CPU and memory meters. |
| `App/Sources/Panes` | Split container views, pane container with notification ring. |
| `App/Sources/Browser` | WKWebView browser pane. |
| `App/Sources/Shortcuts` | Main menu + key equivalents. |
| `App/Sources/API` | Unix-socket JSON-lines server dispatching to `AppController`. |
| `App/Sources/Sync` | Companion server (Bonjour `_cmds._tcp`, WebSocket) for the iOS app. |
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

## Socket API (JSON lines, see `CmdsCore/RPC.swift`)

Socket: `~/Library/Application Support/cmds/cmds.sock` (mode 0600).

| Method | Params | Result |
|---|---|---|
| `system.ping` | – | `{"pong": true}` |
| `system.identify` | – | `{"version", "build", "pid", "socketPath", "cliPath"}` |
| `system.stats` | – | `{"system": SystemStats, "workspaces": [{"id", "cpuPercent", "memoryBytes"}]}` (`system` is omitted until two samples exist, ~1 s after launch; workspace fields until sampled or without processes) |
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
- `CMDS_SYNC_DISABLED=1` skips the iOS sync server (no Bonjour advert, no port).
- Launch the binary directly; `open` does not pass the environment reliably.

## iOS companion sync

Mac runs a WebSocket server (Network.framework) advertised as `_cmds._tcp`. Pairing: the Mac shows a 6-digit code;
the phone sends it in `hello`. Messages are JSON (`CmdsCore/Sync`). The Mac pushes workspace snapshots and per-pane
screen text (only changed panes, ~10 Hz); the phone sends `input` (text/keys) and `select`/`focus` commands.
