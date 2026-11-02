# Schedules

> Start a workspace, continue a Claude Code or Codex session, or type into a pane later: at a set time, on weekdays,
> or when a limit resets. What a schedule does, when it runs, what it never does, and where to see what happened.

Open **Window › Schedules…** (also Settings › Agents › Schedules) or use `cmds schedule`
([CLI reference](../reference/cli.md)). Schedules run only while cmds runs.

## What a schedule does

A schedule has a **trigger** and an **action**.

| Trigger | When it fires |
|---|---|
| Once | At a date and time (`cmds schedule add --at "2026-11-04 02:00"`, `--at 02:00`, `--in 90m`) |
| Weekly | On the chosen weekdays at one or more times of day, 5 minutes apart at least (`--every weekdays --time 09:00,13:30`). In a time zone you choose, or the Mac's (`--tz Asia/Tokyo`) |
| When an account's limit resets | When one of your [Claude accounts](ai-agents.md#several-claude-accounts) is usable again, plus a delay (default 1 minute; `--after-limit work --delay 2m`). It follows the account: a later reset moves it; clearing the limit fires it at once |
| When Codex's limit resets | When Codex is usable again: the latest reset of a window at 100 % that cmds read in a Codex session file, plus the delay (`--after-codex-limit`). cmds learns Codex's limits only while a Codex runs in one of its panes; after cmds restarts, the time it had stays until Codex reports again |
| Every time it resets | Either limit trigger with `--repeat` (**Every time it resets** in the editor): it stays on and runs once for each new reset; a reset it has run (or skipped) never runs again, and a limit cleared early does not run it |

| Action | What happens |
|---|---|
| Start a workspace | A new workspace opens in a folder, in the background: it is not selected and does not take the keyboard. Optionally under an account (or `auto`, the first account without a limit), with a title, a **command** typed at its shell prompt (e.g. `claude`), and a **first prompt** pasted into the Claude Code that command starts, once it is idle. A weekly schedule opens a new workspace each time |
| Continue a session | A remembered Claude Code or Codex session gets a prompt (default `continue`). If the agent is running it in a pane, the prompt is pasted there once it is idle. If the pane is at its shell prompt, the session is resumed first (`claude --resume <id>` under the account, or `codex resume <id>`). If no pane holds it any more, it is resumed in a new background workspace in its folder. If several panes hold it, the pane the schedule was made for is used; when that is not one of them, the run is skipped. Codex sessions have no account |
| Type into a pane | Text goes into a pane you choose (`--send TEXT --to shell\|agent`): **as a shell command** (one line, typed at an empty prompt with Return) or **as an agent prompt** (pasted into Claude Code or Codex once it is idle, then Return). The pane is `--pane P` (default: the pane you run `cmds` in) — it keeps a tag in the saved session, so the schedule finds it again after cmds restarts — or `--workspace TITLE`, the only terminal pane of the workspace with that title. When no pane or several panes match, the run is skipped |

Examples:

```sh
# Continue this pane's session when the "work" account's limit resets.
cmds schedule add --name "Continue after reset" --after-limit work --continue

# Weekdays at 09:00: open ~/src/app under the first free account, start Claude Code and give it a task.
cmds schedule add --name "Morning tests" --every weekdays --time 09:00 \
  --start ~/src/app --account auto --prompt "Run the test suite and summarise failures" -- claude

# Tonight at 02:00: run a benchmark in a new workspace.
cmds schedule add --name bench --at "2026-11-04 02:00" --start ~/src/app -- make bench

# Every time Codex's limit resets: tell the Codex in this pane to go on.
cmds schedule add --name "Codex goes on" --after-codex-limit --repeat --send continue --to agent

# Weekdays at 18:00: run the tests in the "API" workspace's terminal, if its shell is free.
cmds schedule add --name "Evening tests" --every weekdays --time 18:00 --send "make test" --to shell --workspace API
```

### When every account is limited

When Claude Code hits its limit and no other account is free, the bar in the pane offers **Continue at 15:01**
(and the notification **Continue When It Resets**): it adds a schedule that types `continue` into the session one
minute after the account's reset. The sidebar says when.

## Safety

A schedule types only where it may, and only once:

- **Never into a busy agent.** A prompt is pasted only when Claude Code is in the foreground, not working, not
  asking for input or permission (including its numbered choices such as the folder trust question), no subagent is
  running, its screen has not changed for 2 s and shows no working line (`esc to interrupt`), no account switch is in
  progress and no resume is queued. It waits for up to 30 minutes, then the run fails.
