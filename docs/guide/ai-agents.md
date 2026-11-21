# Using AI coding agents in cmds

> How to connect Claude Code, Codex and other agents to cmds: notifications, usage and limits, the MCP server, the cmds skill,
> session resume, several Claude accounts and agents on SSH servers.

Each terminal has `cmds` on `PATH` (the copy inside the app bundle) and `CMDS_SOCKET_PATH`, `CMDS_WORKSPACE_ID`,
`CMDS_PANE_ID` in its environment, so an agent running in a pane can drive the app with the CLI
([reference/cli.md](../reference/cli.md)). `TERM_PROGRAM=ghostty` and `TERM=xterm-ghostty`, so agents treat the pane
like Ghostty (Shift+Enter, true color).

## Attention: how a pane lights up

Any of these lights the pane's ring (unless it is the pane you are looking at), sets the sidebar text and, with the
iOS companion connected, notifies the phone (unless that pane is open on the phone):

- an OSC 9 / OSC 777 desktop notification from the program,
- the terminal bell (sidebar text "Bell"),
- `cmds notify [--title T] <text>` (e.g. from an agent's hook).

Focusing the pane clears the ring; ⇧⌘U jumps to the most recent one. When cmds is in the background, a macOS
notification is shown as well.

## Claude Code

### Notifications (hooks)

`cmds hook claude` reads the hook JSON from stdin and tells cmds about the pane Claude Code runs in
(`agent.claude_hook`):

- `Notification` (permission prompts, waiting for input) → notifies `Claude Code: <message>`; the sidebar shows
  **Needs Input**.
- `Stop` → notifies `Claude Code: <first line of Claude's last reply>` (`last_assistant_message`, else the
  transcript), or `Finished`; the sidebar shows **Done** / **Idle**.
- `UserPromptSubmit` → you answered: the sidebar shows **Working** and the stale "waiting for your input" text and
  ring are cleared (no notification).
- `PreToolUse` / `PostToolUse` (optional, same effect as `UserPromptSubmit`) and `SessionEnd` (optional: Claude
  exited, the row shows **Stopped**) are understood too.
- `SubagentStart` / `SubagentStop` → a subagent of this pane's Claude Code started / finished
  ([Subagents](#subagents)); the pane's own state is left alone.

Other events and `Stop` re-entries (`stop_hook_active`) are ignored. The local `cmds` sends only the event name and
the notification text to the app, never your prompt (`cmds-remote.sh` on a server forwards the payload as is; the app
uses the same fields and keeps nothing else). It always exits 0 and does nothing outside cmds, so it never blocks Claude Code. Add to
`~/.claude/settings.json` (or a project's `.claude/settings.json`):

```json
{
  "hooks": {
    "Notification": [
      { "hooks": [{ "type": "command", "command": "command -v cmds >/dev/null && cmds hook claude || true" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "command -v cmds >/dev/null && cmds hook claude || true" }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "command -v cmds >/dev/null && cmds hook claude || true" }] }
    ],
    "SubagentStart": [
      { "hooks": [{ "type": "command", "command": "command -v cmds >/dev/null && cmds hook claude || true" }] }
    ],
    "SubagentStop": [
      { "hooks": [{ "type": "command", "command": "command -v cmds >/dev/null && cmds hook claude || true" }] }
    ]
  }
}
```

(`command -v` keeps the hook quiet in terminals where `cmds` is not on `PATH`.) The ring lights only when the pane
is not the focused pane of the key window; the sidebar text always updates. Without `UserPromptSubmit` the stale text
still goes when you type in the pane or when Claude visibly works again (status-line figures move, or its title
spinner turns); see [Agent state](workspaces-and-panes.md#agent-state).

### Subagents

Subagents (the Task / Agent tool) run inside Claude Code and have no terminal of their own. With the
`SubagentStart` / `SubagentStop` hooks above, cmds lists them per pane and shows them as cards under the tiles of
the [tiled view](workspaces-and-panes.md#tiled-view) (Settings › Agents › Show subagents: Off / In Tiled View Only /
Everywhere), with a **Sub n** count in the sidebar row.

- **What the hook sends**: `agent_id`, `agent_type` and the subagent's transcript path
  (`agent_transcript_path` on `SubagentStop`; on `SubagentStart`, which has none, `<dir>/<session_id>/subagents/agent-<agent_id>.jsonl`
  next to the session's `transcript_path`). Never the prompt or `last_assistant_message`.
- **Live activity** (local panes only): once a second, while the transcript grows, the app reads its last 64 KB and
  keeps only the last tool call — tool name and a short target (`Read Sources/main.swift`, `Bash: swift test` with
  token/password-looking values masked, `Grep <pattern>`, `WebFetch <host>`, the bare name for MCP and other tools) —
  and the context tokens of the last model call. The description comes from `agent-<id>.meta.json` next to it
  (`agentType`, `description` only). Only paths shaped `…/projects/<project>/<session>/subagents/agent-<id>.jsonl`
  are read. Nothing is saved.
- **SSH panes**: the transcript is on the server, so the cards show type, state and elapsed time only.
- A finished subagent stays dimmed for 20 s; running ones go when the agent ends (`SessionEnd`, its process exits) or
  after 15 minutes without transcript growth or hooks.
- `cmds agents --subagents [--pane P]` lists them (`agent.subagents`, local socket only, [api.md](../reference/api.md)).

Codex has no subagents in its session files (checked with codex-cli 0.165), so this is Claude Code only.

### Usage and limits (status line)

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

The status line is also where cmds learns Claude Code's session id, which [session resume](#resuming-sessions)
needs.

### Skill

`integrations/claude/skills/cmds/SKILL.md` (written in Japanese) teaches Claude to open helper panes without stealing
focus (`--no-focus`), run dev servers in a split and read their output, open and check web pages in a cmds browser
pane (`cmds browser open/snapshot/eval`) instead of Chrome, show generated files with `cmds open`, show progress with
`cmds status`, and never type into panes it did not create. It keeps Chrome for pages that need your Chrome sign-ins
or when you ask for Chrome. It is used only when `CMDS_PANE_ID` is set. Install:

```sh
mkdir -p ~/.claude/skills/cmds && cp integrations/claude/skills/cmds/SKILL.md ~/.claude/skills/cmds/
```

The same file works as a [Codex skill](#codex-cli).

## MCP server

`cmds mcp` is a [Model Context Protocol](https://modelcontextprotocol.io) server (stdio) for agents that run in a cmds
terminal. Its tools open and check web pages in cmds browser panes instead of Chrome, show files in preview panes, run
commands in terminal panes beside the agent's, tell whether memory allows another heavy job, and set the sidebar
status:

| Tool | Does |
|---|---|
| `browser_open` | Open a URL in a new tab of the workspace's browser pane (a browser split to the right of the agent's terminal when there is none, or with tabs turned off), without taking the focus; returns the pane id. The same page opened again reuses its tab; at most 10 tabs per agent (the oldest hidden ones close) |
| `browser_navigate`, `browser_url` | Load a URL; the URL and title |
| `browser_eval` | Run JavaScript in the page and return its JSON value (read text, click, fill inputs); `timeout` seconds (default 30, at most 300), after which a page that stopped responding is reloaded |
| `browser_snapshot` | A PNG of the visible page, returned as an image (also when its workspace is not shown). `fullPage`, `selector` (one element), `device` or `devices` (e.g. `["iphone", "ipad", "desktop-1440"]`: one image per size, each after a line naming it) |
| `browser_set_viewport` | Show the page at a device size (`device`: a preset such as `iphone-se`, `WIDTHxHEIGHT` or `off`; `rotate`), with a user agent and `colorScheme` (`light` / `dark` / `system`), to check responsive layouts ([device sizes](workspaces-and-panes.md#device-sizes-and-color-scheme)) |
| `browser_responsive` | The page at phone, tablet and desktop size side by side in one pane (`url` opens a new pane, else `pane`; `devices`, `syncScroll`, `off`). `browser_snapshot` of such a pane returns one image per frame ([responsive view](workspaces-and-panes.md#responsive-view)) |
| `browser_watch` | Reload the page whenever files in a folder change (`dir`, absolute; default the workspace's folder), e.g. a `file://` page or a dev server without hot reload; `remote` reloads non-local pages too, `off` stops ([guide](workspaces-and-panes.md#reload-on-file-changes)) |
| `browser_console` | Console messages, uncaught errors and unhandled promise rejections of the page (`level`, `limit`, `clear`; `show` opens the console drawer for the user) ([Browser DevTools](#browser-devtools)) |
| `browser_source` | The page's HTML as the server sent it, from the cache (not cached: the DOM, unless `fetch` asks the server again), or with `rendered` the DOM now (cut at `maxChars`, default 100,000) ([Developer tools](workspaces-and-panes.md#developer-tools)) |
| `browser_seo` | SEO check of the page: score and one line per check (✗ problem, ! warning, i note, ✓ passed); `crawl` (1–50) also checks linked pages of the site; `open` also shows the report to the user in a tab |
| `browser_snapshot_tree` | The page as a compact tree of roles and names with refs (`- button "Sign in" [ref=e3]`; `selector` to start lower) |
| `browser_click` / `browser_fill` | Click, or fill a field / select / checkbox, by `ref` or `selector` |
| `browser_wait_for` | Wait for a `selector` or `text` to be visible (`timeout` seconds, default 5, 0 checks once); an error when it is not |
| `open_file` | Show a file (image, PDF, Markdown, diff, …) in a preview pane |
| `terminal_split` | Open a terminal pane split off the agent's terminal (`direction` `right` / `down`, `cwd`), without taking the focus, and type `command` into its shell (a dev server, a watcher); the pane stays when the command exits. Returns the pane id |
| `terminal_read` | The visible screen of a terminal pane opened from the agent's terminal, or its last `lines` lines including scrollback (at most 2000) |
| `terminal_send` | Type `text` into such a pane (`enter: true` presses Return; `"\u0003"` is Ctrl-C) |
| `list_panes` | The panes of the agent's workspace, marking its own and those opened from it |
| `list_ports` | Ports the workspaces' processes listen on, with their workspace (open one with `browser_open`) |
| `system_stats` | Memory pressure, memory and swap used, CPU, and `advice: ok` or `advice: wait` (pressure warning or worse) for heavy jobs ([below](#memory-before-heavy-jobs)) |
| `list_processes` | Processes of the agent's terminal and the panes opened from it (memory, CPU, command), plus leftovers: processes whose pane or workspace was closed but which still run. No tool stops them: that is for the user (`cmds kill`, the sidebar's leftover row); in panes it opened, the agent sends Ctrl-C with `terminal_send` |
| `close_pane` | Close a pane opened from the agent's terminal: by this server, an earlier one or the CLI (`cmds browser open`, `cmds open`, `cmds split`); refuses others |
| `set_status` | Sidebar status text for the agent's workspace |

The browser tools use the last browser pane the server opened unless given `pane`. cmds remembers which terminal pane
each pane was opened from over the API (also across a relaunch), so `close_pane` works after the MCP server restarted and
for panes the agent opened with the CLI. Panes opened from another terminal or by you stay open; the refusal points the
agent to `cmds close-pane <id>`, for when you ask for it. `terminal_read` and `terminal_send` work the same way: only on
terminal panes opened from the agent's terminal (`terminal_split`, `cmds split` there), never on its own terminal, your
panes or another agent's; both the server and the app check it. In an SSH pane the server can only reach that pane (the
[remote socket](../internals/ssh.md) allows no splits), so the terminal tools refuse there. The server's instructions tell the
agent to use these tools rather than Chrome inside cmds, and Chrome only when you ask for it, for pages that need your
Chrome sign-ins (browser panes do not share them), or for what `browser_eval` cannot do (file uploads). Outside a cmds
terminal (`CMDS_PANE_ID` not set) the server offers no tools, so registering it for every project is harmless.

cmds registers it by itself: when it starts, when you add a Claude account, and when Claude Code reports a config
folder in a pane (at most once a minute, so an account you sign in to while cmds runs is covered), it adds `cmds mcp`
(by the full path of the CLI inside cmds.app) where it is missing:

- Claude Code: plain `claude` (`~/.claude.json`) and every [Claude account](#several-claude-accounts) whose folder
  exists, each with `claude mcp add --scope user` (each config folder has its own MCP servers);
- Codex: a `[mcp_servers.cmds]` table appended to `~/.codex/config.toml` (or `$CODEX_HOME`), with `env_vars` as
  below; the previous file is copied to `config.toml.cmds-backup-<time>`;
- [Antigravity CLI](#antigravity-cli): `agy mcp add cmds … mcp` (into `~/.gemini/config/mcp_config.json`) when
  `~/.gemini/antigravity-cli` exists. agy starts the server as its own child, so it knows the pane it runs in.

A server already registered under any name that runs `cmds mcp` counts and is left alone. Each config is done once:
one you remove is not added again, unless its config folder is made again (a new sign-in in a new folder), which counts
as a new config. If cmds.app moves, its own entries are pointed at the new place. A notification
lists what was added; agents started afterwards have the tools. Settings › Agents › **Register cmds' MCP server with
your agents** turns this off; turning it on again registers everywhere it is missing, also where you removed it.

By hand (the agent starts `cmds mcp` itself; `cmds` is on `PATH` in cmds terminals):

```sh
claude mcp add --scope user cmds -- cmds mcp      # Claude Code
```

```toml
# Codex: ~/.codex/config.toml
[mcp_servers.cmds]
command = "cmds"
args = ["mcp"]
# Codex starts MCP servers with a cleaned environment; pass on the variables that tell cmds which terminal it runs in.
env_vars = ["CMDS_PANE_ID", "CMDS_WORKSPACE_ID", "CMDS_SOCKET_PATH"]
```

Other MCP clients take the same command (`cmds mcp`). The [skill](#skill) adds the working rules around it (helper
panes, dev servers, when to notify); both can be used together.

### Memory before heavy jobs

Several agents building and testing at once can run the Mac out of memory. Before a build, a test run, a type check
or a dev server, an agent should call `system_stats` (or run `cmds stats`): at `advice: wait` the memory pressure is
warning or critical, so it should not start another heavy job, but wait until the advice is `ok` again or run its jobs
one at a time. `list_processes` shows what its own panes use and which leftover processes (dev servers, test runners
whose pane was closed) hold memory; it can ask you to stop them (`cmds top --leftover`, `cmds kill PID`, or the
sidebar's leftover row; [Memory and leftover processes](workspaces-and-panes.md#memory-and-leftover-processes)).

### Browser DevTools

For debugging a web front end in a browser pane without screenshots and hand-written JavaScript (CLI and MCP alike):

```sh
cmds browser console --level warn          # warnings and errors since the page loaded (--follow, --clear)
cmds browser tree                          # - textbox "Email" [ref=e4] …
cmds browser fill e4 me@example.com        # or a CSS selector: cmds browser fill '#email' …
cmds browser click e7
cmds browser wait-for --text "Welcome" --timeout 10
```

- **Console**: every `console.debug/log/info/warn/error`, uncaught error (with its file and line) and unhandled
  promise rejection of the page, from the first line of each page on, also before anyone asks. The last 1000 are
  kept per pane (older ones are counted as dropped); a page logging more than 200 messages a second has the rest
  counted instead. Values are recorded as text (objects as JSON). Only the main frame: not iframes, and in the
  [responsive view](workspaces-and-panes.md#responsive-view) only the first frame.
- **Tree and refs**: links, buttons, form fields (with their value and checked/disabled state), headings, images,
  landmarks and lists, named the way assistive technology names them (`aria-label`, `<label>`, `alt`, text). Hidden
  elements are left out. A ref stays valid for its element until the page navigates; a ref of an element that is
  gone gives an error asking for a new tree.
- **click** scrolls the element into view and sends pointer and mouse events, then a click. **fill** sets the value
  with the element's own setter and sends `input` and `change`, so React, Vue and similar see the change; selects
  take an option's value or text, checkboxes and radio buttons `true` / `false`. These events are synthetic
  (`isTrusted` is false); a page that only accepts real input needs a person.
- **wait-for** polls every 100 ms for a visible element matching the selector, or visible text, and fails with a
  timeout error after the timeout (default 5 s, at most 60 s; 0 checks once). When the page navigates meanwhile, it
  goes on waiting on the new page.
- All of it works on pages with a strict Content Security Policy: WebKit injects cmds' scripts itself, so the page's
  policy does not apply to them (the console hook runs in the page's own JavaScript world, everything else in a world
  the page cannot see).

**cmds › Settings… › General › Allow Safari's Web Inspector** (off by default) lets you inspect browser panes with
Safari › Develop › (this Mac) › cmds; turn on Show features for web developers in Safari's Advanced settings first.

## Codex CLI

### Hooks

`cmds hook codex` reads a [Codex hook](https://developers.openai.com/codex/hooks) payload from stdin and tells cmds
about the Codex pane (`agent.codex_hook`):

- `PermissionRequest`: needs you (orange), notifies with what Codex wants to do (its description, else the command).
- `Stop`: the turn ended, notifies with the first line of the reply. Prints `{}`, the JSON Codex expects from a `Stop`
  hook.
- `UserPromptSubmit`, `PreToolUse`, `PostToolUse`: working; an older notification of the pane is cleared.
- `Interrupt` (you pressed Esc): idle, no notification.
- A turn that a usage limit or an error stops sends no `Stop`: the pane goes back to idle once Codex's title spinner
  stops.

Other events are ignored, `SessionEnd` too (Codex also sends it after 30 idle minutes). Only the event, session id,
directory and notification text reach the app, never the prompt, the tool input or its output. Add to
`~/.codex/hooks.json` (or the same tables in `~/.codex/config.toml`, not both):

```json
{
  "hooks": {
    "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "command -v cmds >/dev/null && cmds hook codex || true" }] }],
    "Stop":              [{ "hooks": [{ "type": "command", "command": "command -v cmds >/dev/null && cmds hook codex || echo '{}'" }] }],
    "UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "command -v cmds >/dev/null && cmds hook codex || true" }] }],
    "PreToolUse":        [{ "hooks": [{ "type": "command", "command": "command -v cmds >/dev/null && cmds hook codex || true" }] }],
    "PostToolUse":       [{ "hooks": [{ "type": "command", "command": "command -v cmds >/dev/null && cmds hook codex || true" }] }],
    "Interrupt":         [{ "hooks": [{ "type": "command", "command": "command -v cmds >/dev/null && cmds hook codex || true" }] }]
  }
}
```

Then open `/hooks` in Codex once and trust them: Codex runs a new or changed hook only after you do.

- **Which pane**: Codex runs hooks with its own environment, and TUIs on the shared app-server daemon run them in the
  daemon, whose `CMDS_PANE_ID` may be another pane's. cmds therefore takes the pane whose Codex session (from its
  session file) has the payload's `session_id`; for a session not matched yet, the pane in `CMDS_PANE_ID` or the only
  Codex pane in that directory whose session is not known yet. When it cannot tell, the event is dropped rather than
  shown on another pane. A daemon started outside cmds has no `CMDS_SOCKET_PATH`, and its hooks do nothing.
- **Local panes only**: Codex in SSH panes keeps using OSC 9 notifications (below).
- Use the hooks or the OSC 9 notifications below, not both: with both, every turn notifies twice.

### Terminal notifications (OSC 9)

Without hooks, Codex's TUI can emit OSC 9 notifications; enable them for every turn in `~/.codex/config.toml`:

```toml
[tui]
notifications = true
notification_method = "osc9"
notification_condition = "always"   # cmds keeps the ring off for the pane you are looking at
```

The sidebar then shows Codex's last message when a turn ends or an approval is needed. (`notify = [...]` is left
alone; it may already be used by other tools.)

The [cmds skill](#skill) works for Codex too (browser panes instead of Chrome, helper panes, previews). Install:

```sh
mkdir -p ~/.codex/skills/cmds && cp integrations/claude/skills/cmds/SKILL.md ~/.codex/skills/cmds/
```

[Schedules](schedules.md) can continue a Codex session, type into a Codex pane, or run when Codex's limit resets;
cmds types into Codex only when its stricter idle rules hold.

Usage needs no setup: cmds finds the session file of each `codex` running in a pane (also when the shared app-server
daemon writes it) and reads only its session id and directory (`session_meta`), usage events (`token_count`) and model
(`turn_context`) — never the conversation. Of a turn Codex refuses at the account's usage limit (`task_complete` with
`usage_limit_exceeded`) it keeps only that the limit was reached and the reset time from the message.

## Antigravity CLI

`cmds hook agy-status` reads the JSON Google Antigravity's CLI (`agy`) passes to a custom status-line command and
reports, for the pane, the model, the context window (ctx) and the quota windows (`gemini-5h`, `gemini-weekly`,
`3p-5h`, …, shown as `Gemini 5h`, `Gemini 7d`, `3P 5h`; used = 1 − `remaining_fraction`). Add to
`~/.gemini/antigravity-cli/settings.json`:

```json
{
  "statusLine": { "type": "command", "command": "cmds hook agy-status", "stack_with_default": true }
}
```

**Settings › Agents › Antigravity limits › Set Up…** does this for you with the full path of cmds' own CLI (it keeps a
copy of the file, and asks before replacing another status line). Written by hand, use the full path too
(`/Applications/cmds.app/Contents/Resources/bin/cmds hook agy-status`): agy in a terminal outside cmds otherwise runs
whatever `cmds` its PATH finds, which may be an old copy or a broken link. A status line with a bare `cmds` or a path
that is gone shows **Update** there, and cmds says so once in a notification at launch (click it to open Settings ›
Agents); it never changes the file without you.

`stack_with_default` keeps agy's own status line (the hook prints nothing). The hook finds the `agy` process among its
ancestors, so the usage goes when agy exits. Only those figures are sent to the app; the JSON's account e-mail and
paths are not read. Checked with agy 1.5.2.

The quota windows show in the sidebar footer (as `agy 5h`, `7d`; other model groups by name, `3P 5h`), the menu bar,
the widget and the phone. agy reports them only while an interactive session runs: `agy -p` never runs the status line
(checked with agy 1.5.9). agy in a terminal outside cmds sends only the quota (the command runs with no cmds pane).
The last figures are kept across restarts (`antigravity-limits.json` in the support directory) until their windows
reset, dimmed after an hour without a report. Antigravity has no notification or state hooks in cmds yet: its state
comes from the status-line reports and the terminal title like other agents.

## Usage and limits

The sidebar shows, per workspace, the agent of its focused (else most recently active) pane — model, context %, cost
and the 5-hour limit, details in the tooltip — and in its footer the account limits per agent (5-hour / 7-day windows,
Claude's spend limit; orange from 80 %, red from 95 %, reset times in the tooltip). The phone shows the same, and
`cmds agents` lists everything (`cmds ls` has a short summary per pane, `cmds stats` the limits).

- **Claude Code**: add `cmds hook claude-status` to the status line ([above](#usage-and-limits-status-line)).
- **Codex**: nothing to configure. Account limits come from the session files of Codex in panes and, for runs no pane
  shows (`codex exec`, `codex review` started by an agent), from the 4 newest session files of today and yesterday
  modified in the last 6 hours (`$CODEX_HOME/sessions`, else `~/.codex/sessions`; checked every 15 s, only the end
  of each file, usage events only).
  - **Limit reached**: when Codex refuses a turn because the account hit its usage limit, the window whose reset
    matches Codex's "try again at …" time shows 100 %; if none does, a `limit` 100 % entry with that reset is added
    (rings, sidebar footer, red dot, `cmds agents`, `agent.list`, schedules waiting for Codex's limit). It stays until
    the reset passes or a newer usage event with figures arrives. When the message has no time cmds understands, the
    entry has no reset and is dropped after 24 hours.
  - **Kept across launches**: the newest Codex limits are saved in `codex-limits.json` in the support folder and read
    at launch; windows that have reset since are left out.

Data older than 3 minutes is dimmed (idle agent); it disappears when the agent exits. How it is collected:
[internals/architecture.md](../internals/architecture.md#agent-usage).

## Resuming sessions

When cmds restarts (update, crash, reboot) the workspaces and panes come back, but the agents running in them are
gone. cmds remembers per terminal pane the agent session that ran there and offers to resume it.

- **What is remembered** (in `session.json`, `agentSessions` per workspace): agent (Claude Code / Codex), session id,
  the pane's directory when the session first appeared, the SSH host for SSH panes, pane title, model and last seen.
  Claude Code's id comes from its status line (`cmds hook claude-status`, so that must be set up); Codex's from its
  session file. A session is forgotten when its agent is seen to exit (or on Dismiss), not when cmds quits.
- **On launch** (View › Resume Agent Sessions on Launch):
  - *Ask* (default): a bar at the top of the pane — "Resume Claude Code session “topic” (model, 2 h ago)" with
    **Resume**, **Resume All (n)** (every offered pane of the workspace; shown when there is more than one) and **Dismiss** (forget it). Also
    Pane › Resume Agent Session / Resume All Agent Sessions.
  - *Always*: resumes every remembered session by itself once the pane's shell prompt is ready.
  - *Never*: forgets them.
- **What is typed**, into the pane's own shell and only once: `cd '<dir>' && claude --resume <id>` or
  `cd '<dir>' && codex resume <id>` (Return included). Only ids made of letters, digits, `-`, `_`, `.` are accepted;
  a directory that cannot be quoted the same way in sh/zsh/fish/tcsh is left out of the command. A local Claude Code
  session that was started but never given a prompt has no transcript yet (Claude Code writes it at the first
  prompt), so `--resume` would only say "No conversation found": cmds types `cd '<dir>' && claude` (with the
  account's `CLAUDE_CONFIG_DIR`) instead, and `cmds sessions` shows that command.
- **When**: the shell must be the pane's foreground process, its screen settled, and the cursor right after a prompt
  ending in `$ # % > ❯ ➜ λ »` with nothing typed (a half-typed command line waits; a prompt ending in another
  character never resumes by itself: Cancel and type the command shown by `cmds sessions`). A pane that runs Claude
  Code or Codex (any such process on its terminal, or one reporting usage) is never typed into; its offer is dropped.
- **SSH panes**: the session belongs to the server. Resume connects the pane if needed (never on launch, also not
  in *Always* mode) and types on the remote shell once it reported its prompt (`cmds-remote.sh prompt`) or the screen
  settled on a line ending in a prompt character (never at a password / passphrase / host-key question). When an
  SSH connection drops while an agent ran, the pane offers to resume it after reconnecting.
- **CLI/API**: `cmds sessions` lists remembered sessions (`agent.sessions`); `cmds resume [--pane P | --all]` queues
  resumes (`agent.resume`). From a server, `cmds-remote` sockets only reach their own pane (`--all` is refused).

Isolated instances (`CMDS_SUPPORT_DIR`) keep the setting in memory, starting from `CMDS_AGENT_RESUME=ask|always|never`.

### Recent sessions

File › Recent Agent Sessions (also the clock button next to **+** at the bottom of the sidebar) lists the 5 newest
Claude Code and Codex sessions cmds saw in any pane: agent, title, model, when it was last seen and its folder (and
SSH host). Unlike the per-pane memory above, these stay after the agent exits or its pane is closed.

- **Choosing one**: if a pane still has the session (running it, offering it, or remembering it; checked in the
  menu), cmds shows that pane, and queues its offer if it has one, so a session is never resumed twice. Otherwise
  cmds opens a new workspace in the session's folder, under its Claude account (local panes) or connected to its SSH
  host, and queues the resume there: the command is typed into that new shell once its prompt is ready, by the same
  rules as above. Nothing is typed into an existing pane. A folder that no longer exists is reported instead.
- **What is kept**: up to 20 sessions, newest first, one per agent + session id + host, in `agent-history.json` in
  the support directory (`CMDS_SUPPORT_DIR` for an isolated instance), written with the session state, not on every
  usage update. Sessions remembered by panes before this list existed are added on launch. **Clear Menu** empties it.
- **CLI/API**: `cmds sessions --recent` (`agent.history`, local socket only) lists them with the pane holding each,
  if any, and the command a new pane would get.

## Several Claude accounts

If you have more than one Claude account of your own (say a work and a personal subscription), cmds can run Claude
Code panes under each of them and move a session to the next account when one hits its usage limit.

> Use only your own accounts. You are responsible for following Anthropic's terms for each account.

### Accounts

An account is a name and a Claude Code config directory (`CLAUDE_CONFIG_DIR`). Claude Code keeps everything of an
account there (sign-in, settings, sessions); `~/.claude` is the one plain `claude` uses. cmds stores only the names
and paths (in `claude-accounts.json` in its support directory), never reads, copies or stores credentials, and never
signs in for you. The one thing it looks at in a folder is which Claude account it is signed in to (the account id in
its `.claude.json`, only compared, never kept or shown): two folders signed in to the same Claude account share one
limit, so they show **same sign-in as …**, hit their limit together and a session never moves between them.

1. Add the accounts in **Settings › Agents › Claude accounts › Manage…** (+, a name and a folder such as
   `~/.claude-work`) or with `cmds accounts add work ~/.claude-work`. Their order is the switching order (▲▼,
   `cmds accounts move`).
2. Sign in once per account yourself: select it and click **Sign In** (or the sidebar's account menu › **Sign In**,
   or `cmds accounts login work`). A workspace opens under the account and runs `claude auth login`; finish in the
   browser. An account shown as **not signed in** or **same sign-in as …** needs this (the second: sign in as the
   other Claude account).
3. Set up each account's `settings.json`: select it and click **Set Up for cmds…** (or the account menu › **Set Up for cmds**, or
   `cmds accounts setup work`). cmds adds what is missing and nothing else: the status line when there is none (the
   first account's, when that one reports to cmds) and the hooks; a status line of your own is left alone, and the
   previous file is kept as `settings.json.cmds-backup-<time>`. An account shown as **not set up** needs this: its
   workspaces have no account button, its limit is not seen and its sessions cannot be switched. By hand, it is
   `<config dir>/settings.json` like `~/.claude/settings.json`: the
   [hooks](#notifications-hooks) and, needed for switching, the [status line](#usage-and-limits-status-line), which
   tells cmds the session id and which account Claude Code runs under. Copying the file or symlinking it to
   `~/.claude/settings.json` both work; cmds does not touch it.
4. **Share Sessions…** ([below](#sharing-sessions-between-accounts)).

Everything here also works without the command line: the account button of a workspace in the sidebar opens a menu
with the accounts to continue the session with, **Switch Automatically at the Limit**, **Sign In**, **Set Up for cmds**,
**Clear Limit**, **Share Sessions…** and **Manage Accounts…**. (A workspace has the button once its account is set
up; until then use **Settings › Agents › Claude accounts › Manage…**.)

### Starting Claude Code under an account

`cmds new --account work -- claude` (or `cmds split --account work -- claude`) opens a pane whose shell has
`CLAUDE_CONFIG_DIR` set to the account's folder, so `claude` and everything started from it uses that account.
`--account auto` takes the first account in order that has not hit its limit. The pane keeps its account after a
restart. A split without `--account` (also **Split Right** / **Split Down** in the menu) does not take the account of
the pane it splits: its shell has no `CLAUDE_CONFIG_DIR`, so `claude` there uses `~/.claude`. Removing an account takes
it off the panes that had it (their shells keep the folder they were started with). With accounts set up, the sidebar
shows the account of each workspace's Claude Code session after the model as a coloured icon and its name (one colour
per account, `→ home` while a switch waits); without them, after the model (`Claude Opus @work`). Its tooltip says
`Account: work`, `cmds ls` and `cmds sessions` print `account work`.

**Switching from the sidebar**: click the account (or right-click the row › **Claude Account**) and choose another:
the same as `cmds accounts switch --to NAME` ([below](#when-an-account-hits-its-limit)) — Claude Code quits once it
is idle and the session continues under that account. Accounts at their limit show when they reset; if the session
cannot move (no session id from the status line, sessions not shared, an SSH pane) cmds says why. The compact
sidebar shows the account as a person icon in its colour left of the workspace number (the name in its tooltip); click
it for the same menu. With several Claude Code panes in a workspace, the menu has a section per pane (its task or pane
id and its account), so each can be switched; the row shows the focused (else latest) one. While a switch waits for
Claude Code to be idle the button shows `→ name` and the menu has **Cancel Switch** (as Cancel on the pane's banner). Once Claude Code has restarted with the new account
there is nothing to cancel: choose the previous account to switch back.
A pane where you start `claude` yourself gets the account whose folder matches
the `CLAUDE_CONFIG_DIR` Claude Code reports through the status line (none set: the account using `~/.claude`, if
any). An account on `~/.claude` is a plain `claude`: cmds runs it without `CLAUDE_CONFIG_DIR` (`env -u
CLAUDE_CONFIG_DIR claude …`), because Claude Code keeps a plain `claude`'s sign-in apart from the one it uses with
`CLAUDE_CONFIG_DIR=~/.claude`, and the two may be different Claude accounts.

**A Claude Code that does not report**: when a pane runs Claude Code whose config folder has no cmds status line (a
`~/.claude` made again by signing in afresh, typically), cmds sees no session, limit or account for it. After 45 s
without a report it offers once **Set Up for cmds** for that folder (adding it as an account first if it is none; only
when you have accounts), drops a session it remembered in that pane from before that Claude Code started, and a switch
says that the folder is not set up instead of moving a stale session. Claude Code picks up the new settings as it
runs.

### When an account hits its limit

Every 2 s cmds reads the last 40 lines of each local pane running Claude Code for a line that *starts* with one of
Claude Code's limit messages (a file or diff that only contains the words does not count):

- usage limit: `You've hit your limit · resets 3pm (Asia/Tokyo)`, `You've hit your weekly limit · resets Nov 7, 9am`,
  `5-hour limit reached ∙ resets 3pm`, `Claude usage limit reached. Your limit will reset at 3pm (…)`,
  `Usage limit reached · continuing automatically at 4:50pm` (`Usage limit reset · Continuing automatically` ends it);
- API rate limit: `API Error: 429 {…"rate_limit_error"…}`, `API Error: Rate limit reached`.

A status-line window (5-hour, 7-day, spend) at 100 % counts too. Warnings (`Approaching usage limit`, `You've used 90%
of …`) and limits of the conversation itself (`Context limit reached · /compact or /clear to continue`), which another
account would not lift, do not. The account is marked limited until the reset time in the message (in its time zone, else the
Mac's); without one, for 5 hours (usage limit) or 15 minutes (rate limit). Settings and `cmds accounts` show it;
**Clear Limit** / `cmds accounts clear NAME` forgets it.

Then, if you have accounts set up:

- **Ask** (default): a bar at the top of the pane — "“work” hit its limit (resets 15:00)." with **Continue with
  “personal”** and **Dismiss** — the ring, the sidebar text and, when cmds is in the background, a macOS notification
  with **Continue with Next Account**. When it cannot switch, the bar says why: every other account is limited, the
  session id is unknown (no status line in that account), or the session is not reachable from the next account
  (**Settings…** to share sessions). If the offered account hits its limit too before you click, the bar offers the
  next free one instead.
- **Automatic** (Settings › Claude Accounts › Switch automatically, `cmds accounts auto on`): the same, without asking.

Switching to the next account in order that has not hit its limit, in that pane only:

1. Waits until Claude Code is idle at its prompt: it is the pane's foreground process, not working, no subagent
   running, and the screen has not changed for 2 s. Never mid-turn.
2. Sends Ctrl-C twice in quick succession, as Claude Code asks to quit (a draft typed in its prompt is cleared by the
   first one), again if needed; after three tries without effect it gives up and says so.
3. Once the shell is back, types `cd '<dir>' && env CLAUDE_CONFIG_DIR='<next folder>' claude --resume <id>`
   (`env -u CLAUDE_CONFIG_DIR claude …` for `~/.claude`) the way
   [resuming](#resuming-sessions) does (at an empty shell prompt, once). The conversation continues under the next
   account; ask Claude to go on with what it was doing.

When every other account is limited too, the bar offers **Continue at 15:01** (the notification **Continue When It
Resets**): a [schedule](schedules.md) types `continue` into the session one minute after the account's reset.

`cmds accounts switch [--pane P] [--to NAME]` does the same on request, also without a limit. Accounts are for local
panes; SSH panes are never switched.

### Sharing sessions between accounts

Claude Code keeps each session in `<config dir>/projects/<project>/<session id>.jsonl`, and `claude --resume` looks
only in its own config directory. So that the next account can resume a session, the accounts share one `projects`
folder: **Share Sessions…** (or `cmds accounts share`, then `--yes`) shows what it will do and, when you confirm,

- keeps the first account's `projects` folder (the first one whose folder exists) as the shared one; if that is
  already a link (you reordered the accounts after sharing), the folder it links to stays the shared one. A link to a
  folder that is no account's own (made by hand) is left alone, and the first account with a `projects` folder of
  its own keeps it as the shared one,
- turns every other account's `projects` into a symbolic link to it; an account's own `projects` folder is renamed to
  `projects.before-cmds-<date>` first (kept, never deleted; if the link then cannot be made, the folder is moved
  back), and the sessions in it that the shared folder does not have are copied there (nothing in the shared folder
  is overwritten), so they can be continued under any account at once,
- leaves alone a `projects` that already links elsewhere, and accounts whose folder does not exist yet.

Before switching, cmds checks that the session's file is reachable from the next account (it lists folder names; it
does not read transcripts). A session never given a prompt has no file yet: it switches too, and Claude Code starts
anew under the next account in the same folder. The first time an account opens a project, Claude Code may ask whether you trust the
folder.

### Claude in Chrome with several accounts

The Claude in Chrome extension reaches Claude Code through one file per browser
(`NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json`) that names a script in the config folder of
the account that last turned it on: `<config dir>/chrome/chrome-native-host`. When that folder is removed or made
again (signing in afresh, moving accounts around), the extension cannot connect under any account. cmds notices it
when it starts, when Settings › Claude Accounts opens, after adding an account or sharing sessions, and when Claude
Code starts in a pane, and offers **Repair** once: it writes the missing script (a copy of another account's, else
one that runs `claude --chrome-native-host`), overwrites nothing and leaves the browser's file as it is.
`cmds accounts` says `Claude in Chrome cannot connect` and `cmds accounts chrome` repairs it. Each account still
needs Claude in Chrome turned on for itself (`/chrome` › Enabled by default, or `claude --chrome`): the setting is
kept in each config folder.

## Moving to a new version

To move workspaces with their agent sessions from a running cmds to a newly started one (an update that is not
a plain relaunch, a second build, another Mac):

1. In the old instance: `cmds export -o ~/cmds-workspaces.json` (or File › Export Workspaces…). Use the CLI of the
   new build if the old one has no `export`: it falls back to the old APIs (`cmds export --legacy`).
2. Quit the old instance (its agents end; their sessions stay resumable).
3. Start the new one.
4. `cmds import ~/cmds-workspaces.json` (or File › Import Workspaces…). The workspaces come back with their
   layout and directories; each terminal pane that had a Claude Code / Codex session gets it as resume offer, as
   after a relaunch: *Ask* shows the banner (`cmds resume --all` resumes all), `--resume always` resumes once each
   prompt is ready, `--resume never` skips them. `--replace` closes the workspaces that were open.

The session ids and directories must exist where the agent runs: on another Mac copy the agent's own session
files too (`~/.claude/projects`, `~/.codex/sessions`); SSH panes resume on their server as before. Bundle format
and checks: [reference/cli.md](../reference/cli.md#moving-workspaces-to-another-cmds).

## Agents on a server (SSH panes)

Open the server with **File › New SSH Workspace…** or `cmds new --ssh HOST`
([SSH workspaces](workspaces-and-panes.md#ssh-workspaces)). The pane forwards a restricted cmds socket over the same
SSH connection and sets `CMDS_SOCKET_PATH`/`CMDS_PANE_ID` there. Use **Pane › Install Remote Helper…** once per
server: it installs `~/.local/bin/cmds-remote.sh` (and `cmds` when the server has none), so the Claude Code hook and
status-line lines above work on the server unchanged (`cmds-remote.sh` speaks `hook claude` / `hook claude-status`,
`notify`, `status`). Codex: its OSC 9 notifications travel through SSH as usual. The remote helper can only reach its
own pane ([internals/ssh.md](../internals/ssh.md#what-the-server-may-do-enforced-in-the-app)).

## Other agents

Use whatever "on finish / needs input" hook the tool has to run `cmds notify "<text>"` (no-op outside cmds is up to
the hook: guard with `command -v cmds >/dev/null &&`), or enable its terminal notifications (OSC 9/777 or bell).
For usage figures, a tool can report its own numbers with `agent.report` (`agent: "other"`, [api.md](../reference/api.md)).
