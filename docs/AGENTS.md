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

## Other agents

Use whatever "on finish / needs input" hook the tool has to run `cmds notify "<text>"` (no-op outside cmds is up to
the hook: guard with `command -v cmds >/dev/null &&`), or enable its terminal notifications (OSC 9/777 or bell).
