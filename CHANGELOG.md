# Changelog

All notable changes to cmds are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- iPhone/iPad: files panes appear with a folder icon and their folder's path (sync feature `files`). Older companion
  versions see them as browser panes (#26).

## [0.8.0] - 2026-11-03

Mac only; the iPhone/iPad app is unchanged from 0.4.0.

### Added

- Mac: `cmds mcp`, an MCP server for agents in a cmds terminal (Claude Code, Codex, …): open and check web pages in
  browser panes instead of Chrome (`browser_open`, `browser_eval`, `browser_snapshot` returned as an image, …), show
  files in preview panes, set the sidebar status. Register it with `claude mcp add --scope user cmds -- cmds mcp` or in
  Codex's `config.toml` (#76).
- cmds skill: inside cmds, agents open and check web pages in a cmds browser pane (`cmds browser open/eval/snapshot`)
  instead of Chrome; the same skill installs for Codex (`~/.codex/skills/cmds/`) (#74).

### Fixed

- Mac: `cmds browser snapshot` of a browser pane in a workspace that is not shown failed with "PNG encoding failed";
  the pane is now rendered off screen for the snapshot (#76).
- Mac (Japanese): File › New Remote Files Pane… is called 新規リモートファイル一覧ペイン…, like 新規ファイル一覧ペイン,
  instead of 新規リモートファイルパネル… (#68).

## [0.7.0] - 2026-11-02

Mac only; the iPhone/iPad app is unchanged from 0.4.0.

### Added

- Mac: files panes on SSH hosts. File › New Remote Files Pane… (⌥⇧⌘E), ⇧⌘E in an SSH pane, or
  `cmds files HOST:PATH` lists a folder on a host over SFTP with your own `ssh` (`~/.ssh/config`, keys, agent, an open
  `ControlMaster`). cmds never asks for or stores a password and never adds host keys: password-only hosts, unknown and
  changed host keys are refused with a note on what to do. Rename, New Folder, Open and preview (a downloaded copy),
  Open Terminal Here (an SSH pane), and Move to Trash, which moves items to the server's own Trash
  (`~/.local/share/Trash`) and never deletes them. Remote panes come back after a relaunch and wait for Connect (#26).
- Mac: a transfer queue for copies and moves between the Mac and SSH hosts, or two hosts (F5 / F6, drag and drop,
  dropping from the Finder, ⌘C / ⌘V): progress in the pane, Window › Transfers (⌥⌘T) with Pause, Cancel, Retry and a
  log per transfer, and the usual Keep Both / Replace / Skip conflicts (Replace moves the existing item to the Trash
  of its side). Files arrive under a temporary name and get theirs only when complete; Cancel removes only what the
  transfer wrote, and a temporary file left by quitting mid-transfer is removed at the next launch (on the Mac) or the
  next connection (on a host). `cmds transfers` and `transfer.*` on the socket (#26, #64).
- Mac: schedules can type into an existing pane (`--send TEXT --to shell|agent`, Type into a pane in the editor): a
  one-line command at an empty shell prompt, or a prompt into an idle Claude Code or Codex. The pane is chosen by a tag
  kept in the saved session (it survives a relaunch) or by the title of a one-pane workspace; when no pane or several
  match, the run is skipped (#45).
- Mac: schedules continue Codex sessions too (`codex resume`), and run when Codex's limit resets
  (`--after-codex-limit`). Codex is typed into only when its session file has been quiet for 90 s, its screen has not
  changed for 5 s and shows no working line or choice (#45).
- Mac: limit schedules can repeat ("Every time it resets", `--repeat`): one run per new reset, never two for the
  same one (#45).
- Mac: a notification a minute before a scheduled run, with Skip (`cmds schedule skip`, Skip Next Run in the
  window; `--no-warn` turns it off), and the next run in the sidebar's footer (#45).

### Changed

- Mac: schedule runs also wait while Claude Code's screen shows its working line (`esc to interrupt`). Reasons that
  named Claude Code now say "the agent" (#45).
- Mac: `schedules.json` is written as version 2 once a schedule uses a feature added here; cmds 0.6 then shows such a
  file read only instead of running it. Files with only 0.6-style schedules stay at version 1 (#45).

### Fixed

- CLI: `cmds read p2` read the focused pane, not p2: a pane id given without `--pane` was ignored. `cmds read`,
  `cmds browser url` and `cmds browser snapshot` now refuse a bare argument with their usage; use `--pane P` (#61).
- Mac: a schedule that continues a session held by several panes remembered its pane by id, which changes when cmds
  restarts, so after a relaunch it could prefer another pane holding the same session. It now keeps the pane's tag in
  the saved session, as Type into a pane does (`paneTag`). A pane remembered by cmds 0.6 is forgotten; such a run uses
  the only pane holding the session, or is skipped when several do, until you choose the pane again (#58).

## [0.6.0] - 2026-11-02

Mac only; the iPhone/iPad app is unchanged from 0.4.0.

### Added

- Mac: schedules (Window › Schedules…, Settings › Agents, `cmds schedule`, socket `schedule.*`). Start a workspace in
  the background (folder, account or `auto`, a command typed at its prompt, a first prompt for the Claude Code it
  starts) or continue a remembered Claude Code session (resumed first when it is not running) once, on weekdays at
  set times, or when an account's limit resets. Nothing is typed into a busy agent, a pane running another program, or
  a pane the schedule did not create or target, and nothing is typed twice. Missed times get one catch-up run within
  the schedule's late policy, else a missed notice. A history shows how each run ended. Schedules run while cmds runs;
  `schedule.*` is refused on SSH panes' sockets (#45).
- Mac: when every account has hit its limit, the bar in the pane offers Continue at 15:01 (and the notification
  Continue When It Resets): `continue` is typed into the session after the reset (#45).

### Fixed

- Mac: a remembered Claude Code or Codex session no longer takes the command line typed to start it (e.g.
  `cd '…' && env CLAUDE_CONFIG_DIR=… claude --resume …`) as its title. `cmds sessions`, the resume banners and
  schedules show the session's own title, or none, also for sessions remembered before (#49).
- Mac: the files pane's Git column no longer keeps old `M` / `A` / `?` marks after a commit, `git add` or checkout, or
  after files were edited in another app. It is read again when Git changes the repository and when the window becomes
  active, not only when files are added to or removed from the shown folder (#43).
- Mac: removing a Claude account takes it off the panes that had it; `cmds ls` and the sidebar no longer show
  `account <name>` for an account `cmds accounts` does not list (#44).
- `cmds accounts move NAME 9` with fewer accounts is refused (exit 1, `the position must be 1 to 3`) instead of moving
  the account to the end (#44).
- Docs: a split without `--account` does not take the account of the pane it splits (#44).
- Mac: a damaged `claude-accounts.json` is no longer replaced by the next change to the accounts. It is kept as
  `claude-accounts.json.corrupt-<time>` in the cmds support folder and cmds says so; a file it cannot read at all is
  left alone and not saved over (#46).

## [0.5.0] - 2026-11-02

Mac only; the iPhone/iPad app is unchanged from 0.4.0.

### Added

- Mac: several Claude accounts of your own. An account is a name and a Claude Code config directory
  (`CLAUDE_CONFIG_DIR`) that you sign in to yourself; cmds stores only names and paths, never credentials
  (Settings › Agents › Claude accounts, `cmds accounts`). `cmds new --account NAME -- claude` (and `cmds split
  --account`, `--account auto`) starts a pane under an account; the sidebar shows it after the model. Use only your
  own accounts; you are responsible for following Anthropic's terms for each (#31).
- Mac: when Claude Code shows "You've hit your … limit · resets …", an API rate-limit error, or a status-line limit
  at 100 %, cmds records the account's reset time and offers to continue the session with the next account
  (a bar in the pane and a notification with one click), or does it by itself (`cmds accounts auto on`). It waits
  until Claude Code is idle at its prompt, quits it and resumes the same session with `claude --resume` under the
  next account that has not hit its limit (#31).
- Mac: Share Sessions… (`cmds accounts share`) lets every account reach the same session transcripts: each account's
  `projects` folder becomes a symlink to the first account's, after asking; an account's own folder is renamed, never
  deleted (#31, #39).
- Mac: files panes, a local folder as a list next to your terminals (#26). Columns for name, size, date modified, kind
  and Git state (inside a repository); sorting, hidden files (⇧⌘.), type-to-select, back / forward / enclosing folder
  and a clickable path. Return opens, Space shows the file in the preview pane. Two files panes side by side copy and
  move between each other (F5 / F6, drag and drop, ⌘C / ⌘V / ⌥⌘V) in the background, with progress, Cancel and a
  choice for names that are taken (keep both, replace, skip, for all). Rename (F2), New Folder (F7) and Move to Trash
  (⌘⌫); nothing is deleted for good. Follow Terminal keeps the pane in the directory of the workspace's terminal; Open
  Terminal Here opens one in the folder. File › New Files Pane (⇧⌘E), Pane › Files, `cmds files [PATH]` and the
  socket method `files.open`; files panes come back after a relaunch and in exported workspaces (#40).

### Changed

- Mac: file paths dropped or pasted into a terminal are also quoted when they contain `~`, `^` or `%`, and names with a
  line break are put in single quotes (#26).

## [0.4.0] - 2026-11-02

Mac and iPhone/iPad.

### Added

- Mac: while a phone shows a pane's earlier output, the rows that scroll off the pane's screen are sent along with the
  screen updates, so the earlier output continues without gaps, also while a full scrollback drops its oldest rows
  (sync feature `scrollbackStream`, for phones that support it) (#22).

### Fixed

- iPhone/iPad: earlier output keeps up while you read it. The rows that scroll off the screen meanwhile are added
  between the earlier output and the screen, instead of missing until you return, and the text you read does not move.
  Needs cmds 0.4.0 or later on the Mac (#22).
- Mac: the earlier output of a pane is read without moving the terminal's view. A pane on screen no longer flickers
  while a phone follows it, and a pane scrolled up on the Mac now gives the phone the rows above what it shows (it gave
  none) (#21).
- Mac: a phone's request for a pane's earlier output that comes within 0.5 s of the previous one, or while output
  keeps the screen moving, is answered as soon as possible instead of being dropped (#22).
- Mac: Settings › Terminal font showed some Japanese fonts with garbled names (e.g. `ÇcÇeïΩê¨ÉSÉVÉbÉNëÃW3` for
  ＤＦ平成ゴシック体W3); the list now uses the names Font Book shows (#28).

### Changed

- Building from source: `scripts/build-ghostty.sh` builds GhosttyKit with cmds' patches on libghostty
  (`vendor/ghostty-patches`); a plain GhosttyKit no longer builds the app (#21).

## [0.3.0] - 2026-11-01

Mac and iPhone/iPad.

### Added

- iPhone/iPad: swipe down in a terminal for its earlier output (up to 500 rows above the screen, 200 over Bluetooth).
  The screen stays put while you read it, and Latest returns to the live screen. Needs iOS 18 and cmds 0.3.0 or later
  on the Mac (#19).
- Mac: answers the phone's requests for the rows above a pane's screen (sync feature `scrollback`) (#19).

## [0.2.1] - 2026-11-01

Mac only; the iPhone/iPad app is unchanged from 0.1.3.

### Fixed

- `cmds --version` printed 0.1.0 in every release; it now prints the version of the cmds it comes with (#16).

## [0.2.0] - 2026-11-01

Mac only; the iPhone/iPad app is unchanged from 0.1.3.

### Added

- Mac: automatic updates (Sparkle). cmds checks cmds.n-n.tokyo once a day, downloads a new release in the background
  and installs it when it quits; cmds › Check for Updates… installs it right away, and cmds › Settings… › Updates
  turns either off. Updates and the update feed are EdDSA-signed. Only the downloaded release updates itself, and the
  first update to this version is manual (#13).

## [0.1.3] - 2026-10-31

iPhone/iPad only; the Mac app is unchanged from 0.1.1.

### Added

- iPhone/iPad: shortcut buttons above the key bar that send a canned reply or command with Return (承認, 考慮, 別案,
  再確認, `claude`, `codex` by default), editable in Settings (#8). In line mode, while a line is being typed, a
  shortcut is added to it instead of sending it.

## [0.1.2] - 2026-10-31 [YANKED]

Withdrawn from App Review before release; its changes ship in 0.1.3.

## [0.1.1] - 2026-10-31

### Fixed

- Remote access (iOS sync over SSH): a failure to save the settings is logged and shown in the window instead of
  being ignored.
- Remote access: the relay port is shown without a thousands separator ("62198", not "62,198").
- Remote access: stopping with no relay host shows "Choose a relay host" instead of "Waiting for iOS Sync".
- Remote access: an ssh left over from a previous run is only terminated when its pid, start time and path all match
  the one cmds started, so a reused pid can no longer hit an unrelated ssh.
- Bluetooth sync: a channel that opens without streams is refused instead of crashing the app.

## [0.1.0] - 2026-10-30

First release (`MARKETING_VERSION` 0.1.0, build 1). Development started 2026-10-29.

### Added

#### Mac app

- Native AppKit app with libghostty terminals (GhosttyKit built from the `vendor/ghostty` submodule), Ghostty's
  terminfo and shell-integration resources bundled; `TERM=xterm-ghostty`.
- Workspaces as vertical tabs (drag to reorder, rename, ⌘1…⌘9) with nested right/down splits, draggable dividers,
  pane zoom and directional focus.
- Tiled view: several workspaces side by side as live tiles (sidebar ⌘-click / ⇧-click, View › Tile All
  Workspaces ⌃⌘T, `cmds tile`, `view.tile`), automatic grid up to 9, draggable and remembered dividers, tile
  headers with agent state and attention ring, tile zoom (⇧⌘↩); saved in the session. Tiling by drag: sidebar rows
  dropped on a tile's edge or middle (snap-style highlight), tile headers dragged to move or swap tiles or back onto
  the sidebar to remove them, View › Move Tile … (⌃⇧⌘ + arrow); the arranged rows are kept in the session and
  reported by `cmds tile` / `view.tile` (`rows`).
- Sidebar rows with git branch, directory, listening ports, CPU and memory per workspace (processes attributed by
  environment, pane tty and ancestry), latest notification text and attention dot; footer with Mac-wide CPU, memory
  and memory pressure; compact 52 pt rail (⌃⌘S).
- Sidebar agent state per workspace (Working / Needs Input / Done / Idle / Stopped, from Claude Code hooks, the
  terminal-title spinner and status-line reports), the agent's task as the row's second line, session-only figures per
  row (account limits in the footer), paths shortened by leading components, hover × and Clear Notification,
  filter (⌥⌘F) and Group by Project; stale notifications clear when you type in the pane or the agent works again
  (`UserPromptSubmit` hook).
- Attention ring on OSC 9/777 notifications, the bell and `cmds notify`, with macOS notifications in the background
  and Jump to Latest Attention (⇧⌘U).
- Browser panes (WKWebView) with address bar, reload, back/forward and scripting.
- Preview panes: images, Quick Look (PDF, video, Office, text), rendered Markdown with local images, coloured unified
  diffs; live reload including atomic saves; File › Open in Preview… (⇧⌘O) and ⌘-click on file paths.
- SSH workspaces: the user's `ssh` with a restricted per-pane API socket forwarded to the server, host completion
  from `~/.ssh/config`, reconnect overlay, Install Remote Helper… (`cmds-remote.sh`), remote cwd and branch.
- Session restore of workspaces, layouts, directories, URLs, previewed files and SSH hosts.
- Coding agents: Claude Code usage and account limits from its status line (`cmds hook claude-status`), Codex usage
  from its session files, notifications from Claude Code hooks (`cmds hook claude`); per-pane agent line and
  account-limit meters in the sidebar.
- Resuming Claude Code and Codex sessions after a restart (Ask / Always / Never), also on SSH panes.
- Export and import of workspaces with their agent sessions (File › Export/Import Workspaces…, `cmds export` /
  `cmds import`).
- Keep awake: idle-sleep assertion while cmds runs, optional display assertion, opt-in Keep Awake With Lid Closed
  (`pmset disablesleep` through the administrator dialog, restored on quit, recovery after a crash).
- English and Japanese localization (String Catalogs), with a Language menu.
- Settings window (⌘,): terminal font family and size layered over the Ghostty config and applied live, sidebar text
  size (Small / Medium / Large), default browser and preview zoom; View › Bigger / Smaller / Actual Size (⌘+ / ⌘− /
  ⌘0) for the focused pane. The companion's ⋯ › Settings… has Fit to width or a fixed terminal font size.
- App icon for macOS and iOS.

#### `cmds` CLI and socket API

- Unix-socket JSON-lines API (same-user only) and the `cmds` CLI bundled in the app, with Install Command Line Tool….
- Commands: `ping`, `identify`, `ls`, `panes`, `new`, `select`, `close`, `rename`, `split`, `focus`, `close-pane`,
  `send`, `read`, `notify`, `status`, `open`, `browser open|navigate|url|eval|snapshot`, `events`, `rpc`, `stats`,
  `agents`, `sessions`, `resume`, `sync`, `reconnect`, `remote-helper`, `export`, `import`, `hook claude`,
  `hook claude-status`; `--json` everywhere; English output in every language.
- Claude Code skill (`integrations/claude/skills/cmds`).

#### iOS/iPadOS companion

- SwiftUI app mirroring workspaces and terminal screens (screen diffs at ~10 Hz), with a key bar, direct and line
  input, hardware keyboard support, pinch zoom, CPU/memory and agent usage, notifications, image and PDF previews,
  and demo data.
- Sync protocol v2: WebSocket over TLS 1.3 pinned to the Mac's self-signed keychain certificate; QR-code pairing and
  manual pairing with identity comparison; pairing only while the Mac's pairing window is open; rate limits.
- Bluetooth LE fallback (L2CAP relay carrying the same TLS session) when the Mac is not reachable over IP.
- Remote access through an SSH relay host (`ssh -R` on the Mac, swift-nio-ssh on the phone with a restricted
  forwarding-only key and pinned host key).
- Sync diagnostics: `cmds sync` / `sync.status`, forced transports and a device driver for testing.

#### Distribution

- Release builds of the Mac app and the CLI run under the hardened runtime with the entitlements a terminal needs
  for the programs it runs (`App/cmds.entitlements`: Apple Events, microphone, camera, contacts, calendars, location,
  photos) and matching usage strings in English and Japanese.
- `scripts/release/build-dmg.sh`: Release build, Developer ID signing, DMG, notarization with a keychain profile,
  stapling, SHA-256 and `site/public/download/` (docs/internals/release.md).
- Website for cmds.n-n.tokyo in `site/` (Japanese and English, usage guide with screenshots, privacy policy;
  Firebase Hosting configuration).

[Unreleased]: https://github.com/nntokyo/cmds/compare/v0.8.0...master
[0.8.0]: https://github.com/nntokyo/cmds/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/nntokyo/cmds/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/nntokyo/cmds/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/nntokyo/cmds/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/nntokyo/cmds/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/nntokyo/cmds/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/nntokyo/cmds/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/nntokyo/cmds/compare/v0.1.1...v0.2.0
[0.1.3]: https://github.com/nntokyo/cmds/compare/v0.1.1...v0.1.3
[0.1.2]: https://github.com/nntokyo/cmds/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/nntokyo/cmds/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/nntokyo/cmds/releases/tag/v0.1.0
