# Changelog

All notable changes to cmds are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Mac: find in a terminal pane (#173). Edit › Find › Find… (⌘F) opens a find bar over the pane: libghostty's own
  search highlights every hit in the scrollback and on the screen and scrolls to the selected one; Find Next / Find
  Previous (⌘G / ⇧⌘G, Return / ⇧Return in the bar) go up and down through them, Esc closes. Match Case and Regular
  Expression search the rows in cmds instead (read in slices, matched off the main thread) and outline the selected
  hit. While the bar is open no key reaches the program in the terminal.

- Mac: command palette (#173). View › Command Palette… (⇧⌘P) finds workspaces, panes, enabled menu commands, recent
  agent sessions and listening ports (opened in a browser split) by fuzzy search, also in Japanese; ↑/↓ and Return
  run one, Esc closes.

- Mac: worktree workspaces for agents working side by side (#172). File › New Worktree Workspace… (⌥⌘N, also in a
  workspace's sidebar menu) or `cmds new --worktree BRANCH [--base REF] [--path DIR]` fetches, creates a new branch
  (without upstream) and a git worktree for it, by default in `<repo>-worktrees/<branch>` next to the repository, and
  opens a workspace there; an existing branch or folder is an error. Show Changes in the sidebar menu (`cmds changes`)
  opens the branch's commits and its diff against the base, working tree included, as a diff preview. Closing such a
  workspace offers Close and Remove Worktree (`cmds close --remove-worktree`): `git worktree remove`, refused while
  there are uncommitted changes, untracked files or unpushed commits, and never for worktrees cmds did not create
  (remembered in `worktrees.json` in the support folder).

- Mac: File › Recent Agent Sessions (also the clock button at the bottom of the sidebar) lists the 5 newest Claude
  Code and Codex sessions seen in any pane, kept after the agent exits or the pane closes and across restarts.
  Choosing one shows the pane that still has it, or resumes it in a new workspace in its folder, under its Claude
  account or on its SSH host, typed only once that new shell's prompt is ready. `cmds sessions --recent` /
  `agent.history` list them.

- Mac: cmds can be chosen as the default web browser; links opened from other apps open in a browser split beside the
  focused pane. First step towards passkeys in browser panes (#162).

- iPhone/iPad: browser panes show their page in a web view (Reload, Open in Safari), loaded by the phone itself; pages
  only the Mac can reach (`localhost`, files) say so instead. Preview panes render Markdown and diffs like the Mac and
  show other text files as text; the same for files opened while browsing a files pane.

- Mac: browser panes check responsive layouts. The device button in the toolbar shows the page at an iPhone, Pixel,
  iPad or desktop size (or a custom one, rotated if you like), scaled down to fit the pane, with that device's user
  agent; the toolbar shows the page's CSS width and which media-query breakpoint range it is in. Pages can be shown
  light or dark (`prefers-color-scheme`), or follow the Mac. Kept per pane across relaunches and in exported
  workspaces. `cmds browser device`, MCP `browser_set_viewport`, socket `browser.set_viewport`. WebKit does not
  emulate the pixel ratio, touch, `<meta viewport>` or reduced motion; check those on a device (#168).

- Mac: browser screenshots of the whole page (`cmds browser snapshot --full`), of one element (`--selector`), and at
  other sizes, up to four in one go (`--device iphone,ipad,desktop-1440 -o shot.png` writes `shot-iphone.png`, …;
  each size loads the page again off screen). The pane is not scrolled or resized. MCP `browser_snapshot` takes the
  same and returns one image per size; socket `browser.snapshot` answers with `images`. An older app gives a clear
  "update cmds" error instead of a visible-page image (#169).

- Mac: responsive view. Browser panes can show one page at phone, tablet and desktop size side by side (device menu ›
  Responsive View, `cmds browser responsive [URL]`, MCP `browser_responsive`); 2–4 sizes. Navigating in any frame
  loads the page in the others, scrolling keeps them at the same proportion of their page (Sync Scrolling), Reload
  reloads them all and a `file://` page reloads when saved. Screenshots of such a pane have one image per frame.
  Kept across relaunches; each frame is its own WebKit process, freed when the view is turned off (#170).

### Changed

- Mac: browser pages follow the Mac's light or dark appearance by default; before, they were always dark (#168).

### Fixed

- CLI: bare arguments a command does not take are a usage error instead of being ignored (#185).
  `cmds new --worktree B /path/to/repo` ignored the directory and created the branch and worktree in the repository
  of the current directory; `cmds new` now takes a single bare existing directory as `--cwd` (not together with
  `--cwd`) and refuses anything else. `cmds ping`, `quit`, `identify`, `ls`, `panes`, `remote-helper`, `events` and
  `mcp` refuse bare arguments with their usage.

- Mac: `cmds mcp`'s `close_pane` also closes browser, preview and files panes the agent opened from its terminal with
  the CLI (`cmds browser open`, `cmds open`) or before the MCP server restarted. cmds remembers the terminal pane each
  such pane was opened from (`openedBy` in `cmds panes --json`, kept across a relaunch); panes opened from another
  terminal or by you are still refused, with a hint to `cmds close-pane <id>` (#165).

## [0.15.1] - 2026-11-08

Mac only; no iPhone/iPad release (the Unreleased entry above ships with the next companion release).

### Fixed

- Mac: moving a pane's Claude Code session to another account often ended with "Claude Code did not quit": Claude
  Code quits only on a second Ctrl-C within about 0.7 s of the first, and cmds sent them too far apart. Each attempt
  now sends both Ctrl-Cs at once (#159).

## [0.15.0] - 2026-11-08

Mac and iPhone/iPad. Browsing on the phone needs cmds 0.15.0 on the Mac and the next companion release; older Macs
and phones keep working as before.

### Added

- Mac: phones can browse the folder of a files pane, read only: they ask for a folder's contents (folders first, then
  by name, at most 2,000 items; hidden items only when the pane shows them) and open a file in it (up to 10 MB), only
  phones that ask for it (sync feature `filesBrowse`). A pane on an SSH host is listed through the connection the pane
  already has open; the phone never makes cmds connect. Nothing can be changed from the phone (#26).
- iPhone/iPad: a files pane lists its folder with icons, sizes and dates; tap a folder to go into it (on the phone
  only, the Mac pane stays where it is), Back to return, pull to refresh, and tap a file to open it: images and PDFs
  with the preview viewer, text files (source code, logs, JSON…) as text. Macs without the feature keep showing the
  folder's path (#26).

## [0.14.0] - 2026-11-07

Mac and iPhone/iPad. The iPhone/iPad features need cmds 0.14.0 on the Mac; older Macs and phones keep working as
before.

### Added

- Mac: terminal screens go to the iPhone/iPad with their colours and attributes (palette, 256 and RGB colours, bold,
  faint, italic, underline, inverse, strikethrough), only to phones that ask for them (sync feature `styles`); older
  phones keep getting plain text. The rows above the screen (earlier output) keep theirs too. Built on a new libghostty patch, `ghostty_surface_read_text_vt` (#113).
- iPhone/iPad: terminal screens and their earlier output in colour, with bold, italic, underlined, inverse and faint text and backgrounds on the
  cell grid, from a Mac that sends them; the 16 ANSI colours use a palette made for the dark terminal screen (#113).
- Mac: schedules go to the iPhone/iPad as a read-only summary (name, trigger, kind of action, next run, results and
  recent runs; never prompts, commands, texts or folders), only to phones that ask for them (sync feature
  `schedules`) (#45).
- iPhone/iPad: ⋯ › Schedules lists the Mac's schedules with their next run, the run in progress or the last result
  with its reason, and the recent runs, read only, from a Mac that sends them (#45).
- Mac: compare and sync folders. **Compare and Sync with Other Pane…** (⇧F2, Pane › Files or the right-click menu)
  compares the folders of two files panes, on this Mac or SSH hosts (local ↔ remote, remote ↔ remote, local ↔ local),
  recursively by name, size and date, and lists what differs: only on one side, modified, a link (never followed or
  synced) or a folder that could not be read. A sync copies one way (new and modified items; with **Move extra items
  to the Trash**, items only on the target side go to its Trash) or both ways (missing items both ways; items that
  differ are conflicts settled by Newer wins, Left wins, Right wins or Skip, or per item). The window shows each
  planned action with a checkbox before anything runs; Sync queues them as one transfer in Window › Transfers.
  Replaced items go to the Trash of their side (the server's Trash on a host), nothing is deleted, and an item that
  changed after the comparison is left as it is. Also `cmds files compare` / `cmds files sync` and `files.compare` /
  `files.sync` (#26).

## [0.13.0] - 2026-11-07

Mac only; the iPhone/iPad app is unchanged from 0.11.0.

### Added

- Mac: ctx rings in the menu bar item's menu: the context window of the fullest agents, by workspace (Settings ›
  Menu Bar › Menu).
- Mac: Google Antigravity's CLI (`agy`). `cmds hook agy-status` as its status-line command reports the model, context
  and quota windows (Gemini 5h / 7d, third-party models) like Claude Code's status line; they show in the sidebar,
  the menu bar rings, the widget and on the iPhone (named “Agent” there until the iPhone app's next update). Limit rows with more windows than fit continue on the next row.
- Mac: Codex hooks. `cmds hook codex` in `~/.codex/hooks.json` shows when Codex works, asks for approval
  (`PermissionRequest`, with what it wants to run) or finishes a turn, like the Claude Code hooks; also for Codex TUIs
  on the shared app-server daemon, matched to their pane by session (#128). A turn that Codex's usage limit stops
  (no `Stop` hook) goes back to idle when its title spinner stops.
- Mac: edit files on SSH hosts. **Edit** (F4, the right-click menu or Pane › Files) in a remote files pane downloads
  the file into an editable copy and opens it in its default app; every save is uploaded over the server's file
  (written under a temporary name, then renamed over it in one step, keeping its permissions) and listed in Window ›
  Transfers. If the file changed on the server meanwhile, cmds asks: Keep Mine, Keep Theirs, Save Mine as a Copy or
  Cancel. **Stop Editing**, closing the pane or quitting ends it; quitting warns about edits not uploaded yet (#26).

## [0.12.0] - 2026-11-07

Mac only; the iPhone/iPad app is unchanged from 0.11.0.

### Added

- Mac: a **cmds** widget for the desktop and Notification Center (small, medium): the badges of the menu bar item,
  the workspaces that need you (and since when) or are working, and rings for the account limits, CPU and memory.
  Clicking it opens cmds on that workspace (`cmds://workspace/<id>`) (#96).

## [0.11.0] - 2026-11-07

Mac and iPhone/iPad. The iPhone/iPad app also brings the 0.4.0 changes that had not reached the App Store (earlier
output that keeps up while you read it, #22): the App Store had 0.3.0.

### Added

- Mac: unpair one iPhone or iPad: **Revoke…** next to each device in the pairing window, `cmds sync devices` and
  `cmds sync revoke <id|name>` (`sync.devices`, `sync.revoke`, local socket only). The device is disconnected at once;
  the others stay paired (#114).
- iPhone/iPad: a workspace's agent line shows the Claude account its pane runs under (`@work`, as in the Mac's
  sidebar) and, while that account is at a limit, when it resets. The Mac sends its limited accounts in `state`
  (`accountLimits`, names and reset times only; older phones ignore it) (#112).
- iPhone/iPad: files panes appear with a folder icon and their folder's path (sync feature `files`). Older companion
  versions see them as browser panes (#26).

### Fixed

- iPhone/iPad: rows with Japanese and other wide characters are laid out on the terminal's cell grid, so the cursor
  sits right after the text and columns line up; before, the cursor drifted half a cell to the right per wide
  character (#115).
- Mac: the 16 px app icon (Finder lists, non-Retina displays) is drawn on the pixel grid, so ">_" reads instead of
  blurring (#115).

## [0.10.0] - 2026-11-06

Mac only; the iPhone/iPad app is unchanged from 0.4.0.

### Added

- Mac: menu bar item — rows that need you say since when; ⌘1…⌘9 choose a workspace while the menu is open; limit
  rings count down to their reset within a day (`in 2h10m`); a red dot on the icon warns of a limit at 95 % or
  critical memory pressure; Menu Bar Settings… in the menu. Settings › Menu Bar chooses what the icon and the menu show
  (working badge, red dot, animation, CPU and memory, AI limits, workspaces) (#105).
- Mac: Settings › Sidebar chooses what each workspace row shows (Git branch, directory, ports, agent
  model/context/cost, latest notification) and what the footer shows (AI limits, CPU and memory) (#107).

### Changed

- Mac: Settings is split into tabs (General, Sidebar, Agents, Menu Bar, Updates), so the window fits small screens and
  each setting sits under its area (#107).

## [0.9.1] - 2026-11-06

Mac only; the iPhone/iPad app is unchanged from 0.4.0.

### Fixed

- Mac: in the menu bar item's menu, the line under a workspace (the agent and what it is doing) was cut off (#101).

## [0.9.0] - 2026-11-06

Mac only; the iPhone/iPad app is unchanged from 0.4.0.

### Added

- Mac: a menu bar icon with an orange badge (workspaces that need you) and a blue one with a turning arc (agents
  working). Its menu shows ring charts for CPU, memory and the Claude Code / Codex limits, and each agent workspace
  with a state mark and what the agent is doing; choosing one takes you there. Settings › Agents › Show in menu bar
  (#95).

## [0.8.2] - 2026-11-06

Mac only; the iPhone/iPad app is unchanged from 0.4.0.

### Fixed

- Mac: `cmds browser eval` and the MCP `browser_eval` failed with "EvalError: Refused to evaluate a string as
  JavaScript" on pages whose Content Security Policy forbids `unsafe-eval` (GitHub, many production sites). There
  the script now runs as an expression, or as a function body whose value is what it `return`s (#88).
- Codex: `cmds mcp` offered no tools, because Codex starts MCP servers without the `CMDS_*` variables. The Codex
  setup in the guide adds `env_vars = ["CMDS_PANE_ID", "CMDS_WORKSPACE_ID", "CMDS_SOCKET_PATH"]`, and `cmds mcp`
  outside a cmds terminal says so (#90).

## [0.8.1] - 2026-11-04

Mac only; the iPhone/iPad app is unchanged from 0.4.0.

### Fixed

- Mac: `cmds mcp`: after you close the browser pane the server opened, the browser tools use the workspace's browser
  pane instead of failing, and an empty request batch gets an error (#83).
- Mac: snapshots of two browser panes in a hidden workspace taken at the same time no longer come out blank (#83).

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

[Unreleased]: https://github.com/nntokyo/cmds/compare/v0.15.1...master
[0.15.1]: https://github.com/nntokyo/cmds/compare/v0.15.0...v0.15.1
[0.15.0]: https://github.com/nntokyo/cmds/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/nntokyo/cmds/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/nntokyo/cmds/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/nntokyo/cmds/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/nntokyo/cmds/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/nntokyo/cmds/compare/v0.9.1...v0.10.0
[0.9.1]: https://github.com/nntokyo/cmds/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/nntokyo/cmds/compare/v0.8.2...v0.9.0
[0.8.2]: https://github.com/nntokyo/cmds/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/nntokyo/cmds/compare/v0.8.0...v0.8.1
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
