# Architecture

> How the code is organised: targets, packages, the main concepts and how the pieces fit together.

cmds is a native macOS terminal workspace for coding agents. Swift + AppKit, terminal rendering via libghostty
(GhosttyKit.xcframework built from `vendor/ghostty`), an iOS/iPadOS companion in SwiftUI. GPL-3.0.

## Repository layout

| Path | Contents |
|---|---|
| `Packages/CmdsCore` | SwiftPM package shared by the macOS app, the CLI and iOS: RPC wire types, snapshot models, sync protocol, agent usage parsing, preview renderers, keep-awake logic, workspace export bundles. Also the `cmds` CLI executable (`Sources/cmds-cli`) and the unit tests (`CmdsCoreTests`, `CmdsCLITests`). |
| `Packages/CmdsSSH` | SSH client for the companion's remote access (swift-nio-ssh); only the iOS app links it, so the Mac app and CLI do not pull in SwiftNIO. `Scripts/test-relay-sshd.sh` runs a throwaway sshd for its tests. |
| `App/Sources/App` | App delegate, main window, language menu (`AppLanguage`), keep-awake (`KeepAwake.swift`), settings (`AppSettings`: UserDefaults, own suite for isolated instances; `SettingsWindowController`; the terminal font is a Ghostty config override loaded from a temporary file and pushed with `ghostty_app_update_config`), localized texts for core errors. |
| `App/Sources/Terminal` | `TerminalSurface.swift` (contract) + `Ghostty/` (libghostty implementation, plus a standalone debug harness). |
| `App/Sources/Workspace` | Workspace/pane model (the split tree itself is `CmdsCore/SplitTree.swift`), `AppController` (single source of truth, main actor), session store, export/import, SSH sessions, metadata/CPU sampling, Codex session watcher. |
| `App/Sources/Sidebar` | Vertical tabs: title, git branch, cwd, listening ports, coding agent (model, context, cost, 5-hour limit), CPU/memory, latest notification text, attention dot. Footer: account limits per agent (Claude, Codex) and Mac-wide CPU and memory meters. Compact rail variant. |
| `App/Sources/Panes` | Split container views, pane container with notification ring, SSH connect sheet and overlay, agent resume banner. |
| `App/Sources/Browser` | WKWebView browser pane. |
| `App/Sources/Preview` | File preview pane (`PreviewPane`: header, Quick Look / image view / rendered HTML, file watcher). Renderers in `CmdsCore/Preview` (`MarkdownHTML`, `DiffHTML`, `PreviewHTML`). |
| `App/Sources/Files` | Files pane (`FilesPane`: bar, list, footer; `+Table` cells, sorting, rename, drag and drop; `+Actions` commands, copy/move, conflicts; `+Remote` folders on SSH hosts; `GitStatusReader`), `RemoteConnections` (one SFTP connection per host), `TransferCenter` (the transfer queue, `transfer.*`) and the Transfers window. Logic in `CmdsCore/Files` (`FileSorting`, `FileNames`, `FileSelection`, `ShellQuoting`, `GitStatus`, `FileOperation`, `CommandOutput` for running git; `FileLocation`, `SFTPPacket`/`SFTPClient`, `SSHFileConnection`, `FileTree`, `RemoteTrash`, `TransferJob`/`TransferQueue`; [files-sftp.md](files-sftp.md)). |
| `App/Sources/Schedule` | Schedules: `ScheduleRunner` (owned by `AppController`; files, timers, runs, the 1-minute notice), the Schedules window and editor sheet, `ScheduleAPI` (`schedule.*`), pane tags, the limit banner's Continue at, UI text. Rules in `CmdsCore` (`Schedule`, `ScheduleStore`, `ScheduleCalendar`, `ScheduleRunTiming`, `ScheduleTarget`). |
| `Widget/Sources` | The cmds widget (#96, WidgetKit extension `CmdsWidget`, embedded at `cmds.app/Contents/PlugIns/CmdsWidget.appex`). It reads `widget.json` (CmdsCore `WidgetSnapshot`), which `WidgetPublisher` in the app writes to the support folder; the extension is sandboxed with a read-only exception for that one file (`Widget/CmdsWidget.entitlements`, resolved from the real home, not the sandbox container). The menu bar item and the widget share `AgentOverview`. Clicks open `cmds://workspace/<id>`. |
| `App/Sources/Assistant` | The voice assistant (#243, macOS 26+): `AssistantController` (ties it together), `AssistantListener` (microphone → SpeechAnalyzer), `AssistantVoice` (AVSpeechSynthesizer), `AssistantBrain` (Foundation Models, `claude -p`; the process: `AssistantClaudeProcess`), `AssistantTuning` (timings and caps), `AssistantHUD` / `AssistantOrbView` (the panel), `AssistantIdleOrb` (the orb while waiting), `AssistantHotkeys` (Carbon hot keys), Settings › Assistant, `debug.assistant`. Rules in `CmdsCore/Assistant`. |
| `App/Sources/Shortcuts` | Main menu + key equivalents (`MainMenu`), menu actions (`CommandRouter`). |
| `App/Sources/API` | Unix-socket JSON-lines server dispatching to `AppController`; the bundled CLI and its installer. |
| `App/Sources/Sync` | Companion server (Bonjour `_cmds._tcp`, WebSocket over TLS, keychain sync identity, pairing window, Bluetooth L2CAP relay, remote access via SSH) for the iOS app. |
| `App/Resources`, `iOS/Resources` | Asset catalogs (app icons) and String Catalogs (`Localizable.xcstrings`, `InfoPlist.xcstrings`). |
| `Shared/Sources` | Localized UI text for CmdsCore values, compiled into both apps. |
| `iOS/Sources` | SwiftUI iOS/iPadOS companion (`Connection/` transports and client, `Views/`, `Support/`). |
| `iOS/UITests` | `CmdsDeviceDriver` UI test target: `DeviceDriverTests` (scripted driver) and `TerminalScreenTests`. |
| `integrations/claude` | Skill for Claude Code and Codex working inside cmds. |
| `design/icon` | App icon artwork and the scripts that generate every icon size ([README](../../design/icon/README.md)). |
| `scripts` | `build-ghostty.sh` (GhosttyKit with cmds' libghostty patches), `l10n-sync.sh` (String Catalog sync), `check-links.py` (Markdown link check). |
| `vendor/ghostty` | Ghostty source (submodule, pinned upstream revision). `vendor/GhosttyKit.xcframework` is a symlink/copy of `vendor/ghostty/macos/GhosttyKit.xcframework` (ignored); build steps in the [README](../../README.md#build-from-source). |
| `vendor/ghostty-patches` | cmds' patches on libghostty (exact screen points above the viewport, `ghostty_surface_scrollbar` with the rows pruned from the scrollback), applied for the build only by `scripts/build-ghostty.sh`. |

The Xcode project is generated from `project.yml` with `xcodegen generate` (do not commit `cmds.xcodeproj`).
Targets: `cmds` (Mac app; scheme `CmdsApp`), `cmds-cli` (the CLI, embedded at `cmds.app/Contents/Resources/bin/cmds`),
`CmdsWidget` (the widget extension, embedded in `cmds`), `CmdsCompanion` (iOS app; scheme `CmdsCompanion`),
`CmdsDeviceDriver` (iOS UI tests; scheme `CmdsDeviceDriver`).

## Key concepts

- **Workspace** = one vertical tab. Holds a split tree of panes. Each workspace has a primary working directory.
- **Pane** = terminal (`TerminalSurface`), browser (`WKWebView`), preview (a local file) or files (a local folder). IDs are short strings (e.g. `p1`, `w1`), stable while the app runs and reassigned on launch.
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
- **Browser DevTools** (`Browser/BrowserPane+DevTools.swift`; buffer, parsing and page scripts in
  `CmdsCore/BrowserDevTools.swift`; #167): two user scripts per pane at document start, main frame only. The console
  hook must run in the page world (only there are the page's `console` functions); it wraps `console.*`, listens for
  `error` and `unhandledrejection`, and hands each record over as a `CustomEvent` with a JSON string detail on
  `document`, named `cmds-console-<uuid>` per web view and dispatched with references taken before any page script
  runs. The listener in the `.defaultClient` world batches them (100 ms, at most 200 a second) to the `cmdsConsole`
  handler, which exists only in that world, into a `ConsoleBuffer` (1000 entries). Tree, click, fill and wait_for are
  `callAsyncJavaScript` bodies in `.defaultClient`; refs live in that world's `window.__cmdsRefs` (`WeakRef`s), so
  the page never sees them and the DOM is not changed. User scripts and `callAsyncJavaScript` are compiled by WebKit,
  so a page's CSP does not apply (as for `browser.eval`'s fallback, #88). The responsive view no longer removes all
  user scripts on close (that would drop the console capture); its scroll script stays and posts nothing without its
  handler. `isInspectable` follows Settings (`BrowserInspectable`).
- **Responsive view** (`Browser/ResponsiveView.swift`, `BrowserPane+Responsive.swift`; settings, requests and scroll
  math in `CmdsCore/BrowserResponsive.swift`; #170): still a `browser` pane (no new `PaneKind`, no sync protocol
  change: the iPhone shows the first frame's URL). The pane's own `WKWebView` becomes the first frame; the others are
  web views sharing its website data store, each its own WebContent process, removed in `close()` (view off, pane
  closed). All frames are laid out at their device size in one `ViewportHostView` scaled by a common factor (labels
  above, unscaled). Navigation: a frame's URL change (KVO, so link clicks, form posts, history and `pushState` alike)
  is loaded in the others unless that frame is still loading, or settling for a second after, a URL the view gave it
  (keeps per-UA redirects from bouncing). Scrolling: `ResponsiveScroll.frameScript` in the `.defaultClient` world
  posts the scroll fraction of the scrollable height to the `cmdsResponsiveScroll` handler (a timer, not
  `requestAnimationFrame`, which WebKit pauses in covered windows); the others scroll to the same fraction via
  `__cmdsScrollTo`, whose own scroll event is ignored for 150 ms. A `FileWatcher` reloads every frame when a
  `file://` page changes. Saved as `browser.responsive` in session.json and `responsive` in bundles (optional keys).
- **Reload on file changes** (`Browser/BrowserPane+Watch.swift`; settings, ignore rules, local-page test, request and
  debounce in `CmdsCore/BrowserWatch.swift`; [guide](../guide/workspaces-and-panes.md#reload-on-file-changes), #252):
  a `DirectoryWatcher` is an FSEvents stream on the folder (file-level events, 0.1 s latency, main queue), not the
  vnode `FileWatcher` of preview panes (one file only). It runs only while the `BrowserPane` is in a window
  (`viewDidMoveToWindow`: a hidden workspace's panes have none) and its page passes `BrowserWatch.reloads` (re-checked
  on every URL change); when it stops because the pane left the window it keeps `FSEventsGetCurrentEventId()`, and the
  next stream starts `since` that id, so what changed meanwhile is replayed (one reload); stopping for a page that does
  not reload keeps nothing. Paths are filtered by `BrowserWatch.isIgnored` (the `file://` page's own folder
  is exempt from the folder rules) and a `WatchDebounce` (0.3 s trailing, 2 s ceiling) schedules `reload()` (all
  frames in the responsive view). Not saved in session.json or bundles; no sync protocol change.
- **Browser screenshots** (`Browser/BrowserPane+Snapshot.swift`, params and answer in `CmdsCore/BrowserSnapshot.swift`;
  #169): the visible page is `takeSnapshot`. `takeSnapshot` paints only what is on screen (a rect below the fold comes
  out blank), so a full page or an element is WebKit's PDF of the view (`pdf(configuration:)`; no rect = the whole
  document, a rect is in document coordinates whatever the scroll position) drawn into an sRGB bitmap on white. Page
  metrics (viewport, scroll, document height, the element's rect) are read in the `.defaultClient` world. Other
  sizes: a `CaptureWebView` (a `WKWebView` sharing the pane's configuration, so its website data, in a
  `RenderOnlyWindow` outside the screen) loads the pane's URL, waits for `didFinish` (30 s limit) and 600 ms, is
  captured the same way and closed; one at a time, at most 4. Unknown params are refused, and the answer's `images`
  tells clients the app knows the new params (an older app ignores them and returns only `png_base64`).
- **Browser pop-ups, dialogs and downloads** (`Browser/BrowserPageDelegate.swift`, `BrowserPopupWindow.swift`,
  `BrowserDownloads.swift`; decisions, sizes and names in `CmdsCore/BrowserWindows.swift`;
  [guide](../guide/workspaces-and-panes.md#pop-ups-dialogs-and-downloads), #235): one `BrowserPageDelegate` per pane
  is the UI and navigation delegate of the pane's web view, the responsive view's other frames and the pane's
  pop-ups. `createWebViewWith` (`BrowserNewWindow.decide`): a link activation without window features to a web page
  opens a browser split beside the pane (`AppController.openBrowser`, focused only when the pane is the focused one;
  `_blank` links have no opener in WebKit anyway), else the same pane; anything else (`window.open`, with or without
  features, forms) is a `BrowserPopupWindow` whose `WKWebView` is made from the configuration WebKit passes (so
  `window.opener` / `postMessage` work; it shares the pane's content controller, so the console hook runs there too),
  sized by `BrowserPopupSize`, centred over the opener's window, `.fullScreenAuxiliary`, ⌘W handled by the window
  (the menu's Close Pane has an explicit target). Pop-ups from a web view that is not in a visible window (hidden
  workspace, `RenderOnlyWindow` during a snapshot) are refused. Alert / confirm / prompt and the open panel are sheets
  on the asking web view's window, titled with the frame's origin (`BrowserDialogOrigin`); without a visible window, or
  for a responsive frame that is loading a URL another frame navigated to (`ResponsiveView.isFollowing`), they get the
  no-UI answers (OK, false, nil). Every pending completion handler is answered in `tearDown()` (WebKit raises for
  dropped ones) before the pop-ups close. Downloads: `shouldPerformDownload`, a response WebKit cannot show or a
  `Content-Disposition: attachment` become `WKDownload`s owned by `BrowserDownloads.shared` (they outlive the pane),
  saved to ~/Downloads under `BrowserDownloadName.unique` (`name 2.ext`); WebKit sets `com.apple.quarantine`. The
  notice is a `BrowserDownloadBannerView` at the bottom of the pane (the container's top banner would cover the
  address bar). The snapshot `CaptureWebView` has no UI delegate: no windows, dialogs answered by WebKit, downloads
  fail the capture.
- **Browser pane device sizes** (`Browser/BrowserPane+Device.swift`, presets and settings in
  `CmdsCore/BrowserDevice.swift`; [guide](../guide/workspaces-and-panes.md#device-sizes-and-color-scheme), #168): the
  `WKWebView` sits in a `ViewportHostView` below the toolbar. Filling the pane, it takes the host's bounds and the page
  zoom. With a device size it gets exactly that size in points and page zoom 1, and the host's bounds are scaled
  (`setBoundsSize`) so it fits the pane: the page's CSS viewport is the device's and `devicePixelRatio` stays the
  Mac's. (Fitting with page zoom instead was tried: WebKit then rounds the layout width, 1918 for 1920, and scales
  `devicePixelRatio`.) `prefers-color-scheme` follows the web view's `appearance` (aqua / darkAqua; the system choice
  is `NSApp.effectiveAppearance`, as the main window is always dark); the user agent is `customUserAgent`, and a
  change reloads the page. WKWebView has no public setting for reduced motion, the pixel ratio, touch or
  `<meta viewport>`. The breakpoint indicator runs `Breakpoints.pageScript` in the `.defaultClient` content world
  (the page cannot see it) after loads, resizes and changes, and `Breakpoints.thresholds` turns the media queries of
  readable style sheets into width thresholds. `DevicePreset` (ids, CSS sizes, user agents, `responsiveSet`) is meant
  for the screenshot (#169) and responsive-view (#170) work too. Settings are `BrowserEmulation`, saved in
  session.json (`browser.emulation`) and export bundles (`emulation`), both optional keys. The iPhone is not told
  (no sync protocol change): it keeps loading the pane's URL at its own size.
- **Files pane** (`PaneKind.files`, `PaneInfo.workingDirectory` = the folder; [guide](../guide/files.md)): the
  folder is read on a background queue (`FileEntry` per item, sorted by `FileSorting`) and watched with the same
  vnode `FileWatcher` as preview panes (re-listed at most every 0.5 s). Git states come from
  `git --no-optional-locks status --porcelain=v1 -z -- .` (only below a `.git`, 4 s limit, parsed by `GitStatus`).
  Copies and moves are a `FileOperation` on its own thread: `copyfile(3)` recursive with a progress callback that
  also cancels (the partial item is removed), renames within a volume, copy + Trash across volumes; a taken name
  asks the main thread (semaphore) for skip / replace (Trash) / keep both (`FileNames.keepBoth`). Nothing is ever
  deleted for good. "The other pane" is the workspace's other files pane focused most recently (`Pane.focusedAt`).
  Follow Terminal follows the workspace's local terminal pane focused most recently (`followedTerminal`), on its
  OSC 7 changes and when it takes focus. Session restore keeps the folder, hidden files and Follow Terminal.
  A files pane with a `host` lists a folder on an SSH host over SFTP through the user's `ssh`; copies and moves that
  touch a host go through the transfer queue ([files-sftp.md](files-sftp.md)). Restored remote panes wait for
  Connect; the workspace's location never follows a files pane.
- **SSH pane** ([ssh.md](ssh.md)): a terminal running the user's `ssh` with the pane's own restricted API socket
  forwarded to the server (`ssh -R`); `PaneInfo.remote` = `{host, connected, branch?}`, `WorkspaceInfo.remoteHost`
  while the focused pane is one (its cwd/branch are then remote). Survives `ssh` exiting (Reconnect overlay).
- **Scrollback export** (`AppController.exportScrollback`, `CommandRouter.exportScrollback`; chunking, path checks and
  the file in `CmdsCore/ScrollbackExport.swift`; [guide](../guide/workspaces-and-panes.md#exporting-the-scrollback),
  #253): `TerminalSurface.screenText(rows, ansi:)` reads screen rows as one non-rectangular selection
  (`ghostty_surface_read_text` / cmds' `ghostty_surface_read_text_vt`; exact screen points reach the whole history
  with the patch), which joins soft-wrapped rows. `ScrollbackExport.Job` reads 2000 rows per step, numbered absolutely
  (screen row + `TerminalScrollbar.pruned`), so rows pruned during the export are counted as `lost` instead of shifting
  the read; a step ends where a two-row probe shows a line ending on a non-blank row (no soft wrap, nothing trimmed at
  the edges), searching up to 200 rows past the chunk. The main actor yields between steps. `PrivateFileWriter` writes
  a temporary `.<name>.cmds-…` file beside the target (`O_EXCL | O_NOFOLLOW`, `fchmod 0600`) and renames it into place
  at the end (`renamex_np(RENAME_EXCL)` without force), so the target never sees a partial or world-readable file and
  a symlink there is replaced, not followed. Not in `RemoteAPIPolicy.allowedMethods`.
- **Tiled view** (`Workspace/AppController+Tiling.swift`, `Panes/TileViews.swift`, grid math in
  `CmdsCore/TileLayout.swift`): `tileMode` (off / all visible sidebar rows / a chosen set) decides which workspaces
  `WorkspaceContentViewController` shows as `WorkspaceTileView`s in a `TileGridView`; the selected workspace is the
  active tile. Pane containers are re-parented, never recreated; `GhosttySurfaceView.viewDidMoveToWindow` re-reads
  size, scale, occlusion and whether it really is first responder. Divider ratios are kept per tiling set and grid
  shape; `session.json` stores `tiling` and `tileLayouts` (optional, by workspace index).
- **Moving panes** (`Workspace/AppController+PaneMove.swift`, tree operations and `pane.move` params in
  `CmdsCore/SplitTree.swift` / `PaneMove.swift`, the grip in `Panes/PaneDragHandle.swift`; #218): a move takes the leaf
  out of one tree (its sibling takes the parent's place) and splits the target leaf evenly on a side; a swap exchanges
  two leaves' ids. The `Pane` object moves between the workspaces' `panes` and its `workspaceID` changes; nothing is
  recreated, the containers are re-parented on the next render like tiles. An SSH pane's scoped socket is re-pinned to
  the new workspace. Processes keep their `CMDS_WORKSPACE_ID`: the metadata scan maps a process's pane to the pane's
  workspace now (`ProcessOrigins.Origin.following`), and the CLI / `cmds mcp` look up their pane's workspace. Drags
  carry the pane id (`.cmdsPane`): the content view hit-tests panes (`TileDropZone` → `PaneSide`, centre = swap),
  the sidebar takes drops on rows, and the grip moves the pane into a new workspace when the drag ends outside the
  window without Esc.
- **Attention / notification ring**: a pane lights up (colored ring border) when its program sends OSC 9/777,
  rings the bell, or `cmds notify` targets it — and the pane is not the focused pane of the key window.
  Focusing the pane clears it. The workspace row in the sidebar shows a dot + the latest notification text.
- Every terminal gets env `CMDS_SOCKET_PATH`, `CMDS_WORKSPACE_ID`, `CMDS_PANE_ID` so the CLI targets its own pane by
  default ([reference/environment.md](../reference/environment.md)).
- **Session restore** (`Workspace/SessionStore.swift`): `session.json` in the support directory keeps the workspaces
  with their split layout, per-pane cwd / URL / preview file / SSH host and remote cwd, the focused pane and the
  remembered agent sessions; `agent-history.json` next to it the recent agent sessions of all panes
  (`CmdsCore/AgentSessionHistory.swift`, `AppController+AgentHistory.swift`). Pane and workspace ids are not persisted; they are reassigned on launch. Terminal
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
- Codex account limits (#227): `token_count` events whose windows are null keep the known ones; a `task_complete`
  / `error` event with `codex_error_info: usage_limit_exceeded` (lines found by that marker) sets
  `Snapshot.limitReached` with the reset parsed from the message (`CodexRollout.limitReset`, local time) and is
  cleared by a later event with figures. `accountLimits` turns it into the matching window at 100 % (reset within
  15 min) or an extra `UsageLimit.usageLimit` at 100 % (no reset: dropped by `active(at:)` 24 h after `updatedAt`).
  Besides the panes' files the watcher follows, for limits only, the 4 newest rollout files of today's and
  yesterday's folders under `$CODEX_HOME/sessions` (else `~/.codex/sessions`) modified within 6 h (folders listed
  every 15 s, ≤ 64 KB tail). The newest limits are saved in `codex-limits.json` (`CodexLimitsStore`, support
  folder) when the figures change and restored at launch.
- Usage without updates for 3 min is marked `stale` (idle agent, dimmed). Limits whose `resetsAt` passed are left
  out. Report-driven updates go through `usageChanges` (coalesced to 4/s); only appearing/disappearing agents emit
  `pane` changes (row height).
- Session resume (`AppController+AgentSessions.swift`, `CmdsCore/AgentSession.swift`) remembers the session id per
  pane in `session.json`; behaviour: [guide/ai-agents.md](../guide/ai-agents.md#resuming-sessions).
- **Typing into panes by itself** (a resume command, an account switch's Ctrl-C, a schedule run): one readiness check.
  `Workspace/PaneInput.swift` looks at the pane (`PaneProcessProbe` for the foreground process of a local terminal,
  read 0.8 s after it starts; agent activity, subagents, the screen through `ScreenStability`) and builds a
  `PaneObservation`; the rules are `CmdsCore/PaneReadiness.swift` (unit-tested): shell input only at a settled empty
  prompt (0.4 s; SSH panes 1.5 s unless the remote shell reported its prompt), agent input only when it is idle
  (`ClaudeAccountSwitchTiming.isIdle`).

### Claude accounts

Code: `CmdsCore/ClaudeAccount.swift` (accounts, rules, `claude-accounts.json`), `ClaudeLimitDetector.swift`,
`ClaudeSessionSharing.swift`, `ClaudeAccountSwitchTiming.swift` (when a switch quits Claude Code); app:
`Workspace/AppController+Accounts.swift` (accounts, a pane's account, limits), `Workspace/AppController+AccountSwitch.swift`
(offer, switch, banner) with `Workspace/AccountSwitch.swift`, `App/ClaudeAccountsWindowController.swift`,
`Panes/AccountSwitchBannerView.swift`; CLI `cmds-cli/AccountCommands.swift`. Behaviour: [guide/ai-agents.md](../guide/ai-agents.md#several-claude-accounts).

- **Store**: `ClaudeAccountSettings` (accounts in order with their last limit, `autoSwitch`) in
  `<support dir>/claude-accounts.json`, so an isolated instance has its own. Names and paths only. Loaded through
  `StoredFile`: a damaged file is moved aside (`claude-accounts.json.corrupt-<time>`, kept) and reported; one that
  cannot be read stays in place and is not saved over.
- **A pane's account** (`Pane.claudeAccount`, saved as `paneAccounts` per workspace in `session.json`): set when the
  pane is created with one (its environment gets `CLAUDE_CONFIG_DIR`), by a switch, or from the `configDir` that
  `cmds hook claude-status` sends with `agent.report` (the hook's own `CLAUDE_CONFIG_DIR`, inherited from Claude
  Code; dropped on SSH panes' sockets). A remembered Claude Code session carries `account` and `configDir`
  (`AgentSession`), so `AgentResume.command` resumes it with `env CLAUDE_CONFIG_DIR='<dir>' claude --resume <id>`.
- **Limits**: the metadata scan (2 s) calls `scanClaudeLimits`: the visible text of local panes running Claude Code
  goes through `ClaudeLimitDetector.detect` (last 40 lines, a line must start with a limit message); `agent.report`
  checks the status-line windows (`hit(fromLimits:)`). Without a reset time a limit lasts 5 h (usage,
  `ClaudeLimitDetector.sessionWindow`) or 15 min (rate, `rateLimitWait`). A hit is handled once per pane and line for 5 h
  (`Pane.seenLimitLines`, because a resumed session can show the old line again), merged into the account's limit
  (`ClaudeAccounts.merge`) and saved.
- **Switch** (`Pane.accountSwitch`, `AccountSwitch.Phase`): `offered(problem?)` → `waitingForIdle` → `quitting` →
  handed to the resume machinery (`resumeOffer` + `resumeRequestedAt`). A 0.3 s timer runs while a switch is in
  progress; the rules are `ClaudeAccountSwitchTiming` (unit-tested): idle (`PaneReadiness.isAgentIdle`) = Claude Code
  is the foreground process (`PaneProcessProbe`), activity not busy, no running subagent, screen unchanged for 2 s; then two Ctrl-Cs (`\u{3}\u{3}`)
  in one `sendText` (Claude Code quits only on a second Ctrl-C within about 0.7 s, too tight for the timer), again every 2.5 s up to three times, giving up 5 s after the last; once the shell is the foreground process with no agent on the tty, the pane's usage is dropped and the
  session is queued under the new account. The banner shares the pane's bar with the resume banner and wins.
- **Sharing**: `ClaudeSessionSharing.plan/apply` (unit-tested on temporary folders): the store is the first account
  whose folder exists, its `projects` with symlinks resolved (after reordering, the real folder a linked account points
  to; its owner counts as shared and is never moved aside); others get `projects` → store as a symlink, an own
  `projects` folder renamed `projects.before-cmds-<yyyyMMdd-HHmm>` first; a rename whose target exists fails, and a
  link that cannot be made after the rename moves the folder back. `transcriptReachable` checks
  `<dir>/projects/*/<id>.jsonl` by name before a switch.

### Schedules

Code: `CmdsCore/Schedule.swift` (model, file format), `ScheduleValidation.swift`, `ScheduleStore.swift` (`schedules.json` /
`schedule-runs.json`, history retention, API results), `ScheduleCalendar.swift` (next firing, `ScheduleCatchUp`),
`ScheduleRunTiming.swift` (when a run may type), `ScheduleTarget.swift` (`sendText` targets), `ScheduleNotice.swift`;
app: `Schedule/ScheduleRunner.swift` (+`Runs`, one file per action: +`ContinueSession`, +`SendText`; +`Notice`),
`PaneTags.swift`, `ScheduleAPI.swift`,
`SchedulesWindowController.swift`, `ScheduleEditorController.swift`, `ContinueAtReset.swift`, `ScheduleText.swift`;
CLI `cmds-cli/ScheduleCommands.swift`. Behaviour: [guide/schedules.md](../guide/schedules.md); design: issue #45.

- **Store**: `<support dir>/schedules.json` and `schedule-runs.json`, loaded through `StoredFile` (a damaged file is
  moved aside, never overwritten; a read error or a `version` above `ScheduleFile.currentVersion` makes the runner read
  only), written atomically with mode 600. Decoding is lenient: a schedule that fails to decode or validate is
  dropped, not the file. The version written is the lowest that runs every schedule (`Schedule.requiredVersion`):
  1 for phase-1 schedules, 2 once one uses `sendText`, Codex, `codexLimitReset` or `repeats`, so an older cmds opens
  such a file read only instead of running a repeating trigger once or dropping what it cannot decode.
  `schedule-runs.json` stays at version 1 (unknown reason codes decode as `other`).
- **Pane tags**: a `sendText` target or a `continueSession` pane given as a pane id becomes that pane's
  `Pane.scheduleTag` (`t` + 8 hex; `ScheduleRunner.storingPaneTags`), saved per workspace as `paneTags` in
  `session.json` and restored (duplicates dropped, `ScheduleTarget.uniqueTags`); a run resolves the tag, or a workspace
  title, with `ScheduleTarget.resolve` and is skipped when no pane or several match. A `continueSession` tag only
  breaks a tie between panes holding the session (`ContinueSession.paneTag`); pane ids saved by cmds 0.6 are dropped
  when `schedules.json` is read.
- **Firing**: one `Timer` (`.common` mode, 1 s tolerance) for the earliest `nextFireAt`, re-armed on every change, on
  `NSWorkspace.didWakeNotification`, clock / zone / day changes and account or Codex limit changes (limit triggers
  follow `ScheduleCalendar.recomputed`: a one-shot moves with the limit, a repeating one fires for a reset after
  `lastDueAt`, unknown Codex limits keep the stored time), plus a 60 s safety check while anything is enabled. A second
  timer shows the "starts in 1 minute" notice (`ScheduleNotice`, once per firing time) whose Skip calls
  `ScheduleRunner.skip(id:dueAt:)`. `ScheduleCatchUp.decide` turns a due time into
  one on-time or catch-up run, or a missed entry; then `nextFireAt` moves on from now (one-shots are disabled).
  DEBUG builds move the runner's clock with `debug.schedule_clock`.
- **Runs** (`ActiveScheduleRun`): `waitingForAccount` → (`begin`: create the background workspace with
  `createWorkspace(select: false)`, find the pane holding the session id, or resolve a `sendText` target) →
  `waitingForPane` (shell stage: the
  command or `AgentResume.command`) → `waitingForAgent` → paste (`sendText`, bracketed) → `typing` → Return →
  `confirming` → ended. A 0.3 s tick builds a `ScheduleRunTiming.Observation` of the pane (the `PaneObservation` of
  "Typing into panes by itself" above, plus the agent kind of the foreground process, the reported session id,
  account switch, queued resume, a numbered choice or a working line on screen) and does what
  `ScheduleRunTiming.step` says. Claude Code is idle by `PaneReadiness.isAgentIdle`; Codex, which has no hooks in
  cmds, only by the stricter `PaneReadiness.isCodexIdle` (its session file matched and quiet for 90 s, the screen
  unchanged for 5 s, no `esc to interrupt` in the bottom lines). Each typing step moves the
  run on, so nothing is typed twice. Ended runs go to the history (50 per schedule, 300 in all, 90 days).
- **Events**: `ScheduleRunner.changes` (separate from `AppController.changes`) → socket events `schedule.changed`,
  `schedule.run`. `schedule.*` is not in `RemoteAPIPolicy.allowedMethods`.
- **Logging**: `Logger` category `schedule` with ids, states and reason codes only; prompts and commands never.

## Voice assistant

What the user sees: [guide/assistant.md](../guide/assistant.md). Code: `App/Sources/Assistant`; rules (unit-tested)
in `CmdsCore/Assistant` and `CmdsCore/PaidFeatures.swift`.

- **Availability**: `#available(macOS 26.0, *)` around everything (`AssistantController.start` in `AppDelegate`, the
  Settings tab, the menu bar items, `debug.assistant`); `Speech` and `FoundationModels` are weakly linked, so cmds
  still launches on macOS 14. `PaidFeatures.isUnlocked(.assistant)` gates it: unlocked while the feature is in
  `PaidFeatures.betaFree` (now), in Debug builds (`developmentBuild`, set under `#if DEBUG`) or by the licence
  provider (`NoLicenceProvider` until the subscription, #244). No environment variable or default unlocks anything.
- **Listening**: `AssistantListener` taps `AVAudioEngine`'s input, converts to
  `SpeechAnalyzer.bestAvailableAudioFormat` on the audio thread (`AudioPump`, created outside the main actor) and
  feeds a `SpeechTranscriber` for the app's language (`AssistantLanguage`: ja_JP / en_US), downloading its asset once.
  Only final results leave it, as text. Nothing is written; partial results only drive the level. The end of an
  utterance (#248): `SpeechTranscriber` finalises Japanese only 7–10 s after the speech (English about 2 s), so
  `AssistantEndpoint` (CmdsCore) watches the level of every tap buffer (about 43 ms): at least 0.3 s of speech, then
  0.8 s quiet, and `SpeechAnalyzer.finalize(through: nil)` makes the final result come about 1 s after the speech.
  Speech is relative to the room (#270): the noise floor follows the level in decibels (down within 0.25 s, up within
  3 s), speech begins at 2× the floor (and at least `AssistantPresence.Hearing.onLevel`) for two buffers in a row (a
  clink or a knock is shorter) and goes on above 1.5×; when the noise is as loud as the voice, or is speech itself
  close by, the level never drops and the recogniser's own end counts, as before. A final of punctuation only
  (finalised noise) is dropped. Its `fastResults` option was tried and rejected: it gives early volatile results but a
  worse final transcript (「APIの」 → 「AP来の」), so partial transcripts are not used to route early. Speech beginning
  (`onSpeech`) warms the on-device model up (`AssistantBrain.prewarm`, at most every 30 s).
- **Loud places** (#270): `AssistantListening` (Settings › Assistant › Listening). `noiseReduction` and `pushToTalk`
  turn on `AVAudioInputNode.setVoiceProcessingEnabled` (noise suppression, echo cancellation, AGC) before the engine
  starts, with other apps' audio not ducked (`voiceProcessingOtherAudioDuckingConfiguration` `.min`); its input may
  have several channels, so `AudioPump`'s converter mixes them down. Push to talk: Carbon's hot key released event
  (`AssistantHotkeys.onRelease`); the engine runs but `AudioPump` holds audio back while the key is up (keeping the last
  0.3 s, `AssistantListening.preRoll`, for the first syllable), 0.2 s after the release it finalises (audio still going in
  until the result: cut at once, short requests in noise came back empty), and the
  finals since the press go out as one utterance with `AssistantHeard.pushed` (for the assistant without the name, also
  after the follow-up window, and replacing a card like a request by name). `AssistantHeard.noisy` (the endpoint's
  floor ≥ 0.08) makes `AssistantAddressing` drop a name the recogniser is unsure of (`transcriptionConfidence` of its
  characters < 0.5); follow-ups without the name are as in a quiet room (the hotkey's window must take a long command).
  Engine restarts are limited to 5 in 10 s. The microphone:
  `AssistantInputDevice.choose` (Settings › Assistant › Microphone: automatic = a Bluetooth or headset-named input when
  connected, else the system's; system default; a device UID, automatic while it is unplugged) over
  `AssistantAudioDevices.inputs()` (Core Audio, no permission), set on the input node's unit
  (`kAudioOutputUnitProperty_CurrentDevice`) before the engine starts. Device list and default input changes
  (`AudioObjectAddPropertyListenerBlock`) and `AVAudioEngineConfigurationChange` restart only the engine
  (`restartInput`): a new pump into the same analyzer, its fed seconds carried on.
- **Calls** (#278): on each tick (0.5 s) `AssistantAudioDevices.processes()` reads Core Audio's process objects
  (`kAudioHardwarePropertyProcessObjectList`: PID, bundle ID, `kAudioProcessPropertyIsRunningInput`; no permission, no
  audio), `AssistantMicrophoneShare.recorders` drops cmds itself and other cmds instances and the system's always-on
  listeners (CoreSpeech, assistantd, Sound Recognition), and `update` pauses (`stopListening`, silently; the
  menu bar names the app) or resumes after 2 s with nobody recording, only a pause of its own. The user's pause / resume
  (`pause()` / `resume()`) tell it: resumed during a call it stays on until that call ends. Announcements wait while
  paused for a call. Settings › Assistant › Pause while another app uses the microphone (on by default).
- **Rules**: `AssistantAddressing` (name prefix after an optional greeting, folded for width, case and kana; or the
  follow-up window), `AssistantMachine` (off → idle → listening / thinking / speaking / confirming, paused; follow-up
  8 s from the end of speech, confirmation timeout 60 s; only yes/no count without the name while a card waits),
  `AssistantIntent` (regular-expression grammar, Japanese and English; the rest is a question),
  `AssistantPlanner` with `AssistantWorld` (built by `AgentOverview.assistantWorld` from the menu bar's summary, each
  terminal pane's waiting flag and `AgentPromptOptions`): answers, summaries, questions back, or an `AssistantAction`
  to confirm. A pane is chosen only when unique (the one waiting, else the one agent, else the one terminal).
  `AssistantSafety` marks text (and an approved prompt's screen) that needs Return or a click.
- **Its own voice and barge-in**: the microphone stays open while the assistant speaks, so it can be interrupted.
  While it thinks or speaks (`voiceActive`, also a note spoken while a card waits) and `echoGuard` (1 s) after, only
  an utterance starting with its name counts. Any transcript that is mostly what it said (`AssistantEcho.isEcho`:
  `AssistantText.key` character pairs, ≥ 60 % found in the spoken text, utterances of 6+ characters so "はい" or a
  workspace name answering "Which one?" pass) is dropped while speaking and `echoMemory` (30 s) after: speech
  recognition can deliver a long answer's transcript seconds after it was said. The follow-up window opened by an
  answer takes only short utterances (`AssistantAddressing.isShortFollowUp`: ≤ 8 words, ≤ 20 Japanese characters);
  the hotkey's and the name alone's take any. Each new request (`.handle`, `.wake` while busy, the hotkey, a confirmed
  or cancelled card) increments `AssistantMachine.request`; `AssistantController.interrupt()` then stops the voice and
  cancels the `think` task, whose `claude -p` process `AssistantClaudeProcess.run` terminates in its cancellation
  handler, and `answer(_:request:)` refuses a late answer for an older request. "Asking Claude…" is tied to the
  request it was for. A yes / no while a card is being read out (or a note is said over it, or in the echo guard after)
  confirms or cancels it also without the name (`AssistantMachine.isCardAnswer`), unless the word is in what it is
  saying or just said (`AssistantEcho.isEchoedWord`: whole words in Latin script, a part of the text in Japanese; the
  card's last sentence names no yes word for that reason); anything else by name replaces the card.
- **Short answers**: every prompt (`AssistantClaude`: web, on-device instructions, summaries) asks for one short
  sentence (two at most), only what was asked; a session's summary is cut to its first sentence
  (`AssistantBrevity.first`), a detailed one to three; for a free answer still longer than `maxSpokenLength`
  (Japanese characters count double), only the first sentence is spoken (`AssistantBrevity.spoken`) and the HUD shows
  it all. `AssistantReport.status` is compact: counts and names (`waitingList` / `workingList`, joined by `AssistantStrings.list`: 「api、web」 in
  Japanese); an agent's question
  only for one workspace.
- **Several sessions and free commands**: `AssistantScope` (named / all / waiting / working) in the intents
  `checkAll`, `replyMany`, `approveMany` (rules for 「全部のセッションを確認して」, "approve all"…; "api と web に…" is split
  by the planner when the whole is no title and each part finds one). `checkAll` plans `.summarizeEach` (one item per
  agent pane, at most 8), summarised one after the other and listed on the HUD. `replyMany` / `approveMany` plan one
  `AssistantAction` carrying the rest in `also` (`AssistantAction.batch` / `all`): one card, one confirmation; its
  `confirmation` is the strictest of them (`allReasons`), so one dangerous text makes the whole card need Return or a
  click. Named targets that are not found or not clear ask back; with a filter they are left out and named. What the
  rules leave as a question and `AssistantInterpretation.mightBeCommand` thinks may be a command (it names a
  workspace or speaks of agents, sessions, all of them) goes to `AssistantBrain.interpret` (Settings › Assistant ›
  Use Claude to understand free commands, `AssistantInterpreter`, on unless false): `claude -p <prompt>
  --output-format text --model haiku --tools ""` plus the isolation flags (below), 30 s, with only the utterance and the
  workspaces' names, agents and states (`AssistantClaude.interpreterPrompt`). Its one JSON object
  (`kind` instruct / reply / approve / check / question, `targets`, `filter`, `text`, `detailed`) is parsed by
  `AssistantInterpretation.parse` and turned into an intent by `intent(in:)` (made-up names dropped, one line, at
  most 400 characters), which then goes through the planner and the card like any command; a question, no `claude` or
  a failure falls back to answering it as a question. On-device guided generation was tried and rejected: it named
  workspaces "agent", classed questions as instructions and tripped its guardrails on 「確認させて」. Which way a free
  question goes is `AssistantRoute.decide` (#248): no possible command (or the interpreter off) → the web for live
  information, else the on-device model, as before; a request (`isRequest`: 指示 / させて / もらって / 起動 / tell / have /
  start…) → the interpreter first; a live-information question that names no workspace ("Claude Codeの最新バージョンは？")
  → the web without the interpreter; anything else → the interpreter and the on-device model at once
  (`earlyModelAnswer`): the interpreter's verdict decides, the model's answer is used when it says "question" (never
  before: a command the model answered as text would be lost).
- **Vocabulary and misheard names**: `AssistantListener` sets `AnalysisContext.contextualStrings[.general]` (Speech,
  macOS 26 SDK) from `AssistantVocabulary.contextualStrings` (names, Claude Code, Codex, cmds, workspace titles and
  agents), refreshed on `StateChange.workspaces` / `.workspace`. `AssistantVocabulary.normalizingAgents` rewrites
  Claude Code as misheard (クロトコート, cloud code); `readings` / `soundDistance` compare names by how they sound
  (letter names, vowels as sounds, romaji in katakana; edit distance ≤ 1 from 3 characters, ≤ 2 from 6), used only as
  the last tier of `AssistantWorld.find` (`soundsLike`, closest ones; several → ask back) and in `mentioned(in:)` for
  `mightBeCommand`. The interpreter's prompt gets the likely misheard names as hints.
- **Several requests, starts and tasks**: `AssistantIntent.compound` splits at 、/,/then/after 「起動して」 (never quoted or
  dictated text) when every clause parses; a task clause after a start (`AssistantLaunch.request`: 「書かせて」 →
  「書いてください」, "have it fix…") becomes its `task`; a start without a place takes the place another clause names.
  `.sequence` plans the first (its card adds `AssistantPlanner.next`), the controller queues the rest and goes on
  (`AssistantMachine.proceed`) after the answer is spoken or the card's action ran; no to a card skips only that one
  (`AssistantMachine.cancelledAction`, `AssistantPlanner.skipped`: 「Claudeの起動は取り消しました。」, then the rest);
  expiry or a new request drops the queue. A start's new workspace whose folder name is already a workspace's title
  gets `AssistantWorld.uniqueTitle` (`api-2`) as its title, so the exact-title tier of `find` keeps "api" for the
  original. `.startAgent(kind, place?, task?)`: workspace folder, path, `AssistantPlaces.find` under the project
  folders (depth 3, repositories first), else `recentID` (5 min) / `focusedID`, else ask. The command is
  `AssistantLaunch.command` (single-quoted task, control characters and leading dashes removed, 400 characters);
  Debug builds take `CMDS_ASSISTANT_AGENT_EXECUTABLE` instead of `claude` / `codex` for tests. `.delegate` replies to
  the running agent of that kind, else starts one. The on-device model answers `AssistantModelReply.actionMarker` for
  actions; that or an apology (`isAction`) goes to the interpreter (kind `start` too), else `.cannotTell`.
- **Workspaces without an agent**: "what is X doing" and its summary (`AssistantWorld.Workspace.hasNoAgent`) answer at
  once from `AssistantReport.workspace`: no agent, and `AssistantWorld.Pane.shell` (the foreground process the typing
  rules read, `PaneProcessProbe`: idle at the shell, or the program's name, never its arguments); no screen goes to a
  model, which made up 「入力待ち」 for a shell. For an agent, a summary that is the prompt's example copied, or says
  it waits while the session does not (`AssistantModelReply.isSummary(_:waiting:)`), is replaced by the facts.
- **Follow-through**: `AssistantTaskWatch` follows panes started with a task or replied to (agent panes), fed from
  `AppController.changes` with `pane.agentActivity` and the workspace's notification text: needs input → one line,
  busy then idle → done (and forgotten), exit / 4 h / never started → forgotten. Spoken with `speakOnly` when the
  assistant is free (idle, listening, paused), else after; `assistantReportTasks` (default on).
- **Acting**: confirmed actions run in `AssistantController.run` through `AppController.sendText` + `typeText("\r")`
  after `ScheduleRunTiming.enterDelay` (as the reply panel), `typeText` of the digit, or `createWorkspace(cwd:command:
  select: false)`; the pane must still be in the same workspace.
- **Answers**: `AssistantReport` texts through `AssistantStrings.localized` (String Catalog); summaries and questions
  by `SystemLanguageModel.default` (never Private Cloud Compute, 20 s limit); a detailed summary by `claude -p
  --output-format text --model sonnet --tools ""` (no tools: the screen text is untrusted) in an empty temporary
  folder (always `$TMPDIR/cmds-assistant`), screen text on stdin, 90 s limit. The assistant runs Claude Code isolated
  from the user's settings: every call (`AssistantClaude`, argument lists unit-tested) adds `--setting-sources ""
  --no-session-persistence --strict-mcp-config`, so the user's CLAUDE.md, hooks (including `cmds hook claude`),
  output style and plugins are not loaded, no MCP server starts and no session transcript is saved (Claude Code still
  makes an empty project folder under `~/.claude/projects` for the working directory: one, as it never changes;
  `--bare` is not used: it ignores the OAuth sign-in); the process environment has no `CMDS_*` variables, so nothing can attribute it to a
  pane. Models are named constants: `interpreterModel` haiku, `answerModel` sonnet (not the user's default).
  Web questions (`AssistantWeb`, CmdsCore; Settings › Assistant › Use Claude for web questions, `AssistantWeb`
  defaults key, on unless false): `AssistantWeb.needsWeb` sends a question straight to `AssistantBrain.webAnswer`
  when it asks to search / ask Claude or is about something live (folded keyword lists for Japanese, regular
  expressions for English); otherwise the on-device instructions tell the model to answer `[[NEEDS_WEB]]` alone, and
  `answerNeedsWeb` (the marker, also broken or full width, or a "can't access the internet" sentence) falls back to
  Claude; `withoutMarker` keeps the marker from being spoken. `webAnswer` runs `claude -p <prompt> --output-format
  text --model sonnet --tools WebSearch,WebFetch --allowedTools WebSearch,WebFetch` plus the isolation flags (empty
  folder, 90 s, no permission-skipping flag); the prompt holds only the utterance, the date and time, the time zone
  and the locale, never screen text. `AssistantWeb.speakable` drops a "Sources:" list, links, URLs and Markdown. The
  HUD's `ClaudeMark` shows "Asking Claude…" while `claude -p` runs and "Claude" under its answer.
- **Latency** (#248): every `claude -p` runs with `--output-format stream-json --verbose --include-partial-messages`
  (`AssistantClaude.outputArguments`); `AssistantClaudeProcess` reads it line by line (`AssistantClaudeStream`) and
  returns the `result` line at once (Claude Code takes about a second more to exit, which is not waited for). A
  detailed summary is spoken sentence by sentence as it is written (`AssistantSpokenStream`: complete sentences of
  `AssistantWeb.speakable` text, the first at once with `say(open: true)`, the next with `AssistantVoice.append`, the
  end with `close`; `AssistantUtterances` counts the parts, so the follow-up window opens after the last one); calls with
  tools release nothing before the model's last turn ends and drop a turn that ends in a tool use, so a preamble ("I'll
  search…") is never spoken. A web answer or detailed summary not there after `AssistantAck.delay` (0.8 s) gets
  「調べます。」 / "Checking." (`acknowledge`: the voice only, no state or HUD change, once per request; the answer is
  queued after it, not cut into it). `AssistantWebCache` keeps web answers 10 minutes (key: the question folded by
  `AssistantText.key`, the language and the local day; at most 20). `AssistantClaude.webModel` stays sonnet: the
  web search takes most of the time (about 4–6 s a search) and haiku, in five questions, was not faster (median 10.7 s
  against 12.3 s, one 29.7 s), searched more often and gave up twice. A warm Claude Code process
  (`--input-format stream-json`) was measured and not used: a process keeps its conversation, so it could serve one
  request only and would have to be started before the request is known (no early partial transcript, see Listening),
  i.e. on any speech near the Mac, for about 230 MB and 0.7 s saved; reading the `result` line early saves about 1 s on
  every call for nothing. Stage times per request: `AssistantTimeline` (`+Timing`: `debug.assistant` `timing` /
  `timings`, and one log line `assistant timing r<request> <route>: <stage> <ms> …`, stage names and milliseconds only;
  the listener logs how long after the speech each final transcript came).
- **Voice**: `AssistantVoice` (`AVSpeechSynthesizer`, on the Mac only). Each utterance gets a number from
  `AssistantUtterances` (CmdsCore): stopping ends the current one at once, and the synthesizer's didCancel / didFinish
  (which for a stopped utterance arrive after the next one was queued) end an utterance only while it is the current
  one, so they cannot open the follow-up window or start the echo guard in the middle of the next answer. The list and the fallback are plain values in
  `AssistantVoices` (CmdsCore): `system` / `personal` voices for the app's language, `resolve` (the chosen voice if
  it still exists and speaks the language, else the system voice), `personalVoiceState` (Settings' note: not asked,
  denied, unsupported, none created, available, other languages only). Personal Voices (`voiceTraits` contains
  `.isPersonalVoice`) appear only after `AVSpeechSynthesizer.requestPersonalVoiceAuthorization`, which only
  Settings' "Use my Personal Voice…" button calls (the permission is per app: cmds Dev in Debug).
- **Keys and HUD**: the HUD is a `.nonactivatingPanel` that can never become key; Return / Enter / Esc are Carbon hot
  keys registered only while a card shows (ignored for 0.8 s after it appears), ⌥⌘J likewise; isolated instances
  register none.
- **Waiting orb**: `AssistantIdleOrb`, another never-key `.nonactivatingPanel` (all Spaces, `.stationary`), shows while
  the assistant is on and the HUD is not (`AssistantPresence.shown`, CmdsCore: off → nothing, HUD → none of it,
  paused → dim and hollow, `Hearing` (level ≥ 0.15 on, < 0.08 for 0.6 s off) → follows the level, a workspace needing
  the user → orange; Settings › Assistant › Show while waiting `AssistantShowWhileWaiting`, on unless false, and
  `AssistantOrbSize` small 56 pt / medium 72 pt). `AssistantController+Presence` updates it from `refresh()`, state
  changes (coalesced) and screen changes. It grows and fades as the HUD fades in, and comes back after the HUD fades
  out (0.22 s; none with Reduce Motion). Only the disc takes the mouse (`hitTest`): a click calls `showLast()` (the HUD
  with the last thing said for `hudLinger`), a drag past 4 pt moves it and stores its centre in `AssistantOrbCenter`
  (not observed, so no settings change), kept on the nearest screen within 160 pt (`AssistantPresence.center`), else
  bottom right above the Dock (20 pt margins of `visibleFrame`).
- **Muting in tests**: `debug.assistant` `on {mute}` sets `mutedOverride` (cleared by `turnOff`, gone after a
  relaunch), never `AssistantMuted`; the goodbye after "stop" keeps it (`speakOnly(_:muted:)`).

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
