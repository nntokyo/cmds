# Schedules

> Start a workspace or continue a Claude Code session later: at a set time, on weekdays, or when an account's limit
> resets. What a schedule does, when it runs, what it never does, and where to see what happened.

Open **Window › Schedules…** (also Settings › Agents › Schedules) or use `cmds schedule`
([CLI reference](../reference/cli.md)). Schedules run only while cmds runs.

## What a schedule does

A schedule has a **trigger** and an **action**.

| Trigger | When it fires |
|---|---|
| Once | At a date and time (`cmds schedule add --at "2026-11-04 02:00"`, `--at 02:00`, `--in 90m`) |
| Weekly | On the chosen weekdays at one or more times of day, 5 minutes apart at least (`--every weekdays --time 09:00,13:30`). In a time zone you choose, or the Mac's (`--tz Asia/Tokyo`) |
| When an account's limit resets | Once, when one of your [Claude accounts](ai-agents.md#several-claude-accounts) is usable again, plus a delay (default 1 minute; `--after-limit work --delay 2m`). It follows the account: a later reset moves it; clearing the limit fires it at once |

| Action | What happens |
|---|---|
| Start a workspace | A new workspace opens in a folder, in the background: it is not selected and does not take the keyboard. Optionally under an account (or `auto`, the first account without a limit), with a title, a **command** typed at its shell prompt (e.g. `claude`), and a **first prompt** pasted into the Claude Code that command starts, once it is idle. A weekly schedule opens a new workspace each time |
| Continue a Claude Code session | A remembered Claude Code session gets a prompt (default `continue`). If Claude Code is running it in a pane, the prompt is pasted there once it is idle. If the pane is at its shell prompt, the session is resumed first (`claude --resume <id>`, under the account). If no pane holds it any more, it is resumed in a new background workspace in its folder |

Examples:

```sh
# Continue this pane's session when the "work" account's limit resets.
cmds schedule add --name "Continue after reset" --after-limit work --continue

# Weekdays at 09:00: open ~/src/app under the first free account, start Claude Code and give it a task.
cmds schedule add --name "Morning tests" --every weekdays --time 09:00 \
  --start ~/src/app --account auto --prompt "Run the test suite and summarise failures" -- claude

# Tonight at 02:00: run a benchmark in a new workspace.
cmds schedule add --name bench --at "2026-11-04 02:00" --start ~/src/app -- make bench
```

### When every account is limited

When Claude Code hits its limit and no other account is free, the bar in the pane offers **Continue at 15:01**
(and the notification **Continue When It Resets**): it adds a schedule that types `continue` into the session one
minute after the account's reset. The sidebar says when.

## Safety

A schedule types only where it may, and only once:

- **Never into a busy agent.** A prompt is pasted only when Claude Code is in the foreground, not working, not
  asking for input or permission (including its numbered choices such as the folder trust question), no subagent is
  running, its screen has not changed for 2 s, no account switch is in progress and no resume is queued. It waits for
  up to 30 minutes, then the run fails.
- **Shell input only at an empty prompt.** A command (or a resume) is typed only when the pane's shell is in the
  foreground with nothing typed after its prompt. A pane running any other program is left alone: the run is
  skipped.
- **Only its own panes.** A run types into the pane it created, or into the pane holding the targeted session id; if
  that pane now runs another session or another program, the run is skipped.
- **Once.** Nothing is retried. A failed run is reported; Run Now tries again when you choose.
- **Limits.** At most 50 schedules, one active run per schedule, five active runs at once and one per pane. A prompt
  is at most 8 KB (line breaks and tabs, no other control characters); a command is one line of at most 1 KB.
- **Local only.** `schedule.*` is refused on the sockets of SSH panes, so a server cannot create schedules.
- **Visible origin.** Schedules made with the CLI or the socket API (for example by an agent) are marked in the
  window, with the pane that made them. They run without asking, like `cmds send` would.

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
