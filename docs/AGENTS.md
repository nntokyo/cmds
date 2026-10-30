# Using AI coding agents in cmds

Each terminal has `cmds` on `PATH` (the copy inside the app bundle) and `CMDS_SOCKET_PATH`, `CMDS_WORKSPACE_ID`,
`CMDS_PANE_ID` in its environment, so an agent running in a pane can drive the app with the CLI (docs/CLI.md).
`TERM_PROGRAM=ghostty` and `TERM=xterm-ghostty`, so agents treat the pane like Ghostty (Shift+Enter, true color).

## Attention: how a pane lights up

Any of these lights the pane's ring (unless it is the pane you are looking at), sets the sidebar text and, with the
iOS companion paired, notifies the phone:

- an OSC 9 / OSC 777 desktop notification from the program,
- the terminal bell (sidebar text "Bell"),
- `cmds notify [--title T] <text>` (e.g. from an agent's hook).

## Claude Code

1. Hooks (exact text in docs/CLI.md): `Notification` and `Stop` run `cmds hook claude`, which shows
   "Claude Code: <message>" for permission prompts / idle input and the first line of the final reply on stop.
   The hook is a no-op outside cmds.
2. Skill: `integrations/claude/skills/cmds/SKILL.md` teaches Claude to open helper panes without stealing focus
   (`--no-focus`), check web UIs with `cmds browser snapshot/eval`, show progress with `cmds status`, and never type
   into panes it did not create. Install: `mkdir -p ~/.claude/skills/cmds && cp integrations/claude/skills/cmds/SKILL.md ~/.claude/skills/cmds/`.

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

## Usage and limits

The sidebar shows, per workspace, the agent of its focused (else most recently active) pane — model, context %, cost
and the 5-hour limit, details in the tooltip — and in its footer the account limits per agent (5-hour / 7-day windows,
Claude's spend limit; orange from 80 %, red from 95 %, reset times in the tooltip). The phone shows the same, and
`cmds agents` lists everything.

- **Claude Code**: add `cmds hook claude-status` to the status line (snippet in docs/CLI.md).
- **Codex**: nothing to configure. cmds finds the session file of each `codex` running in a pane (also when the
  shared app-server daemon writes it) and reads only its usage events (`token_count`) and model (`turn_context`) —
  never the conversation.

Data older than 3 minutes is dimmed (idle agent); it disappears when the agent exits.

## Resuming sessions

When cmds restarts (update, crash, reboot) the workspaces and panes come back, but the agents running in them are
gone. cmds remembers per terminal pane the agent session that ran there and offers to resume it.

- **What is remembered** (in `session.json`, `agentSessions` per workspace): agent (Claude Code / Codex), session id,
  the pane's directory when the session first appeared, the SSH host for SSH panes, pane title, model and last seen.
  Claude Code's id comes from its status line (`cmds hook claude-status`, so that must be set up); Codex's from its
  session file. A session is forgotten when its agent is seen to exit (or on Dismiss), not when cmds quits.
- **On launch** (View › Resume Agent Sessions on Launch):
  - *Ask* (default): a bar at the top of the pane — "Resume Claude Code session “topic” (model, 2 h ago)" with
    **Resume**, **Resume All (n)** (every offered pane of the workspace) and **Dismiss** (forget it). Also
    Pane › Resume Agent Session / Resume All Agent Sessions.
  - *Always*: resumes every remembered session by itself once the pane's shell prompt is ready.
  - *Never*: forgets them.
- **What is typed**, into the pane's own shell and only once: `cd '<dir>' && claude --resume <id>` or
  `cd '<dir>' && codex resume <id>` (Return included). Only ids made of letters, digits, `-`, `_`, `.` are accepted;
  a directory that cannot be quoted the same way in sh/zsh/fish/tcsh is left out of the command.
- **When**: the shell must be the pane's foreground process, its screen settled, and the cursor right after a prompt
  ending in `$ # % > ❯ ➜ λ »` with nothing typed (a half-typed command line waits; a prompt ending in another
  character never resumes by itself: Cancel and type the command shown by `cmds sessions`). A pane that runs Claude Code or
  Codex (any such process on its terminal, or one reporting usage) is never typed into; its offer is dropped.
- **SSH panes**: the session belongs to the server. Resume connects the pane if needed (never on launch, also not
  in *Always* mode) and types on the remote shell once it reported its prompt (`cmds-remote.sh prompt`) or the screen
  settled on a line ending in a prompt character (never at a password / passphrase / host-key question). When an
  SSH connection drops while an agent ran, the pane offers to resume it after reconnecting.
- **CLI/API**: `cmds sessions` lists remembered sessions (`agent.sessions`); `cmds resume [--pane P | --all]` queues
  resumes (`agent.resume`). From a server, `cmds-remote` sockets only reach their own pane (`--all` is refused).

Isolated instances (`CMDS_SUPPORT_DIR`) keep the setting in memory, starting from `CMDS_AGENT_RESUME=ask|always|never`.

## Agents on a server (SSH panes)

Open the server with **File → New SSH Workspace…** or `cmds new --ssh HOST` ([SSH.md](SSH.md)). The pane forwards a
restricted cmds socket over the same SSH connection and sets `CMDS_SOCKET_PATH`/`CMDS_PANE_ID` there. Use
**Pane → Install Remote Helper…** once per server: it installs `~/.local/bin/cmds-remote.sh` (and `cmds` when the server
has none), so the Claude Code hook and status-line lines above work on the server unchanged (`cmds-remote.sh` speaks
`hook claude` / `hook claude-status`, `notify`, `status`). Codex: its OSC 9 notifications travel through SSH as usual.
The remote helper can only reach its own pane.

## Other agents

Use whatever "on finish / needs input" hook the tool has to run `cmds notify "<text>"` (no-op outside cmds is up to
the hook: guard with `command -v cmds >/dev/null &&`), or enable its terminal notifications (OSC 9/777 or bell).
