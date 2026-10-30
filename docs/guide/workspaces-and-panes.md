# Workspaces and panes

> Everyday use of the Mac app: workspaces and the sidebar, splits, the tiled view, browser and preview panes, SSH workspaces,
> session restore, keeping the Mac awake, settings (text size) and the app's language.

All key equivalents: [reference/shortcuts.md](../reference/shortcuts.md). Everything here can also be scripted with
the [`cmds` CLI](../reference/cli.md).

## Workspaces and the sidebar

A **workspace** is one vertical tab in the sidebar. It holds a tree of split panes and has a primary working
directory. **File › New Workspace** (⌘N) opens one with a terminal in your home directory; `cmds new [--cwd DIR]`
uses the current (or given) directory. Switch with ⌘1…⌘9, ⇧⌘] / ⇧⌘[ or ⌃Tab / ⌃⇧Tab; drag rows up or down to
reorder (also in the compact rail; ⌘1…⌘9 follow the new order); double-click (or ⇧⌘R, or the row's context menu) to
rename.

Each row shows:

- the title with a state dot (or a small spinner while an agent works) and the ⌘N hint; hovering shows a × that
  closes the workspace (it asks first while an agent is running there);
- the [agent state](#agent-state) and the agent's task — Claude Code's terminal title without its spinner glyph, e.g.
  `Working  自走型売上基盤の対応` — or else the working directory. Long paths keep their last components
  (`…/NN/自社/jav-a`); the full directory is in the tooltip;
- the git branch and listening ports of the workspace's processes;
- the coding agent of its focused pane: model, context and cost of that session
  ([ai-agents.md](ai-agents.md#usage-and-limits)); the account limits are the same for every row and live in the footer;
- optionally (View › Show CPU and Memory per Workspace, off by default) CPU and memory of its processes (100 % CPU =
  one core, like Activity Monitor); never shown for SSH workspaces, whose processes run on the server;
- the latest notification text.

The footer shows each agent's account limits (Claude's 5-hour / 7-day windows and spend limit, Codex's windows, as
far as they are known) and Mac-wide CPU and memory meters (with memory pressure). ⌘B hides the sidebar; ⌃⌘S (or the
button at the top) switches to a compact 52 pt rail with workspace numbers, state dots in the same colours (working
pulses), a status colour and tiny meters. The sidebar width and the compact state are kept across launches.

With many workspaces:

- **View › Filter Workspaces** (⌥⌘F, or ⌘F while the sidebar has the keyboard) shows a filter field above the rows. It
  matches titles, tasks, directories, branches, notification text and state names; Return goes to the first match,
  Esc closes the filter and shows all rows again.
- **View › Group Workspaces by Project** (also in the sidebar's context menu) puts rows under a header per project:
  the git repository (a linked worktree counts as its main repository), else the directory; SSH workspaces by host and
  directory. Rows cannot be reordered while filtered or grouped (dragging one says so at the bottom of the sidebar);
  they can still be dragged onto the content area to [tile](#tiled-view) them.
- The Dock icon shows the number of panes with unseen attention.

The row's context menu also has **Clear Notification** (drops the text and the attention of all its panes).

### Agent state

Rows of workspaces where a coding agent runs show its state:

| State | Shown | Means |
| --- | --- | --- |
| **Working** (作業中) | blue text, spinner (pulsing dot in the rail) | the agent is busy |
| **Needs Input** (入力待ち) | orange | Claude Code asked for permission or input (`Notification` hook) |
| **Done** (完了) / **Idle** (待機) | green / grey | the turn ended (`Stop`); Done until you have seen the pane |
| **Stopped** (停止) | grey | the agent that ran here exited |

The state comes from, newest first: the [Claude Code hooks](ai-agents.md#notifications-hooks) (`Notification`, `Stop`,
`UserPromptSubmit`, optionally `PreToolUse`/`PostToolUse`/`SessionEnd`), the spinner glyph agents put in front of the
terminal title (Claude Code: `✳ task` when idle, an animated glyph while working), and status-line reports whose
figures (cost, tokens, context) moved. Working without any new sign for 10 minutes (90 seconds when only status-line
reports said so) falls back to Idle, since an interrupted turn sends no `Stop`. A workspace shows its most pressing
pane: Needs Input, then Working, Idle, Stopped. Plain shells get no state.

## Splitting and focusing panes

- **Pane › Split Right** (⌘D) / **Split Down** (⇧⌘D) opens a terminal next to the focused pane, in that pane's
  directory. Drag the divider to resize.
- ⌥⌘ + arrow keys move the focus; **View › Zoom Pane** (⇧⌘↩) shows one pane alone until toggled back.
- ⌘W closes the focused pane, ⇧⌘W the workspace.

## Tiled view

Shows several workspaces side by side, each as a live tile you can type in — e.g. five Claude Code sessions at once.

- **Select several workspaces in the sidebar**: ⌘-click adds or removes one, ⇧-click a range. The content area
  tiles them right away; selecting a single workspace again goes back to the normal view.
- **View › Tile All Workspaces** (⌃⌘T) tiles every workspace the sidebar shows (a filter applies; new workspaces
  join), and ⌃⌘T again shows one workspace. **View › Tile Selected Workspaces** brings back the last ⌘-click
  selection; **View › Show Single Workspace** (or Esc while the sidebar has the keyboard) leaves the tiled view.
- Layout follows the count and the window shape: 2 side by side (stacked in a tall window), 3 in a row when the
  window is wide, else 2 + 1, 4 as 2 × 2, 5 as 3 + 2, 6 as 3 × 2, up to 9 in three rows. More than 9 are not shown
  (a note says how many; the workspace you select always gets a tile). Drag the gaps between tiles to resize, double-click a gap to even it out; positions are
  remembered per set of workspaces and kept in the session.
- **Drag a sidebar row onto the content area** to tile it, like window snapping: a translucent area shows where it
  goes. Near the left or right edge of a tile (or of the single workspace shown) it goes beside that tile in its row;
  near the top or bottom edge it gets a row of its own above or below that row (spanning the width); in the middle it
  takes that tile's place (the tile leaves the tiled view; over the single workspace it simply shows the dragged
  one). Dragging onto the single workspace makes a 2-tile view.
- **Drag a tile's header** the same way to move it, or onto the middle of another tile to swap the two. Drop a
  header on the sidebar (or drag it out of the window with ⌥ held) to take that workspace out of the tiled view; with
  one left, the normal view returns. **View › Move Tile Left / Right / Up / Down** (⌃⇧⌘ + arrow) moves the active
  tile from the keyboard: left/right swap it with its neighbour, up/down move it into the row above or below (or into
  a row of its own from the top or bottom row).
- After a drag or a move the grid keeps your rows instead of the automatic layout, also when you ⌘-click
  workspaces in or out (new ones join the last row). It is saved in the session; ⌃⌘T, `cmds tile <ws>…` or leaving
  the tiled view go back to the automatic layout.
- Each tile keeps its own splits and has a header: state dot, title, agent state (Working, Needs Input, Done…) and
  the agent's task. A tile that needs you gets the orange ring.
- The tile with the keyboard has a blue header and is the selected workspace (window title, ⌘W, ⌘D… act on it).
  Click into a tile, its header or its sidebar row to switch; ⌥⌘ + arrow keys move across tiles too.
- **⇧⌘↩** (View › Zoom Tile), the header's button or a double-click on the header shows the active tile alone, and
  back.
- Terminals keep running: tiling moves the existing views, nothing restarts. Scripts can do the same with
  [`cmds tile`](../reference/cli.md).

### The attention ring

A pane lights up with an orange ring when its program sends a desktop notification (OSC 9 / OSC 777), rings the bell,
or `cmds notify` targets it — unless it is the pane you are looking at. The sidebar row shows a dot and the
notification text; a macOS notification appears when cmds is in the background, and a connected iPhone gets one too.
Focusing the pane clears the ring; typing in the pane, or its agent working again (see [Agent state](#agent-state)),
also clears the notification text. **Pane › Jump to Latest Attention** (⇧⌘U) goes to the most recent one. Setting this up
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
- When `ssh` exits the pane stays with its last screen under an overlay "Disconnected — ssh HOST" with
  **Reconnect (⌘R)** (also Return or `cmds reconnect [pane]`) and **Close Pane**. Reconnecting runs the same command
  with a new remote socket path.
- Session restore keeps SSH panes (host + last remote cwd). On launch they show "Not connected — ssh HOST" with
  **Connect (⌘R)** and never connect by themselves.

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

## Settings

**cmds › Settings…** (⌘,) applies every change at once to all open panes and remembers it:

- **Terminal font and size**: a font family (installed monospaced fonts) and a custom size in points. Both are
  layered over your Ghostty config (`~/.config/ghostty/config`): left at **Ghostty Default** / unchecked, the config
  (or Ghostty's default) decides. Changing them also re-reads that config.
- **Bigger / Smaller / Actual Size** (View menu, ⌘+ / ⌘− / ⌘0) change only the focused pane: a terminal's font size
  (Ghostty's own font-size keys), a browser or preview pane's page zoom. A terminal zoomed this way keeps its size
  when you change the setting; ⌘0 returns it to the Settings size.
- **Sidebar text size**: Small, Medium (default) or Large. Rows, footer and the compact rail scale together.
- **Browser page zoom** and **Preview zoom**: the starting zoom of browser panes and of rendered previews
  (Markdown, diffs, text).

Isolated test instances (`CMDS_SUPPORT_DIR`) keep their own settings
([internals/testing.md](../internals/testing.md#isolated-instances)). The iPhone companion has its own text size
setting ([iphone.md](iphone.md#what-the-companion-shows)).

## Language

The app follows the system language (English or Japanese; System Settings › General › Language & Region also has
per-app languages). **cmds › Language** switches between System, 日本語 and English and offers to relaunch. The `cmds`
CLI, the socket API and logs always stay English. More: [internals/localization.md](../internals/localization.md).
