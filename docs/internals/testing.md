# Testing

> How to test cmds without disturbing the instance and phone in use: unit tests, isolated Mac instances, sync tests,
> device and UI tests, and the limits for heavy jobs.

## Ground rules

- **Never test against the cmds instance you work in, or the phone you use.** Start an isolated instance
  ([below](#isolated-instances)) and use a test device or the simulator.
- Never type into (`cmds send`) or close panes and workspaces your test did not create: someone may be working in
  them, also from the iPhone. Create a dedicated workspace with `cmds new` and use the ids it returns.
- Stop what the test started (instances, servers, sshd, simulators) when done.

## Machine load

Builds and test runs are heavy (Swift compiler, Xcode, the iOS simulator). On a shared Mac:

- Run at most two heavy jobs (build, test, simulator) at the same time; queue the rest.
- Check `sysctl kern.memorystatus_vm_pressure_level` first (1 = normal). At 2 (warning) or 4 (critical) start
  nothing new and wait. `cmds stats` shows the same pressure.
- Prefer targeted runs (`swift test --filter …`, `-only-testing:`) over full suites.

## Unit tests

GitHub Actions runs the package tests and String Catalog checks on every pull request; `scripts/ci/run-local.sh` runs
the same jobs here ([ci.md](ci.md)).

| Package | Command | Covers |
|---|---|---|
| `Packages/CmdsCore` | `swift test` (in that directory) | RPC and client, models, agent usage and Claude/Codex parsing, the menu bar lists (`MenuBarSummaryTests`), agents' numbered choices for the menu bar's reply panel (`AgentPromptOptionsTests`), cells per character for the phone's grid (`TerminalCellsTests`), a style's text and background colours as the phone and the reply panel draw them (`TerminalStyleColorsTests`), the widget's file (`WidgetSnapshotTests`), session resume, keep-awake, previews, resource sampling, workspace export bundles, the remote-access policy and helper script (also: `schedule.*` refused on remote sockets), schedules (`ScheduleCalendarTests`: weekly in Tokyo and New York, the DST gap and repeat, a leap day, `limitReset` following a limit, catch-up; `ScheduleRunTimingTests`: every run state, busy / asking / subagent / switch / queued resume, another session or program in the pane; `PaneReadinessTests`: the one readiness check shared with resuming and account switching; `ScheduleCodableTests` / `ScheduleValidationTests`: file format, lenient decoding, newer versions read only, moving a damaged file aside, history retention, limits), the whole sync protocol (codec, pairing, TLS pinning, screens, relays, remote access, status) |
| `Packages/CmdsCore` | `swift test --filter 'SFTP\|FileLocation\|SSHFileCommand\|RemoteEdit\|FolderSync'` | the SFTP codec and client, ssh arguments and failure classification, `HOST:PATH`, the server Trash, the transfer job and queue, editing a server's file (download, save, the conflict answers, upload timing), and comparing and syncing folders (plans, one-way and two-way runs, the Trash, items changed since the comparison, retry) (in-process server, no network) |
| `Packages/CmdsCore` | `swift test --filter 'Assistant\|PaidFeatures'` | the voice assistant (#243): addressing by name and the follow-up window (`AssistantAddressingTests`), Japanese and English commands (`AssistantIntentTests`), which actions a spoken yes may confirm (`AssistantSafetyTests`), finding the workspace and pane, asking back, the status text (`AssistantPlannerTests`), the HUD's state machine (`AssistantMachineTests`), which questions go to Claude with web search, the on-device model's `[[NEEDS_WEB]]` answer and Claude's answer made speakable (`AssistantWebTests`), commands for several sessions, the interpreter's JSON, what goes to it and that its result is only a proposal (`AssistantManySessionsTests`), the voice list and the Personal Voice fallback and notes without its permission (`AssistantVoicesTests`), the paid-feature gate and its free beta (`PaidFeaturesTests`) |
| `Packages/CmdsCore` | `swift test --filter CmdsCLITests` | the CLI's English output, `cmds schedule` argument mapping (`ScheduleCLITests`), the `cmds mcp` server with the app API stubbed (`MCPServerTests`) |
| `Packages/CmdsSSH` | `swift test` (in that directory; fetches swift-nio-ssh and friends on first run) | the SSH tunnel; the end-to-end part needs a throwaway sshd ([below](#remote-access-via-ssh)) |

The app targets have no unit test target; logic that needs tests lives in CmdsCore.

## Isolated instances

Start a second instance from your build:

```sh
CMDS_SUPPORT_DIR=/tmp/cmds-test CMDS_SYNC_DISABLED=1 build/dd/Build/Products/Debug/cmds.app/Contents/MacOS/cmds &
cmds --socket /tmp/cmds-test/cmds.sock ls
```

- `CMDS_SUPPORT_DIR` replaces `~/Library/Application Support/cmds` (session.json, sync-devices.json, cmds.sock) and
  wins over an inherited `CMDS_SOCKET_PATH`, so neither the instance nor a CLI given the variable can reach the
  live app. Such an instance also leaves the saved window/sidebar frames alone and does not activate itself on
  launch (it never takes keyboard focus from the app in use). Its terminals get the resolved absolute path.
- Debug builds are a separate app to macOS (#236): bundle identifier `tokyo.n-n.cmds.dev` (widget
  `tokyo.n-n.cmds.dev.widget`), named "cmds Dev", URL scheme `cmds-dev://`, defaults domain `tokyo.n-n.cmds.dev`.
  So they need their own privacy grants (Screen Recording, Accessibility, Full Disk Access, …: grant them to the
  Debug build when a test needs them) and can never take over the grants, `cmds://` handler, default-browser choice
  or widget of the installed release (`tokyo.n-n.cmds`). Without `CMDS_SUPPORT_DIR` a Debug build uses its own
  support folder, `~/Library/Application Support/cmds-dev` (#247: Info.plist key `CMDSSupportFolderName`, set from
  `CMDS_SUPPORT_FOLDER` in `project.yml` for the app, the widget and the bundled CLI): its own `session.json`,
  `cmds.sock`, `widget.json` (the Debug widget reads that one), sync identity (keychain suffix `cmds-dev`) and paired
  devices. It never listens on an inherited `CMDS_SOCKET_PATH`, and its bundled CLI talks to
  `…/cmds-dev/cmds.sock` by default (in a terminal, to the pane's app via `CMDS_SOCKET_PATH`, as always). So a Debug
  build reopened without its environment no longer restores the release's workspaces or resumes its agent sessions;
  Debug builds and isolated instances also tell macOS not to reopen them at login (`disableRelaunchOnLogin`). Still
  start test instances isolated, so each test has its own throwaway folder; remove `cmds-dev` when you launched a
  Debug build without it. When done with a build you launched, `pluginkit -r …/cmds.app/Contents/PlugIns/CmdsWidget.appex` and
  `lsregister -u …/cmds.app` (`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister`)
  forget it again.
- `CMDS_SYNC_DISABLED=1` skips the iOS sync server (no Bonjour advert, no port). To test sync instead, see
  [below](#sync-against-an-isolated-instance).
- Settings that live in `UserDefaults` (language, keep-awake, resume mode, compact sidebar) are kept in memory only;
  `CMDS_AGENT_RESUME` and `CMDS_SIDEBAR_COMPACT` set their initial values. The lid-close item is disabled.
- cmds › Settings… (terminal font, sidebar text size, zoom) uses its own `UserDefaults` suite
  `tokyo.n-n.cmds.isolated.<first 16 hex digits of SHA-256 of the support directory path>`, read live, so a test can
  change it from outside: `defaults write tokyo.n-n.cmds.isolated.<hash> TerminalFontSize -float 20` (keys:
  `TerminalFontFamily`, `TerminalFontSize`, `SidebarTextSize` small/medium/large, `BrowserPageZoom`,
  `PreviewPageZoom`). `defaults delete` the suite afterwards. DEBUG builds open the window with
  `cmds rpc debug.show_settings` (→ `{"window"}`, its window number for `screencapture -l`).
- Launch the binary directly; `open` does not pass the environment reliably.
- A window that is not on screen (another Space, hidden) is not drawn, so `screencapture` shows nothing. DEBUG
  builds answer `debug.preview_snapshot {pane}` → `{"png_base64"}` with a picture of a preview pane drawn off screen
  (web content via WKWebView's snapshot; Quick Look's out-of-process view stays blank), and
  `debug.files_snapshot {pane}` the same for a files pane. `debug.files {pane, action?, …}` drives a files pane
  without UI scripting and returns its folder, rows, selection, Git states and status line: `select {names}`,
  `copyToOther`, `moveToOther`, `newFolder`, `rename {name, newName}`, `paste {paths, move?}`, `hidden {on?}`,
  `follow {on?}`, `preview`, `terminal`, `back`, `forward`, `up`; `conflict` (`keepBoth`/`replace`/`skip`/`stop`)
  answers name conflicts instead of the alert. Point it only at folders the test created.
- Browser DevTools (#167): a local page that logs at every level, throws an uncaught error and leaves a promise
  rejection unhandled on load, with a form (text field, select, checkbox, button) whose `input` / `change` / `click`
  handlers write what they saw into `document.title` (read with `cmds browser url`); the same page served with a
  strict CSP (`default-src 'self'; script-src 'self'`, e.g. a tiny local server or `<meta http-equiv>`): console,
  tree, fill and click by ref and by selector, wait-for that finds text and one that times out, and `--follow`.
- Responsive view (#170): `debug.browser {pane}` also returns `responsive` = each frame's device, URL, title and
  frame. With a local page that writes its width and scroll fraction into `document.title`, and query-string hooks
  that scroll the phone frame or navigate the desktop frame after 3 s (page scripts, no input injection): navigation
  from the first frame and from another one reaches all frames, the scroll fraction matches with Sync Scrolling and
  stays per frame without it, saving the file reloads every frame, relaunch restores the frames, and the number of
  `com.apple.WebKit.WebContent` processes drops by the extra frames when the view is turned off.
- Browser pop-ups, dialogs and downloads (#235): `debug.browser {pane, answer?, text?}` also returns `popups` (title,
  subtitle = host, URL, size, key), the `sheet` the page waits for (an alert's title, message, buttons and prompt
  field, or `openPanel`) and the `download` notice's text; `answer` `ok` / `cancel` answers that sheet as its buttons
  do, with `text` typed into a prompt or, for the open panel, the path of the file chosen. A local page (served on
  127.0.0.1) with `window.open('/popup.html', 'x', 'width=480,height=520')` whose pop-up `postMessage`s its opener and
  then calls `window.close()`, a `target="_blank"` link, alert / confirm / prompt (triggered from `setTimeout` in
  `cmds browser eval`: a dialog blocks the page, so a synchronous eval or `cmds browser url` waits until it is
  answered), a file input and links to a `download` file, a `Content-Disposition: attachment` response and an
  `application/octet-stream` file: the opener sees the message and `closed`, the link opens a split, answers reach the
  page, the file names are numbered, and in a workspace that is not shown (and during `cmds browser snapshot` of it)
  no pop-up or sheet appears. Downloads land in the real ~/Downloads: delete the test files afterwards. Close a pane
  with a pop-up and an open alert (no exception, the pop-up goes).
- `debug.find {pane, action?, …}` (DEBUG builds) drives a terminal pane's find bar (#173) and returns its state
  (open, text, count, engine = libghostty's search, hits, the selected hit's row/column/width and marker frame for
  Match Case / regex, scrollbar, which of field and terminal has the keyboard): `open {text?, caseSensitive?,
  regex?}` / `set {…}` search and wait for the result, `next`, `previous`, `close`, `key {chars}` sends key presses
  to the window as typed (they must land in the field, never in the terminal), `menuKey {chars, shift?}` a ⌘-key
  through the main menu (⌘F, ⌘G, ⇧⌘G); `snapshot: true` adds `png_base64` (the bar and marker; the terminal's Metal
  layer is not in it). Generate the scrollback in a pane the test created.
- `debug.palette {action?, query?, move?, index?}` (DEBUG builds): `open` (default) opens the command palette as ⇧⌘P
  does, `query` filters, `run {index?}` runs a result as Return does, `close`; returns the results (kind, title,
  detail, shortcut, score), the selected row, the selected workspace and focused pane. Menu commands are collected
  when it opens; in an instance that is not the active app, those that need a key window are missing.
- `debug.menubar_reply {action?, workspace?, number?, text?, key?, snapshot?}` (DEBUG builds, #213): `open`
  (default; `workspace`) opens the menu bar's reply panel as choosing the workspace in the menu does, but without
  taking the keyboard; `state`, `pick {number}` (an option, as its button or 1–9), `reply {text}` (as Return in the
  field: paste, then Return), `key {key}` (`escape`, `up`, `down`, `enter`, `interrupt`: the key bar), `next` /
  `previous` (⌘↓ / ⌘↑), `openInCmds` (⌘↩), `close`. Returns the workspace and pane, the header lines, a note when the
  pane or workspace closed, the mirror's text, the parsed question and options, the window number and frame;
  `snapshot: true` adds `png_base64` (without the window's translucency). Isolated instances leave the menu bar item
  off: `defaults write tokyo.n-n.cmds.isolated.<hash> ShowInMenuBar -bool true` puts it under the icon. Drive only a
  pane the test created (e.g. a script that prints a `❯ 1. Yes` / `  2. No` prompt and reads a line).
- Scrollback export (#253): in a pane the test created, a script prints 30,000 numbered lines (every 1000th longer
  than the pane is wide, every 500th in colour) and writes the same text to a file; `cmds pane export --pane P
  out.txt` must give mode 0600 and that text (wrapped lines joined), again refused without `--force`, `--force` over
  a 0644 file leaves 0600, `--ansi` with the escape codes stripped equals the plain file. Then export a second pane
  while it prints 1.5 million lines (rows pruned meanwhile are reported as lost, the app keeps answering), and once
  more after it finished (no gaps in the numbering).
- Browser screenshots (#169): a local page several screens tall with coloured bands and an element below the fold
  (`--full` is one image of the whole page; `--selector` the element, also after navigating to `page.html#element`,
  which scrolls the pane; the pane's scroll position written to `document.title` stays), a page over 16384 px tall
  (refused), `--device iphone,ipad,desktop-1440 -o shot.png` (three files), a pane of a workspace that is not shown,
  and `cmds mcp` with `browser_snapshot` `devices` (text + image per size).
- Browser device sizes (#168): open a local test page that writes `innerWidth`, `devicePixelRatio`,
  `matchMedia('(prefers-color-scheme: dark)').matches` and `navigator.userAgent` into `document.title` on load and
  resize, set sizes and schemes with `cmds browser device --pane P …`, and read them back with `cmds browser url
  --pane P` (or `cmds browser eval`). `debug.browser {pane}` (DEBUG builds) returns the toolbar's width and
  breakpoint text, the web view's frame and size, the scale, the device menu's items and the pane drawn without its
  page; `cmds browser snapshot` has the page at the device size. Relaunch to check the setting is restored.
- Reload on file changes (#252): a temporary folder with `index.html` (a script that writes `Date.now()` into
  `document.title` on load), `node_modules/` and `.git/`, opened as `file://` in a browser pane of a workspace whose
  folder it is; `cmds browser watch --pane P`, then edit `index.html` (title changes; `debug.browser` `watchReloads`
  counts reloads), touch files in `node_modules`/`.git` and a dot file (no reload), write several files at once (one
  reload). Select another workspace, edit, come back: one reload. `--off`, and a remote URL (`active: false`). Move the
  folder away: `--status` says `not watching: the folder was removed or moved` (`error`; the eye turns red); move it
  back and edit: one reload (#259).
- `debug.pane_drag {pane, target?, zone?, row?, outside?}` (DEBUG builds, #218) drops a pane as a drag of its grip
  would: on `target`'s `zone` (`left`/`right`/`top`/`bottom`/`center`, the middle of that band as laid out now, through
  the content area's hit test), on the sidebar `row` of a workspace, or `outside` the window; without one it reports.
  Returns the pane's workspace, frame, grip frame, terminal grid and whether its terminal has the keyboard (and what
  the hit test found). With a loop (`while true; do date; sleep 1; done`) and a shell in panes the test created, check after each
  move that the loop's output goes on (`cmds read`), the shell takes input (`cmds send`, then `tput cols; tput lines`
  matches the new grid), a browser pane keeps its page state (`cmds browser eval`), `cmds top --workspace` lists the
  loop under its new workspace, and session.json after a relaunch has the new layout. The grip's hover and a real
  mouse drag (Esc cancels) need a person.
- `debug.assistant {action?, …}` (DEBUG builds, macOS 26, #243) drives the voice assistant without a microphone or
  speech: `on {mute: true}` turns it on text-only (the microphone is never started from here and the choice is not
  remembered, so a relaunch starts nothing; keep it muted), `hear {text}` injects a recognised utterance (an
  unaddressed one is dropped as from speech; after an answer wait 1 s, the echo guard), `speak {text}` makes it
  "say" a text without a voice and stay speaking until `spoken` (its own voice heard back, barge-in by name; `state`
  has `request`, `voiceActive`, `followUpSeconds`, `claudeWorking`), `problem {text?}` shows a problem as if the
  microphone had failed (none clears it; Settings › Assistant's orange row comes and goes while Settings is open, the
  window growing and shrinking with it; `debug.show_settings` returns the window's `frame`), `key {key: confirm|cancel}`
  / `click {button: …}` answer the card, `state` returns the phase, transcript, answer, pending action and the HUD's
  texts, `snapshot: true` the HUD drawn off screen (or `screencapture -l <window>`). Isolated instances register no
  global keys (⌥⌘J, Return / Esc while a card shows), so `confirmationKeys` stays false there. Fake agents for it:
  `agent.claude_status` for a pane, `agent.claude_hook` `UserPromptSubmit` (working) / `Notification` (needs you), and
  a script in a pane the test created that prints `❯ 1. Yes` / `  2. No` and reads a line (one that mentions
  `rm -rf` above the question for the Return-or-click rule). Check: status, "what is X doing" (with Apple Intelligence
  on: the model's summary, else the rule text), a reply cancelled by "no" and sent by "yes", an ambiguous name asking
  back and the answer retargeting it, a dangerous text where "yes" is refused and a click sends it, Japanese with
  `-AppleLanguages '(ja)'`, the quiet style, `debug.show_settings {tab: assistant}`, a web question ("what's the weather in Tokyo tomorrow": `hud.source` "Asking Claude…" while it runs, then the answer with "Claude"; `on {web: false}` sends it to the on-device model instead; it runs the real `claude -p` and uses Claude Code usage). Several sessions: "check all sessions" (`answer` has one line per session), "approve all" with two fake agents waiting (`pending.also` holds the second, `hud.target` "2 sessions", one with `rm -rf` above its question makes `confirmation` keyOrClick), a free instruction ("tell the api agent to fix the failing test": the card shows the phrased text; `on {interpreter: false}` answers it as a question instead). The microphone, speech
  permission prompts, the hotkey, Return / Esc and real speech need a person on a Debug build outside isolation.
- `debug.sidebar_port {workspace?, index?}` (DEBUG builds) clicks port `index` (default 0) in the workspace's sidebar
  row, at the middle of its text as the mouse would, and returns the port opened (in a browser split, #171).
- `debug.memory {workspace?}` (DEBUG builds, #193) returns the "memory is short" notification's title and body as
  they would be posted now (without waiting for the pressure), the sidebar footer's leftover row (null when there is
  none) and, with `workspace`, the top-process lines of its usage tooltip. Leftover processes in an isolated instance:
  split a pane, `cmds send --pane P --enter 'nohup sleep 9999 >/dev/null 2>&1 &'` (and e.g. a Homebrew
  `python3 -m http.server`), close the pane, then `cmds top --leftover` lists them as leftover and `cmds kill PID` stops
  them; `cmds kill` of a `sleep` started outside cmds, of pid 1 or of the app's pid is refused. `cmds mcp` with that
  instance's `CMDS_PANE_ID` answers `system_stats` and `list_processes`.
- `cmds mcp` terminal tools (#171), in an isolated instance: run `cmds mcp` with `CMDS_PANE_ID` / `CMDS_WORKSPACE_ID`
  of a terminal pane the test created and `CMDS_SUPPORT_DIR` set, write JSON-RPC lines to it (`initialize`, then
  `tools/call` terminal_split with a command, terminal_read, terminal_send, list_panes, list_ports), and check that
  terminal_read / terminal_send refuse the caller's own pane and a pane split from another terminal.
- `debug.recent_sessions {open?, snapshot?}` (DEBUG builds) returns the items of File › Recent Agent Sessions
  (title, checked, enabled, tooltip); `open` (index of a session item) does what choosing it does and returns the
  `problem` the alert would show; `snapshot: true` adds `png_base64`, the window drawn off screen. Seed
  `agent-history.json` in the support directory with sessions in folders the test created.

### Worktree workspaces end to end

Unit tests: `swift test --filter 'WorktreeTests|WorktreeCLITests'` (in `Packages/CmdsCore`) create temporary
repositories with a local bare remote (hooks off with `core.hooksPath=/dev/null`, no network).

In an isolated instance, with the CLI called as above (`env -u CMDS_PANE_ID … CMDS_SUPPORT_DIR=…`), only on a
temporary repository with a local bare remote (`git init --bare`, `core.hooksPath` set to `/dev/null` in both), never
on a real repository:

- `cmds new --worktree feat/a` in the repository: the folder `<repo>-worktrees/feat-a`, `worktree` in `cmds ls --json`,
  `worktrees.json` in the support directory; the same branch, an existing path, a path inside the repository and an
  unknown `--base` are errors and create nothing.
- Commit, change and add files in the worktree from your own shell (never typed into a pane), `cmds changes <ws>`, then
  the file it names and `debug.preview_snapshot`; a second `cmds changes` reuses the pane.
- `cmds rpc debug.close_alert '{"id": …}'` (DEBUG builds) shows the close alert's text and buttons;
  `cmds close <ws> --remove-worktree` is refused while there are changes, untracked files or unpushed commits; after a
  commit and `git push -u origin feat/a` to the bare remote it removes the folder (the branch stays).
- A worktree made with `git worktree add` and opened with `cmds new --cwd`: no `worktree`, `debug.close_alert` gives
  `null`, `--remove-worktree` is refused. A second workspace in a worktree cmds created: neither is offered.
- Quit and relaunch: the worktree workspace keeps its `worktree`.

### Schedules end to end

In an isolated instance (`CMDS_SUPPORT_DIR`, `CMDS_SYNC_DISABLED=1`), with the CLI called as
`env -u CMDS_PANE_ID -u CMDS_WORKSPACE_ID -u CMDS_SOCKET_PATH CMDS_SUPPORT_DIR=… <app>/Contents/Resources/bin/cmds`:

- `cmds schedule add --name t --in 5s --start <tmp dir> -- echo scheduled-ok`, then `cmds read` on the new pane and
  `cmds schedule history` (succeeded; the selected workspace stays selected).
- A pane of a workspace the test created, with a session reported through `cmds rpc agent.claude_status` and
  `sleep 60` running: a `--continue --pane` schedule is skipped (`otherProgram`) and nothing is typed.
- Catch-up: schedules `--in 1h` (default late policy) and `--in 1h --late skip`, then
  `cmds rpc debug.schedule_clock '{"offset": 3720}'` (DEBUG builds): one catch-up run and one missed entry.
- `continueSession` with a stub `claude` script first on `PATH` (start the instance with `ZDOTDIR` pointing at a
  temporary `.zshrc` that puts it there, so the real `claude` is never run) that reports a session with
  `cmds hook claude-status` / `cmds hook claude`, and accounts whose `CLAUDE_CONFIG_DIR`s are temporary folders
  (never `~/.claude`): a running session (also waiting while the stub reports busy, and `--after-limit` with a
  status-line window at 100 %), an offered session after a relaunch (resumed, then the prompt), and a session no pane
  holds (resumed in a new workspace under the schedule's account).

- Phase 2 (#45), with a stub `codex` script first on `PATH` (via the `ZDOTDIR` `.zshrc`, with `CODEX_HOME` a
  temporary folder) that opens `$CODEX_HOME/sessions/…/rollout-…-<uuid>.jsonl` like Codex, writes `session_meta`
  and `token_count` lines, shows `• Working (Ns • esc to interrupt)` for a while, then logs what it reads:
  - `--send "echo …" --to shell --pane P` types at the empty prompt; into a pane running `sleep 60` the run is
    skipped (`otherProgram`) and nothing is typed; `--workspace TITLE` types into a one-pane workspace, and is skipped
    with `ambiguousTarget` / `paneNotFound` for a two-pane or missing one.
  - `--send … --to agent` into the stub while it shows its working line: the run waits and pastes once, 5 s after
    the line is gone.
  - `token_count` lines appended to the rollout file with `used_percent` 100 and a `resets_at` a few seconds ahead:
    `--after-codex-limit --delay 0 --continue --pane P` continues the Codex session after the reset;
    `--after-codex-limit --repeat --send …` runs once per new reset and not again for the same reset.
  - `cmds schedule skip ID`; a schedule `--in 70s` logs its notice after 10 s (`log show --info` for the instance's
    pid, category `schedule`).
  - Quit and relaunch: the tag still names the same pane (`schedule show` prints `(now pN)`); check the command ran
    on that pane's tty (`tty > file`), because `cmds read` of a restored pane currently returns the focused pane's
    screen (also on master).

- Codex limits (#227): cmds follows recent session files under `$CODEX_HOME/sessions` of its own environment, so
  launch the instance with `CODEX_HOME` set to a temporary folder (without it, it reads the user's
  `~/.codex/sessions`, read only). Never run the real `codex` for this; write a fabricated
  `sessions/<yyyy>/<MM>/<dd>/rollout-<date>-<uuid>.jsonl` (today's local date) with a `token_count` line with
  windows, one with `primary`/`secondary` null and a `task_complete` line with `codex_error_info`
  `usage_limit_exceeded` and "try again at <Mon> <d>th, <yyyy> <h:mm> <AM/PM>." Within 15 s `cmds agents` shows Codex
  with `limit 100%` and that reset; `codex-limits.json` appears in `CMDS_SUPPORT_DIR`; after a relaunch with the
  file removed from the sessions folder the limits are still shown.

Quit the instance (`cmds quit`) and delete the temporary folders afterwards.

All switches: [reference/environment.md](../reference/environment.md#app-switches-isolated-and-test-instances).

## Sync against an isolated instance

In addition to `CMDS_SUPPORT_DIR`, which also selects separate keychain items for the sync identity:

- `CMDS_SYNC_PORT=<port>`: listen on this port; unlike the default port it never falls back to another.
- `CMDS_SYNC_NO_BONJOUR=1`: do not advertise, so no phone discovers the instance.
- `CMDS_SYNC_NO_BLUETOOTH=1`: no Bluetooth peripheral (no advertising, no L2CAP channel). Use it for every test
  instance that does not test Bluetooth.
- `CMDS_SYNC_TEST_PAIRING=1` (DEBUG builds with `CMDS_SUPPORT_DIR` only): listen on 127.0.0.1 only, keep pairing open
  without the window and write the current QR payload (host 127.0.0.1) to `$CMDS_SUPPORT_DIR/sync-test-pairing.txt`
  (0600), so a local client can pair like the scanner does.
- Relay test against an isolated instance: `CMDS_RELAY_E2E_PAIRING=$CMDS_SUPPORT_DIR/sync-test-pairing.txt
  swift test --filter SyncRelayTests` (in `Packages/CmdsCore`) pins the instance's certificate and pairs through two
  relays and a simulated L2CAP channel.
- Unpairing one device against an isolated instance: `CMDS_REVOKE_E2E_PAIRING=$CMDS_SUPPORT_DIR/sync-test-pairing.txt
  swift test --filter SyncRevokeTests` (in `Packages/CmdsCore`) pairs two phones, revokes one through `sync.revoke`
  and checks that only that one is disconnected and refused (#114). The phones' helpers are in `SyncE2ESupport.swift`.
- Scrollback test against an isolated instance: `CMDS_SCROLLBACK_E2E_PAIRING=$CMDS_SUPPORT_DIR/sync-test-pairing.txt
  swift test --filter SyncScrollbackTests` (in `Packages/CmdsCore`). Each test creates its own workspace through the
  instance's socket (next to that file), prints numbered rows there, pairs and checks:
  - `requestScrollback` for a phone without the stream: `welcome.features`, the full `screen` and `scrollback` under
    one `seq`, consecutive rows ending right above the screen, the 1000-row limit, a request within 0.5 s of an answer
    answered once 0.5 s have passed, the errors, and no `scrolledOff` / `historyReset`;
  - the stream (`scrollbackStream`): a script in a temporary directory prints in steps the test releases. The answer
    and every `scrolledOff` after it must form one consecutive sequence that ends right above each screen that carries
    rows (never overlapping it otherwise), through bursts of 100 rows and of 4000 rows (which may reset);
    `historyReset` after `printf '\033[3J'` while the screen's text stays the same, and no rows after it until the
    next answer; a second phone without the feature gets neither field;
  - the stream across pruning: 120 000 rows fill the scrollback (skipped when Ghostty keeps them all, e.g. with a
    raised `scrollback-limit`), then bursts of 100 and of 800 rows keep it pruning: no `historyReset`, one consecutive
    sequence; a request sent during heavy output (3.9 million rows) is answered once the rows can be read.

  It closes the workspaces when done.
- Styles test against an isolated instance: `CMDS_STYLES_E2E_PAIRING=$CMDS_SUPPORT_DIR/sync-test-pairing.txt
  swift test --filter SyncStylesE2ETests` (in `Packages/CmdsCore`) prints coloured rows (palette, 256-colour and RGB
  colours, every attribute, wide characters, a background erased to the right edge) in a workspace it creates and checks
  the runs a phone with `styles` gets, that the text matches `cmds read`, and that a phone without the feature gets the
  same text and no styles. A second test checks the runs of the rows above the screen, in the `scrollback` answer and
  in `scrolledOff` rows, and that a phone without the feature gets those rows plain.

- Schedules test against an isolated instance: `CMDS_SCHEDULES_E2E_PAIRING=$CMDS_SUPPORT_DIR/sync-test-pairing.txt
  swift test --filter SyncSchedulesE2ETests` (in `Packages/CmdsCore`) pairs a phone with `schedules`, adds a schedule
  three hours ahead through the socket (as `cmds schedule add`; it does not fire during the test) whose prompt, command
  and folder carry markers, and checks the summary (no marker in the frame), that a burst of changes arrives at most
  once a second ending with the last state, that a phone without the feature gets no `schedules`, and the removal.
  It removes the schedule at the end. On the phone side, `-mock` sends demo schedules (`-mockNoSchedules`: none;
  `-mockShowSchedules YES` opens ⋯ › Schedules at launch, for screenshots).

- Browsing files panes (#26 phase 4): `SyncListingTests` (CmdsCore) covers the messages, paths, the listing (order,
  cap, hidden items, links, pipes, permissions) and the files sent, on a temporary folder. On the phone side, `-mock`
  has a files pane in the report workspace with a small demo tree (`MockFiles`); `-mockWorkspace w-report -mockPane
  p-files` opens it at launch, `-mockShowHiddenFiles` lists hidden items, `-mockNoFilesBrowse` answers like a Mac
  without the feature.
  Against an isolated instance: `CMDS_FILES_E2E_PAIRING=$CMDS_SUPPORT_DIR/sync-test-pairing.txt swift test --filter
  SyncFilesBrowseE2ETests` (in `Packages/CmdsCore`) opens a temporary folder in a files pane, lists it and a subfolder,
  fetches a file, checks the errors and that the Mac pane did not move, and that a phone without the feature is
  refused. It closes the workspace and removes the folder.

### Files panes on SSH hosts

The same throwaway sshd serves SFTP, starting in `<dir>/sftp-home` (so the "home" and the server Trash of the test
stay inside `<dir>`). Never point a test at your own hosts, keys or `localhost` through `~/.ssh`.

1. `Packages/CmdsSSH/Scripts/test-relay-sshd.sh start <dir> <port>`.
2. Real ssh, no app: in `Packages/CmdsCore`, `CMDS_FILES_E2E_DIR=<dir> swift test --filter SFTPEndToEndTests`
   (connect, upload and download a folder, edit a file (download, save over it with `posix-rename@openssh.com`, a
   change on the server asked), and the refusals: `cmds-test-unknown` with `accept-new` in its config stays
   out of its empty `known_hosts`, `cmds-test-changed` has another key pinned, `cmds-test-nokey` offers a key the server
   does not accept).
3. The app: an isolated instance started with `CMDS_FILES_SSH_CONFIG=<dir>/ssh_config`; `cmds files cmds-test-relay:`
   and `cmds files <local tmp dir>` in a workspace the test created, then `debug.files` (`select`, `copyToOther`,
   `moveToOther` from the remote pane only (a local move would put the originals in your Trash), `rename`,
   `newFolder`, `trash`, `paste {paths}`, `preview`, `reload`, `conflict`, `edit` (no app is opened unless
   `open: true`) and `editing`, then write the copy and check the server's file, `stopEditing`, `compare`, then
   `debug.compare` (`direction`, `delete`, `conflicts`, `path` + `choice`/`exclude`, `action`: `state`, `compare`,
   `hidden`, `sync` (no confirmation), `snapshot` (`appearance`: `light`/`dark`; take a second one after switching),
   `close`)), `cmds files compare` / `cmds files sync` between the
   remote folder and the local one, `cmds transfers` (`pause`, `cancel`,
   `retry` on a large file), the refusals in the pane's status, and a relaunch (remote panes wait for Connect).
4. `test-relay-sshd.sh stop <dir>` and delete `<dir>`.

The rules themselves (conflicts, cancel, retry, Trash, pipelining, drops) are unit-tested without a network against
an in-process SFTP server on a temporary folder (`SFTPTransferTests`).

### Remote access via SSH

`CMDS_SYNC_REMOTE_SSH_CONFIG=<file>` (isolated instances only) makes remote access run `ssh -F <file>`, so a test never
reads `~/.ssh`.

1. `Packages/CmdsSSH/Scripts/test-relay-sshd.sh start <dir> <port>` starts a throwaway sshd as the current user on
   127.0.0.1 (temp host keys, `authorized_keys`, client config with Host `cmds-test-relay` and its own known_hosts).
2. Put `{"enabled":true,"host":"cmds-test-relay","relayPort":<relay port>}` in `$CMDS_SUPPORT_DIR/sync-remote.json`
   and start the instance with `CMDS_SYNC_REMOTE_SSH_CONFIG=<dir>/ssh_config` and the switches above.
3. In `Packages/CmdsSSH`: `CMDS_SSH_E2E_DIR=<dir> CMDS_SSH_E2E_PORT=<port>
   CMDS_SSH_E2E_PAIRING=$CMDS_SUPPORT_DIR/sync-test-pairing.txt CMDS_SSH_E2E_RELAY_PORT=<relay port> swift test`
   (host key TOFU/mismatch, unauthorized key, restricted key, pairing refused over SSH, token → welcome/state, wrong
   certificate, phone-side and Mac-side tunnel drops).
4. `test-relay-sshd.sh stop <dir>` afterwards.

## Testing sync on a device

The sync paths can be checked end to end on a real iPhone without touching it: `xcrun devicectl` installs,
launches and screenshots the app over Wi‑Fi, the `CmdsDeviceDriver` UI test target taps and reads it, and
`cmds sync` shows the Mac's side. Wi‑Fi has to stay on for `devicectl`, so a debug build of the companion can
be told to use only one path. Use a device and Mac instance meant for testing, never the ones in use.

**Forcing a path (debug builds only).** Launch argument `-cmdsTransport <auto|network|bluetooth|ssh>`:
`bluetooth` connects only through `BluetoothTransport` (no LAN/AWDL attempt even though Wi‑Fi works), `ssh`
only through `SSHTransport` (remote access must be set up for that Mac), `network` never falls back. The same
choice is in the ⋯ menu (`moreMenu`) › "Transport (Debug)" (`debugTransport`) › "Transport: bluetooth"
(`transport.bluetooth`, …; the driver's `tap:` also matches the labels); it reconnects at once, wins over the launch
argument for that run and is remembered for later launches without the argument. Every mode keeps the pinned TLS
check; a path that cannot be used fails with a reason instead of falling back. Release builds ignore the argument and
hide the menu.

**Reading the phone's state.** The status badge (`connectionStatus`) carries, in debug builds, an
accessibility value like
`mode=bluetooth path=bluetooth | bluetooth: welcome` or
`mode=bluetooth path=none | bluetooth: error: Bluetooth is off. | lastError: bluetooth: Bluetooth is off.`
(release builds: the path, or the last error). Stages per path: network `connecting`; Bluetooth
`waiting for Bluetooth`, `scanning`, `found peripheral, connecting`, `connected peripheral, reading service info`,
`opening L2CAP (PSM n)`, `L2CAP open, TLS handshake`; SSH `connecting to the relay host`,
`relay login ok, opening the forward`, `forward open, TLS handshake`; then `TLS ok, hello sent` and `welcome`,
or `error: <reason>`. Debug builds also show it as a row at the bottom of the workspace list
(`syncDiagnostics`). No tokens, keys or codes appear in it.

**Mac side.** `cmds sync` (`--json` for everything; socket API `sync.status`, refused on SSH-pane sockets):

```
sync       enabled · Listening on port 47961 · identity 41F2-E114-519A · 1 paired
bonjour    on · "Mac"
bluetooth  allowed · authorization allowedAlways · manager poweredOn · advertising on · PSM 193 · 1 channel · Advertising (PSM 193)
ssh relay  off · forwarding off · Off
  ✓ iPhone  bluetooth:1a2b3c4d  bluetooth  2 panes  sent 1.2 MB  received 3.4 KB  for 1m05s
```

`authorization` is the Mac app's Bluetooth permission (`allowedAlways`, `denied`, `restricted`,
`notDetermined`); `manager` is `off` while the peripheral is not running (sync off, "Allow Bluetooth Sync"
off, `CMDS_SYNC_NO_BLUETOOTH`). A connection is `…` until its `hello` authenticated.

**Commands** (`UDID` = the test device, `$SOCK` = the Mac instance's socket):

```sh
# Build and install the debug companion and the driver once.
xcodebuild -scheme CmdsCompanion -destination id=$UDID -derivedDataPath build/dd-ios -allowProvisioningUpdates build
xcrun devicectl device install app --device $UDID build/dd-ios/Build/Products/Debug-iphoneos/CmdsCompanion.app
xcodebuild -scheme CmdsDeviceDriver -destination id=$UDID -derivedDataPath build/dd-driver -allowProvisioningUpdates build-for-testing

# Launch forced to Bluetooth (the app reconnects to its most recent Mac).
xcrun devicectl device process launch --device $UDID --terminate-existing tokyo.n-n.cmds.companion -cmdsTransport bluetooth

# Wait until it is connected over Bluetooth, then print the diagnostics.
TEST_RUNNER_CMDS_UI_SCRIPT='waitValue:connectionStatus~path=bluetooth~45;;value:syncDiagnostics' \
  xcodebuild test-without-building -xctestrun build/dd-driver/Build/Products/CmdsDeviceDriver_*.xctestrun \
  -destination id=$UDID | grep CMDS_UI_VALUE

# Or switch the running app without relaunching it.
TEST_RUNNER_CMDS_UI_SCRIPT='tap:moreMenu;;tap:debugTransport;;tap:transport.ssh;;waitValue:connectionStatus~path=ssh~45' \
  xcodebuild test-without-building -xctestrun build/dd-driver/Build/Products/CmdsDeviceDriver_*.xctestrun -destination id=$UDID

# The Mac's view of the same connection.
cmds --socket $SOCK sync --json | jq '.bluetooth, [.clients[] | {deviceName, authenticated, peer, path}]'

# Back to normal.
xcrun devicectl device process launch --device $UDID --terminate-existing tokyo.n-n.cmds.companion -cmdsTransport auto
```

Screenshots: `xcrun devicectl device capture screenshot --device $UDID --destination shot.png`.

The phone must already be paired with the Mac instance under test (pairing over Bluetooth works with a
scanned QR code; pairing codes are refused over SSH). For Bluetooth the instance must run without
`CMDS_SYNC_NO_BLUETOOTH`, and `cmds sync` should show `authorization allowedAlways` and `advertising on`.

## The device driver

`iOS/UITests/DeviceDriverTests.swift` drives the already-installed, already-running companion (device or simulator)
without reinstalling or relaunching it. Steps come from `CMDS_UI_SCRIPT` (passed as `TEST_RUNNER_CMDS_UI_SCRIPT`),
separated by `;;`:

| Step | Effect |
|---|---|
| `tap:<label or identifier>` | Tap the first element with that label/identifier |
| `tapContains:<text>` | Tap the first element whose label contains the text |
| `tapText:<text>` | Tap the first static text containing the text |
| `type:<text>` | Type into the focused element (`\n` = return) |
| `wait:<seconds>` | Wait |
| `pinch:<scale>` | Pinch the terminal screen (>1 zooms in) |
| `swipe:<down\|up>[~count]` | Swipe the terminal screen (down scrolls back into earlier output) |
| `value:<identifier>` | Print `CMDS_UI_VALUE <identifier> <accessibility value>` |
| `waitValue:<id>~<text>[~secs]` | Wait (default 30 s) until that value contains the text, else fail |
| `back` | Navigation bar back button |
| `dump` | Print the accessibility tree between `CMDS_UI_DUMP_BEGIN` / `CMDS_UI_DUMP_END` |

Elements are found by accessibility identifier (e.g. `terminalScreen`, `connectionStatus`, key bar keys such as
`left`, `esc`, `ctrlc`), never by localized text.

## The simulator companion against an isolated instance

The simulator shares the Mac's loopback, so the companion can pair with an instance started with
`CMDS_SYNC_TEST_PAIRING=1 CMDS_SYNC_NO_BONJOUR=1 CMDS_SYNC_NO_BLUETOOTH=1` (DEBUG build, own `CMDS_SUPPORT_DIR`) and
show real panes, e.g. a workspace made with `cmds new` that ran `seq 1 1500` (earlier output, #19).
`sync-test-pairing.txt` is a `cmds-pair://v2?host=…&port=…&fp=…&code=…` URI. Launch the companion with
`-noNotify -AppleLanguages '(en)' -AppleLocale en_US` (the steps below use English labels), then drive it:

1. `tap:manualHost;;type:127.0.0.1:<port>;;tap:Connect;;wait:3;;tap:Pair Without Camera;;wait:3;;dump`
2. Check the label of `pairingFingerprint` in the dump against `fp` (base64url; its first 6 bytes in hex read
   `XXXX-XXXX-XXXX`).
3. `tap:It Matches;;wait:2;;tap:pairingCode;;type:<code>` pairs at the sixth digit.

Never pick a Mac under "On This Network": that is the instance someone works in.

## UI tests in the simulator

`TerminalScreenTests` (same target) launches the companion with `-mock -noNotify` and the demo flags it needs
(`-mockFullScreenTUI`, `-mockStreamOutput`, `-mockJapanese`, `-mockNoHistoryStream`, `-uiTestProbes`;
[reference/environment.md](../reference/environment.md#ios-companion-launch-arguments)) and checks rendering against the
demo data: the zoomed TUI, earlier output, and earlier output that keeps up while it is read (#22: the rows on screen
must not change, compared as text and as screenshots, and the rows above the screen must have no gap). It skips itself
on a real device. Run it with `-only-testing:CmdsDeviceDriver/TerminalScreenTests` and the companion installed on the
simulator. `-mock` alone (or "Try with demo data" on the connect screen) runs the app without a Mac.

## Terminal engine harness

`GhosttyHarness.swift` builds a one-window libghostty test app when compiled with
`SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG CMDS_GHOSTTY_HARNESS'`; its `CMDS_HARNESS_*` variables are listed in
[reference/environment.md](../reference/environment.md#libghostty-harness).
