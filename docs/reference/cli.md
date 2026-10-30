# `cmds` command line tool

> Reference for every `cmds` command, its targeting rules, output and exit codes.

`cmds` controls the running app over its Unix socket ([api.md](api.md)). Output and error messages are always
English, whatever the app's language: scripts and agents parse them
([internals/localization.md](../internals/localization.md#what-stays-english)).

## Getting it

- Every terminal opened by cmds has the bundled CLI (`cmds.app/Contents/Resources/bin/cmds`) first on its `PATH`.
- For other terminals: **cmds › Install Command Line Tool…** symlinks `/usr/local/bin/cmds` to the bundled binary
  (asks for an administrator password if `/usr/local/bin` is not writable).
- From source: `swift build --package-path Packages/CmdsCore --product cmds`.

## Targeting

Inside a cmds terminal the CLI sends `CMDS_PANE_ID` / `CMDS_WORKSPACE_ID` as explicit params, so commands act on
*that* pane/workspace even when another one is focused. `--pane P` / `--workspace W` override this. Outside cmds,
the focused pane of the selected workspace is used. Browser commands without `--pane` use the focused browser pane of
the current workspace, else its first browser pane.

The socket is `$CMDS_SUPPORT_DIR/cmds.sock` (isolated test instances, see [internals/testing.md](../internals/testing.md#isolated-instances)),
else `$CMDS_SOCKET_PATH`, else `~/Library/Application Support/cmds/cmds.sock`; `--socket PATH` overrides all of them.

## Commands

| Command | What it does |
|---|---|
| `cmds ping` / `cmds identify` | Check the app is up / show version, pid, socket path |
| `cmds ls` | Workspaces (branch, cwd, ports, `CPU 12% · 1.2 GB`, `!` attention, sidebar text) with a tree of panes (`>` focused) |
| `cmds stats [--watch [seconds]]` | CPU and memory: the Mac (CPU of all cores, memory used / installed, memory pressure) and each workspace's processes (CPU like Activity Monitor: 100% = one core), plus an `awake` line (idle-sleep assertion, whether closing the lid sleeps the Mac; JSON `keepAwake`, see [Keeping the Mac awake](../guide/workspaces-and-panes.md#keeping-the-mac-awake)). `--watch`/`-w` refreshes every 2 s or the given seconds; with `--json` one JSON object per line |
| `cmds sync` | iOS sync status (read-only): listener port, Bonjour, Bluetooth (permission `authorization`, peripheral state, advertising, PSM), SSH remote access, and each connection (device, authenticated, peer `ip` / `bluetooth:…` / `ssh:…`, panes, bytes, connected for). `--json` for the full report; see [Testing sync on a device](../internals/testing.md#testing-sync-on-a-device) |
| `cmds new [--title T] [--cwd DIR] [-- cmd…]` | New workspace (default cwd: current directory); prints its id |
| `cmds new --ssh HOST [--remote-cwd DIR] [--title T]` | New SSH workspace ([SSH workspaces](../guide/workspaces-and-panes.md#ssh-workspaces)) |
| `cmds reconnect [pane]` | Reconnect an SSH pane whose `ssh` exited |
| `cmds remote-helper` | Print `cmds-remote.sh`, the sh client for servers reached through an SSH pane |
| `cmds select <id\|index\|title>` | Select a workspace (index is 1-based like ⌘1…⌘9) |
| `cmds tile [--all \| --off \| <ws>…]` | Tiled view: show the given workspaces (ids, indexes or titles; at least two) side by side, `--all` every workspace the sidebar shows (up to 9), `--off` one workspace again; without arguments prints what is tiled (`tiled (selected): *w2 w3`, `*` = active). See [Tiled view](../guide/workspaces-and-panes.md#tiled-view) |
| `cmds close [ws]` / `cmds rename [ws] <title>` | Close / rename a workspace (default: current) |
| `cmds split [right\|down] [--pane P] [--browser URL \| --ssh HOST [--remote-cwd DIR]] [--cwd DIR] [--no-focus] [-- cmd…]` | Split a pane; prints the new pane id (`--no-focus` keeps the keyboard where it is). Splitting an SSH pane without `--cwd`/command connects to the same host again |
| `cmds panes [--workspace W]` | List panes |
| `cmds focus <pane>` / `cmds close-pane [pane]` | Focus / close a pane |
| `cmds send [--pane P] [--enter] <text…\|->` | Type text into a terminal (`-` reads stdin; `--enter`/`-e` appends Return) |
| `cmds read [--pane P] [--scrollback N \| -n N]` | Print the screen, or the last N lines including scrollback |
| `cmds notify [--title T] [--pane P] <body…>` | Light the attention ring + sidebar text (+ macOS notification when cmds is in the background) |
| `cmds status [--workspace W] <text…>` | Set the sidebar text without ringing (`""` clears) |
| `cmds open [--pane P] [--down] [--no-focus] [--diff] <file\|->` | Show a local file in a preview pane split to the right (`--down`: below); prints the pane id. Images in an image view; PDF, video, Office, text/code in Quick Look; Markdown rendered (GitHub style, dark mode, local images); unified diffs (`.diff`/`.patch`, or any file with `--diff`) coloured with line numbers. Reloads when the file changes (atomic saves too); a deleted file shows a placeholder until it is back. Relative paths are resolved against the current directory; `-` saves stdin to a temporary file (`git diff \| cmds open --diff -`). `--pane` naming a preview pane replaces its file. Refused in SSH panes (the file is on the server). In the app: File › Open in Preview… (⇧⌘O), or ⌘-click a file path in a terminal |
| `cmds browser open [--pane P] [--no-focus] <url>` | Open a browser split to the right; prints the pane id |
| `cmds browser navigate [--pane P] <url>` | Load a URL |
| `cmds browser url [--pane P]` | Print URL and title |
| `cmds browser eval [--pane P] <script\|->` | Run JavaScript and print the JSON result. Promises are awaited; an expression may use `await`; statements with top-level `await` must `return` their value |
| `cmds browser snapshot [--pane P] [-o file.png]` | PNG of the visible page (to stdout when piped) |
| `cmds events` | Stream `notification`, `workspace.changed`, `pane.changed`, `workspaces.changed` events as JSON lines |
| `cmds rpc <method> [json-params\|-]` | Raw API call, e.g. `cmds rpc pane.split '{"direction":"down"}'` |
| `cmds agents` | Coding agents in cmds panes: per pane the figures of Claude Code's status line (`ctx 53% 527k/1M │ $117.99 ($34.53/h) │ ⏱ 3h25m api 3h40m(107%) │ +17642 -330 │ cache ●98%`) or Codex context/tokens, then account limits per agent (5h / 7d / spend, reset times). `cmds ls` shows a short agent summary per pane, `cmds stats` the limits |
| `cmds sessions [--pane P]` | Agent sessions remembered per pane (state `offered` / `waiting` / `running` / `resumed` / `remembered`, id, directory, host, the resume command) and the launch setting ([Resuming sessions](../guide/ai-agents.md#resuming-sessions)) |
| `cmds resume [--pane P \| --all]` | Resume the session offered in a pane after a restart (default: the current pane) or in all panes: types `claude --resume <id>` / `codex resume <id>` into the pane's shell once its prompt is ready |
| `cmds export [-o file] [--legacy]` | Workspaces and their agent sessions as a JSON bundle (stdout, or `-o` file created mode 600); for `cmds import` in another (newer) cmds. Falls back to a legacy export from `workspace.list` / `agent.list` when the app has no `state.export` ([below](#moving-workspaces-to-another-cmds)) |
| `cmds import <file\|-> [--append \| --replace] [--resume ask\|always\|never]` | Recreate a bundle's workspaces (after the open ones, or replacing them) and offer each pane's agent session for resuming (default: the app's resume setting) |
| `cmds hook claude` | Claude Code `Notification` / `Stop` / `UserPromptSubmit` hook ([setup](../guide/ai-agents.md#claude-code)) |
| `cmds hook claude-status` | Claude Code status-line reporter ([setup](../guide/ai-agents.md#claude-code)) |

Every command accepts `--json` (print the raw result) and `--help` (also `cmds help <command>`); `cmds --version`
prints the CLI version. Exit codes: `0` ok, `1` the request failed
(e.g. unknown pane), `2` usage error, `3` the app is not reachable.

Examples:

```sh
cmds split down -- npm run dev          # dev server below this pane
cmds browser open http://localhost:3000
cmds open --no-focus out/report.md       # show a generated report next to this pane
git diff | cmds open --no-focus --diff -
cmds browser eval 'document.title'
cmds browser snapshot -o /tmp/page.png
cmds send --pane p2 --enter 'make test'
cmds read --pane p2 --scrollback 200 | tail -20
long-task; cmds notify --title "long-task" "finished with $?"
cmds stats --json | jq '.system.memoryPressure'   # 1 normal, 2 warning, 4 critical
cmds stats --watch 5
```

## Moving workspaces to another cmds

`cmds export` writes a bundle; `cmds import` recreates it in the running instance (steps for an update:
[guide/ai-agents.md](../guide/ai-agents.md#moving-to-a-new-version)).

```sh
cmds export -o ~/cmds-workspaces.json        # in the old instance
cmds import ~/cmds-workspaces.json           # in the new one (--replace closes the open workspaces)
cmds resume --all                            # with --resume ask (default): resume the offered sessions
```

Bundle (`state.export` result, JSON):

```json
{"format": "cmds.workspaces", "version": 1, "exportedAt": 1793343607.5,
 "source": {"version": "0.1.0", "build": "1", "legacy": true?}, "selectedIndex": 1,
 "workspaces": [{"title": "Main"?, "workingDirectory": "/Users/me/app"?, "focusedPaneIndex": 0?,
   "layout": {"split": {"axis": "horizontal", "ratio": 0.5,
     "first":  {"pane": {"kind": "terminal", "cwd": "/Users/me/app",
                         "agentSession": {"agent": "claude", "sessionID": "…", "cwd": "/Users/me/app",
                                          "host"?, "title"?, "model"?, "lastSeen": 1793343603.1}}},
     "second": {"pane": {"kind": "terminal", "host": "home", "remoteCwd": "~/srv"}}}}}]}
```

Pane kinds: `terminal` (`cwd`, or `host` + `remoteCwd` for an SSH pane), `browser` (`url`), `preview` (`path`,
`format`?). `focusedPaneIndex` and the agent sessions count panes in reading order. Import checks everything
before creating anything: format and version (a newer version is refused), at most 4 MB, 100 workspaces, 500 panes
and 24 split levels, absolute (or `~/`) paths without control characters, SSH hosts and remote directories as for
`cmds new --ssh`, browser URLs http/https/file only, session ids of the plain form `cmds resume` types, sessions
only on terminal panes and for the pane's own host. Directories missing on this Mac open the home directory;
SSH panes stay disconnected until connected or resumed. `state.export` / `state.import` are local-socket only
(refused from SSH panes).

`--legacy` (automatic when the app answers `state.export` with "method not found") builds the bundle in the CLI
from `workspace.list`, `agent.list` and, where the app has it, `agent.sessions`. It only knows the sessions of
agents that are running (or remembered by `agent.sessions`), keeps a workspace title only when it differs from
its directory name, and has no preview format. So a new `cmds` CLI can export from an old running app.

## Hooks for coding agents

`cmds hook claude` and `cmds hook claude-status` are meant to be called by Claude Code; the `settings.json` and
status-line snippets are in [guide/ai-agents.md](../guide/ai-agents.md#claude-code). Both always exit 0, print nothing
and do nothing outside cmds, so they never block the agent.

## Raw calls

`cmds rpc <method> [json-params|-]` sends any API method and prints the result; see [api.md](api.md) for the wire
format, methods and events.