- **Codex, more carefully.** Codex tells cmds less (no hooks), so a prompt goes into Codex only when all of these
  hold: Codex is the foreground process; cmds has matched its session file to the pane and the file has not been
  written for 90 seconds (Codex writes to it while it works); the screen has not changed for 5 seconds (its working
  line counts seconds); the bottom of the screen shows no working line and no numbered choice or approval. A Codex
  that has not finished a first turn yet has no session file to match, so it is never typed into. A pane whose agent
  cmds cannot tell is never typed into either.
- **Shell input only at an empty prompt.** A command (or a resume) is typed only when the pane's shell is in the
  foreground with nothing typed after its prompt. A pane running any other program is left alone: the run is
  skipped.
- **Only its own panes.** A run types into the pane it created, the pane holding the targeted session id, or the
  pane its target names (a pane's tag, or the only terminal pane of a workspace title); if that pane now runs another
  session or another program, or the target matches no pane or several, the run is skipped. SSH panes are never
  targets. One run at a time per pane.
- **Once.** Nothing is retried. A failed run is reported; Run Now tries again when you choose.
- **Limits.** At most 50 schedules, one active run per schedule, five active runs at once and one per pane. A prompt
  is at most 8 KB (line breaks and tabs, no other control characters); a command is one line of at most 1 KB.
- **Local only.** `schedule.*` is refused on the sockets of SSH panes, so a server cannot create schedules.
- **Visible origin.** Schedules made with the CLI or the socket API (for example by an agent) are marked in the
  window, with the pane that made them. They run without asking, like `cmds send` would.

## Before a run: the notice and Skip

A minute before a scheduled run, a notification says "Schedule “X” starts at 09:00" with **Skip** (and Open
Schedules). Skip, `cmds schedule skip ID`, or **Skip Next Run** in the window leaves out that one run: the history
notes it as skipped and the schedule moves on (a one-time schedule is turned off). Turn the notice off per schedule
(**Notify 1 minute before, with Skip** in the editor, `--no-warn`). Catch-up and Run Now runs come without one.

The sidebar's footer shows the next run (`Morning tests · 09:00`; the next three in its tooltip); click it to open
the Schedules window.

## When the Mac sleeps or cmds is not running

Schedules run only while cmds runs; cmds keeps the Mac from idle sleep by default
([Keeping the Mac awake](workspaces-and-panes.md#keeping-the-mac-awake)), but a closed lid still sleeps it.

When cmds starts, and when the Mac wakes, every schedule whose time has passed gets **one** catch-up run if it is
late by at most its **If late** setting (default: 6 hours for once and limit schedules, 15 minutes for weekly
ones); otherwise the history notes it as missed and you get a notification ("did not run at 09:00: the Mac was
asleep or cmds was not running"). Several missed times never cause several runs. A one-time schedule that ran or
was missed is turned off and kept.

## Seeing what happened

The window lists each schedule's trigger, action, next run and last result; the history below shows the runs of
the selected schedule (or of all schedules) with why each ended as it did. `cmds schedule history` prints the same.

- **Failed, skipped and missed runs** light the run's pane (or post a notification with **Open Schedules** when
  there is no pane), unless the schedule's **Notify** is Never.
- **Successful runs** with Notify **Always** set the workspace's sidebar text, without the attention ring.

Run Now runs a schedule at once (also one that is off); Cancel Run stops an active run (nothing more is typed).

## Where schedules are kept

`schedules.json` (definitions) and `schedule-runs.json` (history: at most 50 runs per schedule, 300 in all, 90 days)
in the support folder (`~/Library/Application Support/cmds`, readable by you only). Prompts and commands are stored
there in plain text; they are never logged and never sent to the iPhone. A damaged file is renamed to
`schedules.json.corrupt-<time>` and kept; a file written by a newer cmds is shown but not changed.

Going back to an older cmds: as long as your schedules only start workspaces and continue Claude Code sessions once,
cmds 0.6 keeps running them. Once one types into a pane, continues Codex, follows Codex's limit or repeats, the file
says so (`version` 2) and cmds 0.6 shows the schedules but runs and changes none of them. Pane tags live in
`session.json`; an older cmds drops them when it saves, and a schedule that targets a pane then skips its runs
(`the target pane was not found`) until you choose the pane again.
