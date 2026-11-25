# Kept instructions and idle panes

> Hand work to an agent that is busy without waiting for it, and see which agents have stopped: `cmds queue` keeps an
> instruction for a pane and types it in when the agent is free; `cmds idle` lists the panes with nothing in progress.

## Keeping an instruction for a busy pane

```sh
cmds queue add --pane p12 "When the build is done, run the tests and report the failures"
cmds queue add --workspace sales - < instructions.txt     # the only terminal pane of the workspace titled "sales"
cmds queue list
cmds queue cancel q1a642b50
```

`cmds queue add` returns at once. cmds keeps the text and pastes it into the Claude Code or Codex in that pane, then
presses Return, as soon as the agent is free. Several instructions for one pane go in one at a time, oldest first, each
after the agent has finished the one before. An instruction waits as long as it takes (it does not time out), also
across a restart of cmds: the pane keeps a tag in the saved session, as a [schedule](schedules.md)'s pane does, and the
instructions are in `pane-queue.json` in the support folder (readable by you only).

The pane is `--pane P` (an id from `cmds ls`) or `--workspace TITLE`. Words are joined with spaces; `-` reads the text
from stdin, with its line breaks. At most 20 instructions wait per pane, each up to 8 KiB.

### When it is typed

The rules are a schedule run's ([Safety](schedules.md#safety)); an instruction is typed only when all of these hold:

- Claude Code or Codex is in the foreground of the pane, not working, and no subagent runs;
- it does not ask for input or permission and shows no choice or dialog: Claude Code's input box must be on screen
  (a paste and Return would answer a dialog such as the folder trust question);
- **its input box is empty.** Text a person typed there and has not sent stays as it is: the instruction waits until
  the box is empty again. A placeholder or a suggested prompt (drawn faint) does not count as typed text;
- no schedule run, account switch or queued resume is using the pane.

Otherwise it waits, and `cmds queue list` says why:

```
q27ae3e08  p12  sales  next · waits: its input box holds typed text  When the build is done, run the tests and…
q29eec7ff  p12  sales  place 2 · behind 1  Then tidy the folder
  q1a642b50  p12  delivered 2026-11-25 15:38
```

Reasons: the agent is working; it asks for input or permission, or shows a dialog; its input box holds typed text; no
agent runs in the pane (a shell is never typed into: start the agent, the instruction then goes in); another program
runs in the pane; a schedule run, account switch or resume is using the pane; the pane is not open.

The lines below the waiting ones are the last 50 instructions that left the queue: `delivered` (typed, and the agent
was seen starting on it), `unconfirmed` (typed with Return, the agent was not seen starting within 20 s), `failed` (the
agent left the foreground between the paste and Return; nothing more was typed) or `cancelled`. An instruction is typed
once and never again. `cmds queue cancel ID` takes out one that still waits.

`cmds send` is unchanged: it types at once, whatever the pane is doing.

## Panes with nothing in progress

```sh
cmds idle                 # nothing in progress for 30 minutes or longer
cmds idle --minutes 10
```

```
p3  sales  claude  idle 45m00s (since 2026-11-25 15:15)
p7  legal  codex  asks for input ≥2h05m (since 2026-11-25 13:55) · 2 kept instructions waiting
```

A pane is listed when its agent waits for a prompt (`idle`) or asks for input or permission (`asks for input`), no
subagent runs, nothing is being typed into it by a schedule or a kept instruction, and that has been so for the given
minutes (default 30; 1 to 10080). Longest first. `≥`: cmds has not seen this agent work since it started watching the
pane (since cmds started, or the agent did), so it may have been idle for longer. A pane with kept instructions
waiting is listed too: something holds them (`cmds queue list`). Panes without an agent are not listed. Read only.

What it cannot see: a background command the agent started and is waiting for, or a timer inside the agent's session.
A [schedule](schedules.md) that will type into the pane later does not count as work in progress either.

API: `queue.add`, `queue.list`, `queue.cancel`, `agent.idle` ([reference](../reference/api.md)); local socket only.
