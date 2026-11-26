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

## On battery

A closed lid on battery stops every agent in the middle of its turn. cmds can tell them first:

```sh
cmds power                               # the power source, the charge, whether the notice is on
cmds power notice on                     # tell the agents (off by default)
cmds power notice --below 30             # the level in percent (default 25; 5 to 95)
cmds power notice --request "Stop at a good point and write your next step in NEXT.md."
cmds power notice off
```

When it is on, cmds keeps one line for every pane that runs Claude Code or Codex, exactly as `cmds queue add` would
(typed in when the agent is free, never into a question or over text you typed), at two moments:

- the Mac switches from the power adapter to its battery: 「この Mac の電源が電池に切り替わりました（残り 59%）。区切りをつけ、
  途中の反映を残さず、次の一手を 1 行で記録してください。」 (the Mac switched to battery power, 59% left; wrap up at a good
  stopping point, leave nothing half-applied, record your next step in one line);
- on battery, the charge falls below the level: 「この Mac の電池の残りが 25% を下回りました（残り 24%、充電されていません）。…」
  (also when the adapter is unplugged below the level, in place of the first line, and when the notice is turned on
  or cmds starts in that state).

The line is in Japanese whatever the Mac's language; `--request` replaces the sentence after the reason (one line),
`--default-request` puts the usual one back. Each moment is told once: the switch again only after the Mac was on the adapter in between, the level again only after
it was on the adapter or 5 points above the level, and a pane that has not read cmds's last line gets no second one.
Panes without an agent get nothing. The lines show in `cmds queue list` and can be cancelled there; `cmds power`
shows the last one sent. The setting is kept in `power-notice.json` in cmds's support folder. A Mac without a
battery never sends anything.

## Stalled panes

An agent that asks for permission waits until someone answers, and an instruction kept for a pane waits as long as
its input box holds text. cmds can tell one pane (the one that hands out the work) when that lasts
(the steps on one page, in Japanese: [stall-notice.ja.md](stall-notice.ja.md)):

```sh
cmds stall                                   # the panes that are stuck now, and whether the notice is on
cmds stall notice on --to p3                 # tell pane p3 (off by default; --to is needed the first time)
cmds stall notice --input-minutes 5 --queue-minutes 20
cmds stall notice --idle-minutes 30          # an agent with nothing to do (default 10; 0: not told)
cmds stall notice --idle-repeat on           # tell about an idle agent every hour, not once
cmds stall notice off
```

When it is on, cmds looks at the panes once a minute and keeps one line for the pane given with `--to`, exactly as
`cmds queue add` would (typed in when its agent is free), for:

- an agent that has asked for input or permission for `--input-minutes` (default 10):
  「cmds 詰まり通知: ペイン p7 / 入力待ち / 12 分 / 理由 permission-or-question」;
- an instruction kept for a pane that has not been typed in for `--queue-minutes` (default 15):
  「cmds 詰まり通知: ペイン p9 / 預けた指示が未達 / 15 分 / 理由 typed-input」;
- an agent that finished its work and has waited at its prompt, with nothing in progress and nothing asked, for
  `--idle-minutes` (default 10; 0 turns only this kind off):
  「cmds 詰まり通知: ペイン p5 / 待機中 / 10 分 / 理由 idle」. So whoever hands out the work need not look at every
  pane to find the ones with nothing to do.

The line always has this form: the pane, the state, the minutes and one of a fixed set of reasons
(`permission-or-question`; `idle`; for a kept instruction `busy`, `needs-input`, `typed-input`, `no-agent`, `other-program`,
`other-input`, `pane-closed`, the reasons `cmds queue list` gives). Nothing from the pane's screen is in it. cmds
never answers the question, never types into the stuck pane and never brings a window forward: the pane that is told
decides what to do. A question or an instruction that stays stuck is told again every hour; an idle agent is told once each
time it becomes idle (a night with every agent idle is one line per agent), every hour only with `--idle-repeat on`.
A pane with both kinds for the same question gets
one line (so does an idle agent whose kept instruction is not typed in: that instruction is told), and the pane that is told is never reported itself. The minutes of a question and of an idle agent count from when the agent
last worked (for an agent cmds never saw working: from when it started, at the earliest when cmds did); a pane
without an agent is never idle. A dialog an agent shows without reporting it (the folder trust question at its start) is only seen
through an instruction kept for its pane. `cmds stall` lists the stalls also while the notice is off.

The line for the pane that is told waits, like any kept instruction, while its agent works. So, while the notice is
on, every check also writes the stalls to `stalls.txt` in cmds's support folder (`cmds stall` prints the path): a
first line `cmds stall <time, ISO 8601> <number of stalls>`, then one line per stall in the same fixed form. It is
written again every minute, also when there is no stall (the time shows it is fresh), and removed when the notice is
turned off. Anything may read it without asking cmds: a person, a status line, an agent's hook.
 The setting is
kept in `stall-notice.json` in cmds's support folder; the pane is remembered by its tag, so it is found after a
restart.

While a line still waits for the pane that is told (its agent works), the same stall gets no second line, and at most
10 lines wait there, so its queue keeps room for instructions; the others follow as lines are typed in. A line still
waiting when its stall is over is taken back. Turning the notice on or off, or telling another pane, takes back the
lines that wait and starts over: every stall there is then is told to the pane chosen now. So does a restart of cmds.

## Panes with nothing in progress

```sh
cmds idle                 # nothing in progress for 30 minutes or longer
cmds idle --minutes 10
```

```
p3  sales  claude  idle 45m00s (since 2026-11-25 15:15)
p7  legal  codex  asks for input ≥2h05m (since 2026-11-25 13:55) · 2 kept instructions waiting
```

A pane is listed when its agent waits for a prompt (`idle`; Claude Code's own "waiting for your input" notice a
minute after a turn is that, not a question) or asks for input or permission (`asks for input`), no
subagent runs, nothing is being typed into it by a schedule or a kept instruction, and that has been so for the given
minutes (default 30; 1 to 10080). Longest first. `≥`: cmds has not seen this agent work since it started watching the
pane (since cmds started, or the agent did), so it may have been idle for longer. A pane with kept instructions
waiting is listed too: something holds them (`cmds queue list`). Panes without an agent are not listed. Read only.

What it cannot see: a background command the agent started and is waiting for, or a timer inside the agent's session.
A [schedule](schedules.md) that will type into the pane later does not count as work in progress either.

API: `queue.add`, `queue.list`, `queue.cancel`, `agent.idle` ([reference](../reference/api.md)); local socket only.
