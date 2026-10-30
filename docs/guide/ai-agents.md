# Using AI coding agents in cmds

> How to connect Claude Code, Codex and other agents to cmds: notifications, usage and limits, the Claude skill,
> session resume and agents on SSH servers.

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

`cmds hook claude` reads the hook JSON from stdin and calls `notify` for the pane Claude Code runs in:

- `Notification` (permission prompts, waiting for input) → `Claude Code: <message>`
- `Stop` → `Claude Code: <first line of Claude's last reply>` (`last_assistant_message`, else the transcript), or
  `Finished`

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
focus (`--no-focus`), run dev servers in a split and read their output, check web UIs with
`cmds browser snapshot/eval`, show generated files with `cmds open`, show progress with `cmds status`, and never type
into panes it did not create. It is used only when `CMDS_PANE_ID` is set. Install:

```sh
mkdir -p ~/.claude/skills/cmds && cp integrations/claude/skills/cmds/SKILL.md ~/.claude/skills/cmds/
```

## Codex CLI

Codex's TUI emits OSC 9 notifications; enable them for every turn in `~/.codex/config.toml`:

```toml
[tui]
notifications = true
notification_method = "osc9"
notification_condition = "always"   # cmds keeps the ring off for the pane you are looking at
```

The sidebar then shows Codex's last message when a turn ends or an approval is needed. (`notify = [...]` is left
alone; it may already be used by other tools.)

Usage needs no setup: cmds finds the session file of each `codex` running in a pane (also when the shared app-server
daemon writes it) and reads only its session id and directory (`session_meta`), usage events (`token_count`) and model
(`turn_context`) — never the conversation.

## Usage and limits

The sidebar shows, per workspace, the agent of its focused (else most recently active) pane — model, context %, cost
and the 5-hour limit, details in the tooltip — and in its footer the account limits per agent (5-hour / 7-day windows,
Claude's spend limit; orange from 80 %, red from 95 %, reset times in the tooltip). The phone shows the same, and
`cmds agents` lists everything (`cmds ls` has a short summary per pane, `cmds stats` the limits).

- **Claude Code**: add `cmds hook claude-status` to the status line ([above](#usage-and-limits-status-line)).
- **Codex**: nothing to configure.

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
  a directory that cannot be quoted the same way in sh/zsh/fish/tcsh is left out of the command.
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
