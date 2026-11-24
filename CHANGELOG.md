# Changelog

All notable changes to cmds are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Browser sign-ins are kept per workspace: a workspace created from now on gets its own login profile for the
  browser panes opened in it, unless one was chosen (Settings › General › Browser › Separate sign-ins per workspace,
  on). Existing workspaces keep the profile they used, so nothing has to be signed in again; one switches only when
  asked. A page in the shared data on a site signed in there (X, Amazon, GitHub, Google, note…) shows a notice with
  **Use This Workspace's Profile**, and agents get a warning, so no workspace acts as another's account (#436)

- Browser panes: agents can give files to a page, into a file field as if chosen or dropped on a drop zone
  (`cmds browser upload`, MCP `browser_upload`). Only into a browser pane their terminal opened, never from where
  secrets are kept (`~/.ssh`, `~/.aws`, `~/.claude*`, `.env`, keys, credentials, `.git`), and every upload is noted in
  `uploads.log` and shown in the sidebar (#434).

- Hangs are recorded: when cmds' main thread stops answering for 30 s, a sample of every thread goes to
  `<support dir>/hangs` (with `hangs.log`), and meanwhile `cmds ping` says "running but not responding" instead of
  timing out (#430).

- Schedules: a missed run says why, "the Mac was asleep" or "cmds was not running", and its notification has
  **Run Now** (#426).

- Schedules: **Run when the Mac is back, until the next time** (`--late next`): a weekly schedule whose time passed
  while the Mac slept runs once when it wakes, as long as its next time has not come, so a morning report is not lost
  and never runs twice (#424).

- Waiting for a command in a terminal pane: `cmds wait` (exits with the command's exit code) and MCP `terminal_wait`
  (exit code, duration and the last lines) wait until the command typed into a pane finishes, from the shell
  integration, so agents no longer read the pane over and over; panes report their `lastCommand` (#422).

- iPhone and iPad: a browser pane showing a page only the Mac can load (its localhost) shows a picture the Mac takes,
  as the pane shows it or at iPhone, iPad and desktop sizes (loaded again off screen on the Mac), to check a dev
  server's layouts from the phone (#420).

- iPhone and iPad: the workspace list shows changes and commits ahead / behind, the pull request and its checks, files
  another worktree changed too, and notification text in its level's colour and symbol, as the Mac's sidebar (#418).

- SSH panes: ⌘-click on the server's `http://localhost:5173` opens the page in a browser pane through a port forward
  you started (`ssh -L`, or `LocalForward`), never this Mac's own localhost; without one the sidebar shows the
  `ssh -N -L` command to start (#416).

- Menu shortcuts can be changed: `cmds shortcuts` lists them, `cmds shortcuts set splitRight ctrl+opt+d` gives an item
  another key (`""` none) and `reset` brings back the defaults. A key another item has is refused; changes apply at
  once and are kept (#414).

- Notification levels: sidebar text is green with `✓` for a success, orange with `⚠︎` for a warning and red with `✗`
  for an error, whose pane ring is red too. A long command that failed is an error and one that succeeded a success;
  `cmds notify --level`, `cmds status --level` and MCP `set_status` choose one (#412).

- Workspace › Environment Variables…: variables for the terminals opened in a workspace, saved with the session.
  Secrets stay in the Keychain (`cmds env secret NAME`), referenced as `keychain:service/account` and read when a
  terminal opens, never with a Keychain dialog (#410).

- Project commands: a `.cmds.json` lists a project's commands (dev server, test watcher) and pages; Workspace › Run
  Project Commands opens them in terminals and a browser, after showing a new or changed file; `cmds project show|run`
  for scripts and agents runs only a confirmed one (#408).

- Sidebar: the branch's pull request and its checks from your GitHub CLI (`#405 ✓`, `✗`, `●`, `merged`), asked at
  most every 2 minutes per branch in GitHub repositories (Settings › Sidebar › Pull request and checks; #406).

- Edit › Find › Find in All Terminals… (⇧⌘F): the lines of every terminal's scrollback that contain the text, with
  their workspace and pane; Return shows the pane with its find bar (#404).

- A command that ran 30 s or more (Settings › General › Notify when a command finishes: 10 s to 5 minutes, or never)
  and ends in a pane you are not looking at lights the pane and notifies, saying when it failed (shell integration).

- Sidebar: a thin progress bar under a workspace while a program in it reports progress (OSC 9;4): the percent done,
  red on failure, sliding while unknown; also `progress` in the API's pane info (#401).

- Sidebar: after a local workspace's branch, `±3 ↑1 ↓2` shows uncommitted paths (orange) and commits ahead / behind
  the upstream, with a tooltip; also `gitSummary` in the API's workspace info (#397).
- Sidebar: `⚠︎N` (red) when another worktree of the same repository changed some of the same files, with the other
  workspaces and the files in the tooltip, so agents in separate worktrees can be stopped before their branches
  conflict; also `gitOverlaps` in the API's workspace info (#399).

- Network requests of browser panes: `cmds browser network` and MCP `browser_network` list the page's fetch and XHR
  calls with method, status, duration, size and failure (`--failed` for failing API calls; `--resources` adds
  scripts, styles, images and the document), recorded from the start of each page (#395).

- Agents can ask you to point at an element: MCP `browser_point` and `cmds browser point --prompt "…"` show the
  request in the browser pane and return the element you click (selector, box, styles, components, source line).

- Point at Element (⇧⌘C, the scope button in the browser toolbar): click an element of the page, write what is wrong
  with it, and the agent in the terminal gets your words with the element's selector, box, styles, the component and
  source line when the dev build tells them (React, including React 19 through the dev server's source maps; Vue,
  Svelte, Angular, Astro, react-dev-inspector) and a screenshot with the element outlined in `.cmds/reports/`. An agent
  asking a question, or no agent, gets nothing typed: the report goes to the clipboard. Elements inside same-origin
  iframes (Storybook's preview) and in any frame of the responsive view (named in the report) are picked themselves. The
  pane's notice then follows the report: working, asking, finished (with the first line of the reply), with Show
  Terminal. Idea from FixKit (github.com/ostiums/fixkit).

### Fixed

- Browser panes an agent works on keep rendering when they are not on screen (cmds behind other windows, another
  workspace shown, a background tab, the display asleep): pages such as X no longer draw nothing, and agents no longer
  need to switch the shown workspace (#432).

- Schedules: "Continue" (also Continue When It Resets) no longer skips with "an agent was running in the pane" when
  that agent is the session to continue and its status line had gone quiet; the prompt is pasted into it (#428).

- Japanese: "Never" in Settings › General › Suspend background tabs and in a schedule's notifications read "再開しない"
  (do not resume); it is "しない".
- `cmds-remote.sh` (version 2) on macOS servers: a hook, notification or command could fail with "app not reachable"
  when the app answered and closed the connection before the script finished sending (python3 transport, ENOTCONN).
- In terminals of a second copy of cmds (a newer download, a Debug build), `cmds`, its hooks and `cmds mcp` ran the
  installed CLI of `/Applications/cmds.app`, which login shells put first on `PATH`; the CLI now hands off to the
  app's own (`CMDS_CLI_PATH`). Takes effect once the installed CLI has this change.

## [0.32.0] - 2026-11-22

### Added

- Browser login profiles: each named profile keeps its own cookies, storage and sign-ins, panes of the same profile
  share them, and panes without one share the default data as before. Set from the person button in the browser
  toolbar, `cmds browser profile` / `cmds browser open --profile`, or the MCP tools `browser_profile` and
  `browser_open` (`profile`), so agent sessions can keep their sign-ins apart or share them.

## [0.31.0] - 2026-11-22

The iPhone/iPad change (#378) comes with the next App Store version of the companion.

### Added

- Tabs: an overflow menu (⌄) for tabs that do not fit, tooltips with the page address or path, Pane › Move Tab Left /
  Right (⌃⇧⌘[ / ⌃⇧⌘]) (#374).
- Background browser tabs unused for 30 minutes are suspended (unloaded until shown; Settings › General › Suspend
  background tabs); never pages with unsaved input or playing media (#375).
- Bookmarks bar from Microsoft Edge, Brave, Vivaldi, Arc or Safari (Settings › General › Bookmarks from), and every
  Chrome bookmark's icon from Chrome's icon database (#376, #377).
- Developer tools: a text filter and Copy in the console (height remembered), a header line in source tabs (address,
  HTTP status, content type, encoding), SEO loading measures (LCP, CLS, time to first byte, size, elements), hreflang
  and sitemap checks, and `cmds browser seo --crawl N` for up to 50 linked pages (#380).
- iPhone: the pane selector shows the Mac's tab groups (#378).
- Claude harness: `cmds harness report|suggest|skill|review` and Window › Claude Harness read what `~/.claude` holds
  (sessions, memory, CLAUDE.md, skills, MCP servers) and propose an improved CLAUDE.md, a skill from memory and a daily
  review through `claude -p` (no tools, isolated, secrets masked); applied only after you saw the diff, with a backup.
  A skill keeps only its name and description in the front matter, and lines that run code, skip permissions or reach
  other places are pointed out before applying (`--yes` then refuses).
- Browser: a "Not Secure" icon before the address of plain-http pages on the internet.

### Changed

- Duplicate Tab keeps the pane's settings (device size, responsive view, file watch, Claude account, hidden files,
  Follow Terminal) (#379).
- Agents' tab reuse and cap go on after a relaunch (#375).

### Fixed

- Browser panes could not load plain-http pages other than local ones (App Transport Security); WebKit's content is
  now exempt, the app's own connections stay https-only. Plain-http sites get their favicon too (#376).
- Settings › General said nothing when a Chrome profile's account bookmarks are only encrypted but local ones exist
  (#377).
- Suspended tabs now free their page's process and never come from a form, a load error or a page with a pop-up,
  a code editor or changed fields in frames; Reload Tab on a suspended tab loads it.
- SEO crawl: links that sign out or delete, `download` and `nofollow` links are not followed; robots.txt `*`, `$` and
  `Allow` rules, page encodings, redirects, sitemap indexes and gzip sitemaps are understood; files that are not HTML
  no longer count as pages without a title.
- Favicons are not fetched from this Mac or the local network for internet pages (also not through a redirect).

## [0.30.0] - 2026-11-22

Mac only; the iPhone/iPad app is unchanged.

### Added

- Tabs show the page's icon (favicon); the Chrome bookmarks bar shows the icons of sites visited in browser panes.
- Right-click a tab: Close Tab, Close Other Tabs, Close Tabs to the Right, Duplicate Tab, Reload Page, Move to New
  Workspace.
- The console drawer can be resized by dragging its top edge.
- View Page Source of a local page (`file://`) shows the file.
- `cmds browser source --fetch` (`browser.source` `fetch`, MCP `browser_source` `fetch`).

### Changed

- Agents' browser tabs (MCP `browser_open`, `cmds browser open --reuse`): opening a page an agent already has open
  reuses its tab (reloaded), and an agent keeps at most 10 such tabs (its oldest background ones close; tabs you open,
  or where you typed an address, are never closed for you).
- After a relaunch, browser tabs that are not shown load their page only when first shown.
- View Page Source no longer asks the server again: it shows the cached HTML, or the DOM with a note when the page is
  not cached (`--fetch` asks the server), so one-time links are not repeated.
- The SEO report tab is in the app's language (Japanese too); the CLI and MCP keep English.
- Settings › General says when Chrome keeps a profile's bookmarks only encrypted.

### Fixed

- The iPhone/iPad app's source failed to build since 0.29.0 (the new preview format); the released app was not
  affected.

## [0.29.1] - 2026-11-20

Mac only; the iPhone/iPad app is unchanged.

### Fixed

- Chrome bookmarks bar: bookmarks saved in the Google Account (`AccountBookmarks`, what signed-in profiles of newer
  Chrome versions use) are shown too, before those kept on the Mac. Such profiles showed "No Chrome bookmarks found".

## [0.29.0] - 2026-11-20

Mac only; the iPhone/iPad app is unchanged (it shows the tab that is shown on the Mac).

### Added

- Tabs: any place of the layout can hold several panes as tabs (terminals, browsers, previews, files panes), with a
  tab bar showing each tab's kind, title and attention. **Pane › New Tab** (⌘T; the tab bar's +) adds a browser tab
  in a browser pane, else a terminal; ⌥⌘] / ⌥⌘[ go to the next / previous tab; ⌘W, the × or a middle click closes
  one. Drag a tab like a pane, onto a tab bar to join it or onto the top strip of a pane to make a group with it.
  Tabs that are not shown keep running, and focusing one brings it to the front. Tabs are restored with the session.
  `cmds tab`, `cmds pane move --beside P --tab`, `pane.new_tab`; `PaneInfo` has `tabs` and `background`.
- Browser panes open new pages as tabs (on by default, Settings › General › Open new pages in tabs): a
  `target="_blank"` link becomes a tab of its pane, and `cmds browser open` or an agent's `browser_open` a tab of the
  workspace's browser pane, instead of a new split each time.
- Developer tools in browser panes (the toolbar's **</>** button, View › Developer): **View Page Source** (⌥⌘U) in a
  tab with line numbers and coloured markup; a **console drawer** (⌥⌘C) with the page's messages and errors by level
  and a JavaScript line; an **SEO report** (title, description, headings, canonical, robots and robots.txt, Open Graph,
  alt, structured data, https…) with a score. Also `cmds browser source`, `cmds browser seo`,
  `cmds browser console --show`, `browser.source` / `browser.seo`, and the MCP tools `browser_source` and
  `browser_seo` (`browser_console` takes `show`).
- Google Chrome's bookmarks bar in browser panes (Settings › General › Show Chrome bookmarks, Chrome profile): links
  load in the pane, ⌘-click opens a tab, folders are menus with Open All in Tabs. Read only; Chrome's sign-ins and
  passwords are not shared. When macOS refuses to let cmds read Chrome's data, Settings explains how to allow it (Full
  Disk Access).

## [0.28.1] - 2026-11-17

Mac only; the iPhone/iPad app is unchanged.

### Fixed

- Assistant: "how many workspaces" / 「ワークスペースはいくつ？」 (also agents and sessions) is answered from the
  workspaces: how many there are, how many run an agent and how many of those wait for you. It went to the on-device
  model, which could not count them.

## [0.28.0] - 2026-11-17

Mac only; the iPhone/iPad app is unchanged.

### Added

- Assistant: NVIDIA's voices for spoken answers. With a free API key from build.nvidia.com typed into Settings ›
  Assistant › NVIDIA API key (kept in the keychain), the Voice list offers NVIDIA's Magpie TTS Multilingual voices for
  the app's language (Japanese: eight, such as Ray and Isabela). Only the answers' text is sent to NVIDIA, never what
  you say; the Rate setting applies as it plays. Without the key or a connection the system voice speaks, and Settings
  shows the last problem.

### Fixed

- Assistant: an answer that was only a marker the on-device model made up (such as `[[COUNT]]`) was read out; it is
  no longer spoken.

## [0.27.3] - 2026-11-16

Mac only; the iPhone/iPad app is unchanged.

### Fixed

- Claude accounts: a Claude Code whose config folder has no cmds status line (a `~/.claude` made again by signing in
  afresh, typically, under a plain `claude`) never reported to cmds, so its session could not be switched: the pane
  showed no session or kept an old one from before. cmds now notices such a Claude Code after 45 s and offers
  **Set Up for cmds** for its folder once (adding it as an account when it is none), drops the old session, and the
  switch says why instead of moving the old one (#360).
- Claude accounts: sharing sessions now copies the sessions of an account's own `projects` folder (renamed to
  `projects.before-cmds-<date>`) that the shared folder lacks, so they can be continued under another account at
  once; nothing is overwritten (#360).
- Claude accounts: an account on `~/.claude` now runs as a plain `claude` (resumed with `env -u CLAUDE_CONFIG_DIR`,
  its sign-in read from `~/.claude.json`): with `CLAUDE_CONFIG_DIR=~/.claude` Claude Code used another sign-in, so
  the account shown and the one the resumed session ran under could differ (#360).

## [0.27.2] - 2026-11-16

Mac only; the iPhone/iPad app is unchanged.

### Fixed

- Claude accounts: a Claude Code session that was started but never given a prompt (no transcript yet, e.g. one
  resumed at launch and not used) could not be switched to another account ("share sessions first", although they
  were shared); it now switches by starting Claude Code anew under the account. Resuming such a session (at launch,
  Recent Sessions) starts Claude Code instead of typing a `claude --resume` that fails with "No conversation found"
  (#357).

## [0.27.1] - 2026-11-16

Mac only; the iPhone/iPad app is unchanged.

### Fixed

- Agents: the MCP server is also registered with the Antigravity CLI (`agy mcp add`), for a Claude account signed in
  while cmds runs (when its Claude Code first reports, not only at the next launch), and again for a config folder
  that was made again (it was remembered by path, so a recreated folder stayed without it). A registration asked for
  while one runs is no longer dropped (#354).

## [0.27.0] - 2026-11-16

Mac only; the iPhone/iPad app is unchanged.

### Added

- Agents: cmds registers its MCP server (`cmds mcp`) by itself with Claude Code (plain `claude` and every Claude
  account, each of which keeps its own MCP servers) and Codex, at launch and when an account is added, so agents in
  cmds terminals have browser panes, previews and terminal panes as tools without `claude mcp add`. Once per config:
  one you removed is not added again; Settings › Agents turns it off (#351).

## [0.26.0] - 2026-11-15

Mac and iPhone/iPad (the iPhone/iPad entries need the App Store build 0.26.0).

### Added

- Browser panes: when a page asks for a passkey or security key, a notice says that browser panes cannot use them yet
  (Apple has not granted the entitlement, #162), with Open in Safari (#336).

- Browser panes: find in page. ⌘F opens a find bar over the page (⌘G / ⇧⌘G next / previous, Match Case), and
  `cmds browser find TEXT` does the same from a terminal (#338).
- Browser panes: HTTP Basic and Digest sign-in asks for a user name and password in a sheet (kept until cmds quits,
  never saved) (#338).

### Fixed

- Claude accounts: when Claude in Chrome cannot connect because its host script went with a config folder that was
  made again (the browser's manifest names `<config dir>/chrome/chrome-native-host` of one account), cmds says so when
  it starts, in Settings › Claude Accounts and when Claude Code starts in a pane, and offers to put the script back
  (nothing is overwritten). `cmds accounts` shows it and `cmds accounts chrome` repairs it (#347).
- Browser panes: a page that does not load (connection refused, server not found, too many redirects, an untrusted
  certificate) shows a notice with the address, the reason and Reload instead of leaving the previous page without
  a word; the address bar keeps the failed address and `cmds browser url` reports it with the reason. Untrusted
  certificates are refused, with Continue Anyway for that server until cmds quits (#338).
- Browser panes: when a page's web content process ends, the page reloads (once a minute, else a notice with Reload)
  instead of leaving an empty pane, address bar and `cmds browser url` (#338).
- Browser panes: the address bar opens `/path` and `~/path` as files, keeps `mailto:` and `tel:` (handed to Mail /
  FaceTime), searches for `1.5` and `README.md` instead of opening them as sites, and opens `localhostfoo.com` over
  https. `cmds browser navigate` and `browser open` fail for input with nothing to load (`''`,
  `http://exa mple.com`) instead of exiting 0 (#338).
- iPhone/iPad: a paired Mac no longer asks to pair again when its network name or address changes (macOS renames the
  service to "Name (2)" after a name conflict, e.g. around an update; the Mac is renamed; it was paired by address
  and is later found on the network). The phone recognises the Mac by the identity it pinned, and the pairing and
  the remote access settings follow. After pairing anew, the remote access settings are kept (#325).
- Mac: Bluetooth sync no longer stays off after macOS refuses it once ("No resources available for L2CAP"); cmds
  tries again after 5 s, 15 s, 1 min, then every 5 min, and `cmds sync` says when (#343).
- iPhone/iPad: pairing without the camera no longer hangs at "Reading the Mac's identity…" (#331).
- Browser panes: `cmds browser eval` (and MCP `browser_eval`) gives up after a timeout (`--timeout`, default 30 s,
  at most 300) instead of waiting for good. When the script never yields (`while (true) {}`), the page is reloaded in
  a new web view and its stuck WebContent process ends, so the pane works again; before, it stayed dead until cmds
  quit (#338).
- Browser panes: `cmds browser wait-for` (MCP `browser_wait_for`) answers in time when the page navigates while it
  waits, and goes on waiting on the new page; `--timeout 0` checks once instead of being refused (#338).
- Browser panes: `cmds browser snapshot -o -` writes the PNG to stdout instead of a file named `-`; with several
  devices it is refused (#338).
- Closed browser, preview and files panes are freed: each closed browser pane kept its web view and a WebContent
  process (about 30 MB) until cmds quit (#338).
- API and CLI errors from WebKit and the system (e.g. a page that did not load) are in English, not the app's language
  (#338).

## [0.25.1] - 2026-11-15

Mac only; the iPhone/iPad entries above wait for the next App Store build.

### Fixed

- Claude accounts: after a switch, the resumed session shows its transcript again, including the previous account's
  limit messages ("You've hit your 5-hour limit · resets …"); cmds took them for the new account's limit, so every
  account ended up limited and automatic switching stopped. Limit messages shown before Claude Code works on a
  prompt under the new account are now ignored (#329).

## [0.25.0] - 2026-11-15

Mac only; the iPhone/iPad app is unchanged. All of it is #320.

### Added

- Claude accounts: **Sign In** (the sidebar's account menu, Settings › Claude Accounts, `cmds accounts login NAME`)
  opens a workspace under the account and runs `claude auth login`.
- Claude accounts: **Set Up for cmds** (the account menu, Settings › Claude Accounts, `cmds accounts setup NAME`)
  adds cmds's status line and hooks to an account's `settings.json` when they are missing (the previous file is
  kept). Accounts that need it are shown as "not set up": without it their workspaces had no account button and
  never switched.
- Claude accounts: the sidebar's account menu also has **Switch Automatically at the Limit**, **Clear Limit** and
  **Share Sessions…**, so accounts can be handled without the command line.

### Fixed

- Claude accounts: two accounts signed in to the same Claude account share one limit. They are shown as "same sign-in
  as …" (menu, Settings, `cmds accounts`), are marked limited together, and a session is never switched between them
  (it used to "switch" and stop at the same limit).
- Claude accounts: the limit notice of Claude Code 2.1.3xx (`Usage limit reached · continuing automatically at
  4:50pm`) gives the reset time (it was estimated as five hours later, so the account stayed "limited" and "Continue
  at" came too late); `Usage limit reset · Continuing automatically` ends the limit shown above it.
- Claude accounts: an account whose config directory does not exist is never chosen to continue with (the pane said
  "share sessions first" instead of switching to the next account or offering to continue at the reset), nor by
  `--account auto`.

## [0.24.3] - 2026-11-15

Mac only; the iPhone/iPad app is unchanged.

### Fixed

- Claude accounts: Claude Code's "Context limit reached" (and other limits of the conversation) no longer counts as
  the account's limit, so it no longer switches the session to the next account (#315).
- Claude accounts: a reset time whose time zone wraps onto the next row (`(America/Ne` / `w_York)`) is read in that
  zone, not the Mac's (#315).
- Claude accounts: after a switch, the next account hitting the same limit message in the same pane is detected;
  the previous account's message shown again by the resumed session is still ignored (#315).
- Claude accounts: when the account offered by "Continue with …" hits its limit too, the bar offers the next free
  one instead of continuing with the limited account (#315).
- Claude accounts: Share Sessions after moving an account whose `projects` links to a folder outside the accounts to
  the top keeps the accounts' shared folder, instead of moving it aside (#315).

## [0.24.2] - 2026-11-15

Mac only; the iPhone/iPad app is unchanged.

### Fixed

- Voice assistant (Mac): a command-line tool you chose not to pause for paused it again after an upgrade (Homebrew
  runs it from a versioned folder); it is now matched by its file name (#310).
- Antigravity limits: when agy's status line runs cmds through the PATH or a path that is gone, cmds now says so once
  in a notification at launch; clicking it opens Settings › Agents (Update). The file is not changed (#310).
- Website guide: Don't Pause for … and Settings › Assistant › Remove are described (#310).

## [0.24.1] - 2026-11-15

Mac only; the iPhone/iPad app is unchanged.

### Added

- Voice assistant (Mac): Settings › Assistant › Remove takes one app off the list of apps it never pauses for, or all
  of them. A command-line tool that records (sox, ffmpeg) is named by its file and can be ignored too (#305).

### Fixed

- Voice assistant (Mac): two copies of the same cmds open at once both answered; the one opened later now pauses while
  the other listens (#305).
- Antigravity limits: a status line that runs `cmds hook agy-status` through the PATH or a path that is gone (agy
  outside cmds may run an old copy or a broken link) now shows Update in Settings › Agents, which writes this app's
  full path (#305).

## [0.24.0] - 2026-11-14

Mac only; the iPhone/iPad app is unchanged.

### Added

- Voice assistant (Mac): when it pauses for an app that keeps the microphone open, the menu bar offers Don't Pause
  for that app; it listens again at once and ignores that app from then on. Settings › Assistant lists the ignored
  apps with Clear (#295).
- Siri: cmds can also be called Commands, C M D S, シーエムディーエス or コマンズ in the Shortcuts phrases.
- Sidebar accounts: a workspace with several Claude Code panes shows a section per pane in the account menu; while
  a switch waits for the session to finish, the menu offers Cancel Switch (#296).

### Fixed

- Sidebar accounts: the compact sidebar now shows each session's account icon too, and the icons update at once when
  you add, remove or reorder accounts (#296).
- Voice assistant (Mac): with a cmds Dev build open next to cmds, only one assistant answers; the Dev build pauses
  while the released app's assistant listens (#295).

## [0.23.0] - 2026-11-14

Mac only; the iPhone/iPad app is unchanged.

### Added

- Antigravity limits: Settings › Agents › Antigravity limits › Set Up… adds `cmds hook agy-status` to agy's status
  line (`~/.gemini/antigravity-cli/settings.json`; a copy of the file is kept, and it asks before replacing another
  status line). agy running in a terminal outside cmds now sends its quota too, and the last quota is kept across
  restarts until its windows reset. agy reports it only while an interactive session runs, not with `agy -p` (#290).

### Fixed

- Sidebar footer: Antigravity's limits were cut off ("Antigra", "Gen"). It now shows `agy` with `5h` / `7d` (other
  model groups by name, `3P 5h`), and every agent's meters start at the same place (#290).

## [0.22.0] - 2026-11-13

### Added

- Mac (macOS 26 and later): a voice assistant, "JARVIS" (beta, free for now). Turned on in Settings › Assistant or
  the menu bar item, it listens on this Mac for its name (ジャービス / Jarvis) and answers in Japanese or English:
  which workspaces need you, what an agent is doing (Apple's on-device model), a detailed summary on request
  (`claude -p`). It can reply to an agent, approve or pick an option and start Claude Code or Codex, always shown first
  in a floating HUD and run only after yes or Return (Return or a click for deletes, pushes, deploys and SSH panes)
  (#243). Questions that need the web (weather, news, prices, "search…" / 「検索して」) go to Claude Code with web
  search only (Settings › Assistant › Use Claude for web questions, on by default; uses your Claude Code usage), also
  when the on-device model finds it needs current information. It goes through every session ("check all sessions" /
  「全部のセッションを確認して」, also only the waiting or working ones) and acts on several at once ("approve all",
  「apiとwebに…と伝えて」) on one card, and takes instructions in your own words ("tell the api agent to fix the failing
  test"): Claude Code without tools works out the target and the message, always shown on the card before anything is
  sent (Settings › Assistant › Use Claude to understand free commands). It can speak with your own Personal Voice
  (Settings › Assistant › Use my Personal Voice…), and uses the system voice for a language your Personal Voice does
  not speak.
- Voice assistant (Mac): start Claude Code or Codex with work to do. 「cmds のリポジトリで Claude Code を起動して、ログイン
  画面のテストを書かせて」, "start Claude in api and have it fix the failing tests": one card shows the folder, the agent
  and the exact first prompt, and the new workspace runs `claude '<prompt>'` (one quoted argument, no other flags)
  after yes or Return. The place is a workspace (its folder) or a folder of that name in your project folders
  (Settings › Assistant › Project folders; ~/Source, ~/Developer, ~/Projects and ~/src by default; repositories
  first; several fit: it asks which). 「api で Claude にこのバグを直させて」 gives the task to the Claude already running
  there, else starts one. For a session it started with a task or gave an instruction to, it says when the agent is
  done or asks you something (Settings › Assistant › Report on tasks I gave, on by default) (#243).

- Voice assistant (Mac): faster answers. An utterance ends about 0.8 s after you stop speaking (relative to the room's
  noise, so also in a café or on a platform), the on-device model warms up while you speak, web questions get a short
  「調べます。」 at once and the answer is spoken sentence by sentence as Claude writes it; web answers are reused for
  10 minutes (#248).
- Voice assistant (Mac): a small orb while it waits for its name (Settings › Assistant › Show while waiting): dim
  while paused, orange when a workspace needs you, grows into the HUD when you speak; click it for the last answer,
  drag it anywhere.
- Voice assistant (Mac): loud places. Settings › Assistant › Listening: Automatic, Automatic with noise reduction
  (macOS voice processing) or Push to talk (hold ⌥⌘J, no name needed, letting go ends the request at once);
  Microphone: Automatic (a headset such as AirPods when connected), System Default or one device; in a loud room a
  name speech recognition is unsure of is ignored (#270).
- Voice assistant (Mac): it pauses by itself while another app uses the microphone (a call in Zoom, FaceTime, Meet…)
  and listens again when the call ends; the menu bar says which app (Settings › Assistant › Pause while another app
  uses the microphone, on) (#278).
- Voice assistant (Mac): Siri and Shortcuts. Agent Status (「cmdsの状況」) says and returns the short status; Ask the
  Assistant (「cmdsに頼む」) hands it a request and returns its answer, actions still waiting for your yes on the Mac. A
  morning summary is a Shortcuts automation (#282).
- Sidebar: each Claude Code session shows its account as a coloured icon and name; click it (or right-click the row ›
  Claude Account) to continue the session with another account, as `cmds accounts switch` does (#284).
- Browser panes: Reload on File Changes (the eye button in the toolbar, View menu, `cmds browser watch`, API
  `browser.watch`, MCP `browser_watch`) reloads a local page (`file://`, `localhost`) when files in the workspace's
  folder (or one you choose) change, debounced, ignoring `.git`, `node_modules`, build folders and dot files, and only
  while the pane is on screen; remote pages reload only when you turn that on (#252).

- Terminal panes: Pane › Export Scrollback… (`cmds pane export`, API `pane.export`) writes the whole scrollback to a
  file as plain text, or with colours as ANSI escape codes; the file is readable only by you (0600), an existing file
  is replaced only when asked, and long histories are read in chunks while the pane keeps running (#253).

- iPhone/iPad 0.15.0 (on the App Store since 2026-11-11, listed here with the Mac release it was written for): browser
  panes show their page in a web view (Reload, Open in Safari), loaded by the phone itself; pages
  only the Mac can reach (`localhost`, files) say so instead. Preview panes render Markdown and diffs like the Mac and
  show other text files as text; the same for files opened while browsing a files pane.

### Fixed

- Voice assistant (Mac): it no longer hears itself. Its own long answer, picked up by the microphone and transcribed
  after it finished, was sent to Claude again; now, while it speaks and a second after, only its name counts, and
  what is mostly its own words is dropped. Its name interrupts it at any time (while speaking, thinking or searching
  with Claude, also to answer a card) and takes the new request at once, stopping Claude's search; without the name
  only short follow-ups count, from when it has finished speaking. Answers are short: only what was asked, in a
  sentence (「明日の船橋は晴れ、最高20度、最低9度です。」), the status as 「入力待ち2件: api, api-v2。作業中1件: web。」, one sentence
  per session; of a long answer only the first sentence is spoken and the HUD shows the rest. Claude Code runs for it
  without your CLAUDE.md, hooks, output style or plugins, saves no sessions, uses Sonnet (Haiku for free commands),
  and its runs no longer show up as agent activity in cmds (#243).
- Voice assistant (Mac): misheard names. Speech recognition now expects the assistant's names, Claude Code, Codex,
  cmds and your workspaces' names; 「クロトコート」 / "cloud code" count as Claude Code, and a workspace name heard in
  katakana or as other letters (エーピーアイ, EPA for api) finds the workspace when no other is called so (otherwise
  it asks which). 「Claude Code を立ち上げて」 without a place starts it where the last request was about or in the
  selected workspace; several requests in one sentence (「Claude Code を立ち上げて、API の進捗を教えて」) are done one
  after the other, the next after the card. The on-device model no longer apologises that it cannot start apps: a
  request to act goes to the command interpreter instead (#243).
- Browser reload on file changes: a watched folder that is removed or moved, or one macOS cannot watch, no longer
  stops the reloads silently. The eye button turns red with the reason in its tooltip and menu, and
  `cmds browser watch` / `browser.watch` report it (`error`, `active: false`); watching resumes when the folder is
  back. **Choose Folder…** and **Also Reload Remote Pages** beep when they fail, like the button itself (#259).

## [0.21.0] - 2026-11-11

Mac only; no iPhone/iPad release (the Unreleased entry above ships with the next companion release).

### Added

- Browser panes: pop-ups open in a small window that keeps its link to the page (Sign in with Google / Apple, OAuth
  and payment pop-ups), `target="_blank"` links open in a new browser split, `alert` / `confirm` / `prompt` appear as
  sheets naming the page's host, file fields open the file panel, and downloads are saved to the Downloads folder
  with a notice in the pane (#235).

### Fixed

- A Codex usage limit reached without a reset time now expires a day after it was last seen, not first seen (#231).

### Changed

- Building from source: Debug builds are a separate app, "cmds Dev" (`tokyo.n-n.cmds.dev`, URL scheme `cmds-dev`),
  so they no longer take over the release's macOS privacy permissions such as Screen Recording (#236).
- Building from source: Debug builds keep their workspaces, sessions and API socket in
  `~/Library/Application Support/cmds-dev` (their bundled `cmds` CLI and widget follow), and macOS no longer reopens
  them, or isolated instances, after a restart: a Debug build reopened without its environment had restored the
  installed cmds' workspaces and resumed its Claude sessions a second time (#247).

## [0.20.0] - 2026-11-11

Mac only; no iPhone/iPad release (the Unreleased entry above ships with the next companion release).

### Added

- A Codex account over its usage limit shows as Codex at 100 % with the reset time from Codex's message (rings,
  sidebar footer, red dot, `cmds agents`, schedules waiting for Codex's limit), until the reset passes or newer
  figures arrive. The last known Codex limits are kept across relaunches, and limits are also picked up from recent
  Codex sessions not running in a pane (`codex exec`, `codex review`) (#227).

## [0.19.0] - 2026-11-11

Mac only; no iPhone/iPad release (the Unreleased entry above ships with the next companion release).

### Added

- Move panes within a workspace, to another workspace or into a new one, with what runs in them (#218): drag the grip
  that appears at a pane's top edge onto another pane's edge (split there) or centre (swap), onto a workspace in the
  sidebar, or out of the window (new workspace); Pane › Swap with Pane Left / Right / Up / Down (⌥⇧⌘ + arrow keys),
  Move to Workspace…, Move to New Workspace; `cmds pane move` / `cmds pane swap` and `pane.move` / `pane.swap`.

## [0.18.0] - 2026-11-11

Mac only; no iPhone/iPad release (the Unreleased entry above ships with the next companion release).

### Added

- Menu bar: answer a waiting agent without switching to cmds (#213). Choosing a workspace in the menu bar menu opens a
  panel under the icon with a live view of the pane's last lines, the agent's numbered choices as buttons (Claude
  Code, Codex; keys 1–9 pick them), a reply field (Return sends; empty, it presses Return) and Esc / ↑ / ↓ / ⏎ / ⌃C
  keys. ⌘↩ opens the pane in cmds, ⌘↑ / ⌘↓ go to the other workspaces, Esc or a click elsewhere closes it. Hold ⌥ in
  the menu to open a workspace in cmds as before; Settings › Menu Bar › Reply from the menu bar turns the panel off.

## [0.17.0] - 2026-11-10

Mac only; no iPhone/iPad release (the Unreleased entry above ships with the next companion release).

### Added

- Memory (#193): `cmds stats` and `system.stats` show swap used (`swapUsedBytes`, `swapTotalBytes`). `cmds top` lists
  the heaviest processes started from cmds terminals (memory, CPU, pane, workspace, command; socket
  `system.processes`), also *leftover* ones whose pane or workspace was closed but which still run (a dev server
  started with `&`, a test runner, a browser driver); `cmds top --leftover` lists only those. `cmds kill PID [--force]`
  (socket `system.kill_process`) stops one of them and refuses any other pid, checked by the app. The sidebar footer
  shows "N leftover processes · X GB" with a list and Stop buttons, the workspace usage tooltip its three heaviest
  processes, and a notification warns when the memory pressure stays at warning for a minute (at most every 30
  minutes; Settings › General › Memory). `cmds mcp` gains `system_stats` (with `advice: ok|wait` before heavy jobs)
  and `list_processes`. Not available from SSH panes.

## [0.16.0] - 2026-11-10

Mac only; no iPhone/iPad release (the Unreleased entry above ships with the next companion release).

### Added

- `cmds mcp`: terminal tools for agents that only speak MCP (#171). `terminal_split` opens a terminal pane beside the
  agent's terminal without taking the focus and types a command into its shell (the pane and its output stay when the
  command exits); `terminal_read` (screen or last lines with scrollback) and `terminal_send` (text, Return) reach only
  terminal panes opened from the agent's terminal (`terminal_split`, `cmds split`), never its own, the user's or
  another agent's, checked by the server and by the app (`openedBy` on `pane.read_text` / `pane.send_text`);
  `list_panes` and `list_ports`. Terminal panes now remember the terminal they were split from over the API, so
  `close_pane` closes them too.

- Mac: clicking a listening port in the sidebar opens it in a browser split of that workspace; `cmds ports` lists the
  ports with their workspaces (#171).

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

- Mac: DevTools for agents in browser panes. `cmds browser console` (MCP `browser_console`) returns the page's
  console messages, uncaught errors and unhandled promise rejections, recorded from the start of each page;
  `cmds browser tree` (`browser_snapshot_tree`) the page as roles and names with refs, which `cmds browser click` /
  `fill` act on (also by CSS selector; fill sends input and change events); `cmds browser wait-for` waits for an
  element or text with a timeout. Works on pages with a strict Content Security Policy. cmds › Settings… › General ›
  Allow Safari's Web Inspector makes browser panes inspectable from Safari's Develop menu (off by default) (#167).

### Changed

- Mac: browser pages follow the Mac's light or dark appearance by default; before, they were always dark (#168).

### Fixed

- Mac: Show Changes' diff file (in the temporary folder, `cmds-changes/<workspace>`) is deleted when its workspace
  closes, and is no longer written when the workspace closed while git ran (#176). They used to stay until macOS
  cleaned the temporary folder.

- Mac: the command palette also matches English names in a localized UI (#186). With the app in Japanese, "split"
  or "browser" found nothing; menu commands now also match their English titles and menu path, and panes their
  English kind and default title (`split` finds 右に分割, `browser` ブラウザを分割して開く and browser panes).

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

[Unreleased]: https://github.com/nntokyo/cmds/compare/v0.23.0...master
[0.23.0]: https://github.com/nntokyo/cmds/compare/v0.22.0...v0.23.0
[0.22.0]: https://github.com/nntokyo/cmds/compare/v0.21.0...v0.22.0
[0.21.0]: https://github.com/nntokyo/cmds/compare/v0.20.0...v0.21.0
[0.20.0]: https://github.com/nntokyo/cmds/compare/v0.19.0...v0.20.0
[0.19.0]: https://github.com/nntokyo/cmds/compare/v0.18.0...v0.19.0
[0.18.0]: https://github.com/nntokyo/cmds/compare/v0.17.0...v0.18.0
[0.17.0]: https://github.com/nntokyo/cmds/compare/v0.16.0...v0.17.0
[0.16.0]: https://github.com/nntokyo/cmds/compare/v0.15.1...v0.16.0
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
