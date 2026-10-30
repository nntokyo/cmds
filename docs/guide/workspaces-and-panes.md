# Workspaces and panes

> Everyday use of the Mac app: workspaces and the sidebar, splits, browser and preview panes, SSH workspaces,
> session restore, keeping the Mac awake and the app's language.

All key equivalents: [reference/shortcuts.md](../reference/shortcuts.md). Everything here can also be scripted with
the [`cmds` CLI](../reference/cli.md).

## Workspaces and the sidebar

A **workspace** is one vertical tab in the sidebar. It holds a tree of split panes and has a primary working
directory. **File › New Workspace** (⌘N) opens one with a terminal in your home directory; `cmds new [--cwd DIR]`
uses the current (or given) directory. Switch with ⌘1…⌘9, ⇧⌘] / ⇧⌘[ or ⌃Tab / ⌃⇧Tab; drag rows to reorder;
double-click (or ⇧⌘R, or the row's context menu) to rename.

Each row shows:

- the title, git branch, working directory and listening ports of the workspace's processes;
- CPU and memory of its processes (100 % CPU = one core, like Activity Monitor);
- the coding agent of its focused pane (model, context, cost, 5-hour limit; [ai-agents.md](ai-agents.md#usage-and-limits));
- the latest notification text and an attention dot.

The footer shows each agent's account limits (5-hour / 7-day windows, Claude's spend limit) and Mac-wide CPU and
memory meters (with memory pressure). ⌘B hides the sidebar; ⌃⌘S (or the button at the top) switches to a compact
52 pt rail with workspace numbers, the attention dot, a status colour and tiny meters.

## Splitting and focusing panes

- **Pane › Split Right** (⌘D) / **Split Down** (⇧⌘D) opens a terminal next to the focused pane, in that pane's
  directory. Drag the divider to resize.
- ⌥⌘ + arrow keys move the focus; **View › Zoom Pane** (⇧⌘↩) shows one pane alone until toggled back.
- ⌘W closes the focused pane, ⇧⌘W the workspace.

### The attention ring

A pane lights up with an orange ring when its program sends a desktop notification (OSC 9 / OSC 777), rings the bell,
or `cmds notify` targets it — unless it is the pane you are looking at. The sidebar row shows a dot and the
notification text; a macOS notification appears when cmds is in the background, and a paired iPhone gets one too.
Focusing the pane clears it; **Pane › Jump to Latest Attention** (⇧⌘U) goes to the most recent one. Setting this up
for coding agents: [ai-agents.md](ai-agents.md#attention-how-a-pane-lights-up).

## Browser panes

**File › Open Browser Split** (⇧⌘B) opens a WebKit browser to the right of the focused pane with the address bar
focused. ⌘L focuses the address bar, ⌘R reloads, ⌘[ / ⌘] go back / forward. From a terminal:

```sh
cmds browser open --no-focus http://localhost:3000   # prints the pane id
cmds browser eval 'document.title'                   # run JavaScript, print the JSON result
cmds browser snapshot -o /tmp/page.png               # PNG of the visible page
```

## Preview panes

A preview pane shows a local file next to your terminals and reloads it whenever the file changes (also on atomic
saves; a deleted file shows a placeholder until it is back).

- Images in an image view; PDF, video, Office documents and text/code via Quick Look.
- Markdown rendered GitHub style (light/dark, local images from the file's folder; scripts are disabled).
- Unified diffs (`.diff`, `.patch`, or `cmds open --diff`) coloured with line numbers.

Open one with **File › Open in Preview…** (⇧⌘O), by ⌘-clicking a file path printed in a terminal (`path:line[:col]`
works too; URLs, folders and missing files open in their default app instead), or with `cmds open`:

```sh
cmds open --no-focus out/report.md
git diff | cmds open --no-focus --diff -
```

The header shows the file name and folder (click to reveal in Finder), **Open in Default App** and **Reload** (⌘R).
Preview only reaches files on this Mac, so it is not available from SSH panes. Rendering details:
[internals/architecture.md](../internals/architecture.md#key-concepts).

## SSH workspaces

An SSH pane runs your own `ssh` (so `~/.ssh/config`, keys, agents, jump hosts and `ControlMaster` apply) and gives
programs on the server a restricted way back to cmds: notifications, sidebar status, Claude Code usage, the pane's
cwd and branch. Nothing is installed on the server unless you ask for it. How it works and what the server can and
cannot do: [internals/ssh.md](../internals/ssh.md).

### Opening one

- **File › New SSH Workspace…** (⇧⌘N): host (completes from the `Host` lines of `~/.ssh/config` and its
  `Include`s, read only; patterns are skipped), optional remote directory and title.
- `cmds new --ssh HOST [--remote-cwd DIR] [--title T]`, `cmds split [right|down] --ssh HOST [--remote-cwd DIR]`.
- Splitting an SSH pane (⌘D, ⇧⌘D, `cmds split` without `--cwd`/command) opens another connection to the same host in
  the pane's remote directory. Local terminals split from it (`--cwd`, a command) start in a local directory.

`HOST` is a host, `user@host`, a config alias or an `ssh://user@host:port` URI; it may not start with `-`. The remote
directory is absolute or `~/…`, without quotes, backslashes or control characters. The server needs nothing special
with default OpenSSH settings ([server requirements](../internals/ssh.md#server-requirements)).

### Disconnects and restore

- The sidebar row shows `ssh HOST` (`+N` for more hosts, orange "disconnected" while the shown pane is down);
  cwd/branch come from the focused SSH pane's reports. CPU/memory count local processes only: for an SSH pane that is
  the `ssh` client; ports are local listeners (e.g. `ssh -L`).
- When `ssh` exits the pane stays with its last screen under an overlay: **Disconnected — Reconnect (⌘R)** (also
  Return, the button, or `cmds reconnect [pane]`); Close Pane closes it.
- Session restore keeps SSH panes (host + last remote cwd). On launch they show **Not connected — Connect (⌘R)** and
  never connect by themselves.

### Remote helper

**Pane › Install Remote Helper…** (focused SSH pane, after a confirmation) types one line into the remote shell that
writes `~/.local/bin/cmds-remote.sh` and, if the server has no `cmds`, a `~/.local/bin/cmds` link to it. Then
`cmds notify`, `cmds status` and the Claude Code hooks work on the server unchanged
([ai-agents.md](ai-agents.md#agents-on-a-server-ssh-panes)). Make sure a shell prompt is showing first; it is never
done automatically. `cmds remote-helper` prints the script if you prefer to install it yourself.

### Remote cwd and branch

libghostty ignores OSC 7 whose host is not this Mac (Ghostty's own shell integration on the server sends the server's
hostname, so it does not reach cmds). Report the cwd as `localhost` instead; in an SSH pane the path is shown as a
remote path. Add to the server's `~/.bashrc` / `~/.zshrc`:

```sh
# bash
[ -n "$CMDS_PANE_ID" ] && PROMPT_COMMAND='printf "\033]7;file://localhost%s\007" "$PWD"; cmds-remote.sh prompt 2>/dev/null'"${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
# zsh
_cmds_location() { printf '\033]7;file://localhost%s\007' "$PWD"; cmds-remote.sh prompt 2>/dev/null; }
[ -n "$CMDS_PANE_ID" ] && precmd_functions+=(_cmds_location)
```

The `printf` alone gives the cwd (no process, no helper needed); `cmds-remote.sh prompt` adds the git branch (one
`git` + one socket call per prompt; drop it if that is too slow). Local git is never consulted for remote paths.

## Session restore

When cmds quits and starts again, it restores the workspaces, their split layout and titles, and per pane the
working directory, browser URL, previewed file or SSH host. Terminals start fresh shells in their directories
(screen contents and running programs are not restored); SSH panes wait for you to connect. Coding-agent sessions that
ran in a pane are offered for resuming: [ai-agents.md](ai-agents.md#resuming-sessions). To move workspaces to another
instance or Mac, use File › Export Workspaces… / Import Workspaces… ([ai-agents.md](ai-agents.md#moving-to-a-new-version)).

## Keeping the Mac awake

While cmds runs, the Mac does not go to sleep when idle (**cmds › Prevent Idle Sleep**, on by default, no password).
**cmds › Keep Display Awake** (off by default) keeps the screen on too. Both end when cmds quits.

Closing the lid still sleeps the Mac. To keep agents running with the lid closed, choose **cmds › Keep Awake With Lid
Closed…**: after a warning, macOS asks for your administrator password and cmds runs `pmset -a disablesleep 1`; it
runs `pmset -a disablesleep 0` when you turn it off or quit cmds. While it is on, the sidebar footer shows
"Awake (lid closed OK)"; on battery, cmds offers to turn it off.

> [!WARNING]
> If cmds crashes, sleep stays disabled until cmds starts again (it offers to restore it) or you run
> `sudo pmset -a disablesleep 0`. Don't put a closed Mac that never sleeps in a bag: it can overheat and drain the
> battery.

`cmds stats` shows the state on its `awake` line. Details: [internals/architecture.md](../internals/architecture.md#keeping-the-mac-awake).

## Language

The app follows the system language (English or Japanese; System Settings › General › Language & Region also has
per-app languages). **cmds › Language** switches between System, 日本語 and English and offers to relaunch. The `cmds`
CLI, the socket API and logs always stay English. More: [internals/localization.md](../internals/localization.md).
