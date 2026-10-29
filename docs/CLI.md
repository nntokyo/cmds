# cmds command line tool

`cmds` controls the running app over its Unix socket (JSON lines, see [ARCHITECTURE.md](ARCHITECTURE.md#socket-api-json-lines-see-cmdscorerpcswift)).

## Getting it

- Every terminal opened by cmds has the bundled CLI (`cmds.app/Contents/Resources/bin/cmds`) first on its `PATH`.
- For other terminals: menu **cmds → Install Command Line Tool…** symlinks `/usr/local/bin/cmds` to the bundled binary
  (asks for an administrator password if `/usr/local/bin` is not writable).
- From source: `swift build --package-path Packages/CmdsCore --product cmds`.

## Targeting

Inside a cmds terminal the CLI sends `CMDS_PANE_ID` / `CMDS_WORKSPACE_ID` as explicit params, so commands act on
*that* pane/workspace even when another one is focused. `--pane P` / `--workspace W` override this. Outside cmds,
the focused pane of the selected workspace is used. Browser commands without `--pane` use the focused browser pane of
the current workspace, else its first browser pane.

The socket is `$CMDS_SUPPORT_DIR/cmds.sock` (isolated test instances, see [ARCHITECTURE.md](ARCHITECTURE.md#testing-with-an-isolated-instance)),
else `$CMDS_SOCKET_PATH`, else `~/Library/Application Support/cmds/cmds.sock`; `--socket PATH` overrides all of them.

## Commands

| Command | What it does |
|---|---|
| `cmds ping` / `cmds identify` | Check the app is up / show version, pid, socket path |
| `cmds ls` | Workspaces (branch, cwd, ports, `CPU 12% · 1.2 GB`, `!` attention, sidebar text) with a tree of panes (`>` focused) |
| `cmds stats [--watch [seconds]]` | CPU and memory: the Mac (CPU of all cores, memory used / installed, memory pressure) and each workspace's processes (CPU like Activity Monitor: 100% = one core). `--watch`/`-w` refreshes every 2 s or the given seconds; with `--json` one JSON object per line |
| `cmds new [--title T] [--cwd DIR] [-- cmd…]` | New workspace (default cwd: current directory); prints its id |
| `cmds select <id\|index\|title>` | Select a workspace (index is 1-based like ⌘1…⌘9) |
| `cmds close [ws]` / `cmds rename [ws] <title>` | Close / rename a workspace (default: current) |
| `cmds split [right\|down] [--pane P] [--browser URL] [--cwd DIR] [--no-focus] [-- cmd…]` | Split a pane; prints the new pane id (`--no-focus` keeps the keyboard where it is) |
| `cmds panes [--workspace W]` | List panes |
| `cmds focus <pane>` / `cmds close-pane [pane]` | Focus / close a pane |
| `cmds send [--pane P] [--enter] <text…\|->` | Type text into a terminal (`-` reads stdin; `--enter`/`-e` appends Return) |
| `cmds read [--pane P] [--scrollback N]` | Print the screen, or the last N lines including scrollback |
| `cmds notify [--title T] [--pane P] <body…>` | Light the attention ring + sidebar text (+ macOS notification when cmds is in the background) |
| `cmds status [--workspace W] <text…>` | Set the sidebar text without ringing (`""` clears) |
| `cmds browser open [--pane P] [--no-focus] <url>` | Open a browser split to the right; prints the pane id |
| `cmds browser navigate [--pane P] <url>` | Load a URL |
| `cmds browser url [--pane P]` | Print URL and title |
| `cmds browser eval [--pane P] <script\|->` | Run JavaScript and print the JSON result. Promises are awaited; an expression may use `await`; statements with top-level `await` must `return` their value |
| `cmds browser snapshot [--pane P] [-o file.png]` | PNG of the visible page (to stdout when piped) |
| `cmds events` | Stream `notification`, `workspace.changed`, `pane.changed`, `workspaces.changed` events as JSON lines |
| `cmds rpc <method> [json-params\|-]` | Raw API call, e.g. `cmds rpc pane.split '{"direction":"down"}'` |
| `cmds agents` | Coding agents in cmds panes: per pane the figures of Claude Code's status line (`ctx 53% 527k/1M │ $117.99 ($34.53/h) │ ⏱ 3h25m api 3h40m(107%) │ +17642 -330 │ cache ●98%`) or Codex context/tokens, then account limits per agent (5h / 7d / spend, reset times). `cmds ls` shows a short agent summary per pane, `cmds stats` the limits |
| `cmds hook claude` | Claude Code hook (below) |
| `cmds hook claude-status` | Claude Code status-line reporter (below) |

Every command accepts `--json` (print the raw result) and `--help`. Exit codes: `0` ok, `1` the request failed
(e.g. unknown pane), `2` usage error, `3` the app is not reachable.

Examples:

```sh
cmds split down -- npm run dev          # dev server below this pane
cmds browser open http://localhost:3000
cmds browser eval 'document.title'
cmds browser snapshot -o /tmp/page.png
cmds send --pane p2 --enter 'make test'
cmds read --pane p2 --scrollback 200 | tail -20
long-task; cmds notify --title "long-task" "finished with $?"
cmds stats --json | jq '.system.memoryPressure'   # 1 normal, 2 warning, 4 critical
cmds stats --watch 5
```

## Claude Code hooks

`cmds hook claude` reads the hook JSON from stdin and calls `notify` for the pane Claude Code runs in:

- `Notification` (permission prompts, waiting for input) → `Claude Code: <message>`
- `Stop` → `Claude Code: <first line of Claude's last reply>` (from the transcript), or `Finished`

Other events and `Stop` re-entries (`stop_hook_active`) are ignored. It always exits 0 and does nothing outside cmds,
so it never blocks Claude Code. Add to `~/.claude/settings.json` (or a project's `.claude/settings.json`):

```json
{
  "hooks": {
    "Notification": [
      { "hooks": [{ "type": "command", "command": "command -v cmds >/dev/null && cmds hook claude || true" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "command -v cmds >/dev/null && cmds hook claude || true" }] }
    ]
  }
}
```

(`command -v` keeps the hook quiet in terminals where `cmds` is not on `PATH`.) The ring lights only when the pane
is not the focused pane of the key window; the sidebar text always updates.

## Claude Code usage and limits (status line)

`cmds hook claude-status` reads the JSON Claude Code passes to its status-line command and reports model, effort,
context, cost, durations, lines, prompt cache and the account limits (`rate_limits`: 5-hour, 7-day, spend limit) for
`$CMDS_PANE_ID` (`agent.report`). It prints nothing, exits 0, reads stdin for at most 150 ms, does not wait for the app
and is a no-op outside cmds — safe to call from a status-line script. Add one line after the script reads its input
(`input=$(cat)`):

```sh
[ -n "$CMDS_PANE_ID" ] && command -v cmds >/dev/null 2>&1 && printf '%s' "$input" | cmds hook claude-status >/dev/null 2>&1
```

Run it in the foreground (not `&`): the hook finds the Claude process among its ancestors so the pane's usage
disappears when Claude exits. Without a status-line script, `"statusLine": {"type": "command", "command": "cmds hook
claude-status"}` in `~/.claude/settings.json` also works (the status line then stays empty).

## Raw protocol

`{"id":1,"method":"workspace.list"}` → `{"id":1,"result":[…]}`. One JSON object per line; responses carry the request `id` (`result` or `error {code, message}`); malformed lines get
`id: 0` with code `-32700`/`-32600`. Lines are capped at 8 MB. Only processes of the same user may connect.
