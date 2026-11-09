# Workspaces and panes

> Everyday use of the Mac app: workspaces and the sidebar, splits, the tiled view, browser and preview panes, SSH workspaces,
> worktree workspaces, session restore, keeping the Mac awake, settings (text size) and the app's language.

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
  (`…/projects/my-app`); the full directory is in the tooltip;
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
- **Subagents**: under its terminal a tile shows one card per Claude Code subagent (Task / Agent tool) of its panes:
  type and description, current action (`Read Sources/main.swift`, `Bash: swift test`), elapsed time, tokens and a spinner.
  A finished one is dimmed with a check mark and fades out after 20 seconds. The sidebar row shows **Sub 3** while
  three run. Settings › Agents › **Show subagents** (also View › Show Subagents): *Off*, *In Tiled View Only*
  (default) or *Everywhere* (also a strip under the single workspace). Needs the subagent hooks
  ([ai-agents.md](ai-agents.md#subagents)).
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

### Responsive view

**Responsive View** in the device menu (the button at the right end of the browser toolbar) shows the page at
phone, tablet and desktop size side by side in one pane (iPhone 16, iPad Air, 1440×900), each frame at its own
width and user agent, all scaled by the same factor to fit the pane:

```sh
cmds browser responsive http://localhost:3000               # opens it in a new browser split
cmds browser responsive --devices iphone-se,pixel,ipad,desktop-1920   # 2–4 sizes, left to right
cmds browser responsive --no-sync-scroll                    # keep scrolling per frame
cmds browser responsive --off                               # show the page once again
```

- **Navigation** follows you: following a link, submitting, going back or typing an address in any frame loads the
  new address in the others. A frame that cmds sent to an address ignores its own address changes until a second
  after that page loaded, so a site that redirects phones elsewhere (`m.` sites) does not bounce the frames around.
- **Scrolling** (Sync Scrolling, on by default) moves the other frames to the same *proportion* of their page: half
  way down the phone page is half way down the desktop page, as the same content is taller at narrower widths.
  The position is the share of the scrollable height (`scrollY / (scrollHeight − innerHeight)`), so sections line
  up only roughly where layouts differ a lot.
- **Reload** (⌘R) reloads every frame; a `file://` page reloads by itself when the file is saved.
- The address bar, `cmds browser eval` / `url` / `navigate` and the iPhone use the first frame. `cmds browser
  snapshot` (and the MCP `browser_snapshot`) returns one image per frame (`-o shot.png` writes `shot-<device>.png`).
- Each frame is its own WebKit process (memory): at most four, freed when you turn the view off or close the pane.
  The view and its sizes are kept across relaunches and in exported workspaces; the pane's own device size and user
  agent apply again when the view is off. Older cmds versions show the page once.

### Screenshots

`cmds browser snapshot` captures what the pane shows; it can also capture more without scrolling or resizing the
pane:

```sh
cmds browser snapshot --full -o /tmp/page.png                  # the whole page as one image
cmds browser snapshot --selector '#pricing' -o /tmp/pricing.png  # one element
cmds browser snapshot --full --device iphone,ipad,desktop-1440 -o /tmp/shot.png
# → /tmp/shot-iphone.png, /tmp/shot-ipad.png, /tmp/shot-desktop-1440.png
```

- A full page may be up to 16384 CSS pixels tall; a taller one is refused (capture an element instead). Images are
  at 2× (1× above 4096 CSS pixels tall).
- `--device` takes the presets of [Device sizes](#device-sizes-and-color-scheme) or `WIDTHxHEIGHT`, up to four. Each
  size loads the pane's URL again in a web view outside the screen, one after another: the same cookies and storage,
  but not what you did on the page (form input, opened menus, client-side state). The pane's own device size and
  color scheme apply to the pane only; the other sizes use their preset's user agent and the pane's color scheme.
- Full-page and element captures come from WebKit's PDF of the page: fixed headers appear once, at the top, and
  a page that sets no background of its own comes out on white.
- Agents get the same through the MCP tool `browser_snapshot` (`fullPage`, `selector`, `device`, `devices`).

cmds can be chosen as the default web browser (**System Settings › Desktop & Dock › Default web browser**): links
opened from other apps then open in a browser split beside the focused pane. Passkeys and security keys don't work in
browser panes yet; they need an entitlement from Apple ([#162](https://github.com/nntokyo/cmds/issues/162)).

### Device sizes and color scheme

To check a responsive layout, click the device button at the right end of the browser toolbar:

- **Fill Pane** (default): the page is as wide as the pane.
- **Phones / Tablets / Desktops**: iPhone SE (375×667), iPhone 16 (393×852), iPhone 16 Pro Max (440×956), Pixel 7
  (412×915), iPad Air portrait (820×1180) and landscape (1180×820), 1280×800, 1440×900, 1920×1080. **Custom Size…**
  takes any width and height from 100 to 4096; **Rotate** swaps them. The page gets exactly that size in CSS pixels
  (`innerWidth`, media queries) and is scaled down to fit the pane when the pane is smaller. Phone and tablet sizes
  also send that device's user agent (iPhone Safari, Android Chrome; iPadOS Safari presents itself as Mac Safari).
- **Color Scheme**: Follow the Mac (default), Light or Dark, as `prefers-color-scheme` for the page.
- **User Agent**: WebKit's own, one of the device ones, or a custom string. Changing it reloads the page so the server
  sees it too.

The button is tinted while anything differs from the default. Next to it the toolbar shows the page's CSS width, the
media-query breakpoint range it is in (`768–1023`, `<640`, `≥1280`; the width thresholds come from the page's
readable style sheets, `min-width` / `max-width` and `width >= …` ranges), and the scale when the page is scaled down.
Hover over it for the list of breakpoints. View › Bigger / Smaller apply once the page fills the pane again. The
setting is kept per pane across relaunches and in exported workspaces.

From a terminal or an agent:

```sh
cmds browser device iphone-se            # preset (see cmds browser device --list)
cmds browser device 1024x768 --rotate    # custom size, rotated
cmds browser device --scheme dark        # only the color scheme
cmds browser device off                  # fill the pane again
```

What WebKit on the Mac does **not** emulate: the device pixel ratio (`devicePixelRatio` stays the Mac's), touch
events, `pointer: coarse` / `hover: none`, `<meta name="viewport">` scaling (the page is laid out at the device width
whatever its viewport tag says) and `prefers-reduced-motion` (WKWebView has no public setting for it). This is a layout-width, user-agent and color-scheme check; check real mobile behaviour on a device.

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

## Files panes

A files pane lists a local folder (name, size, date modified, kind, Git state) with back/forward, the path, hidden
files and type-to-select. Two of them side by side copy and move between each other (F5/F6, drag and drop) with
progress and a choice for names that are taken; rename, new folder and Move to Trash are there too, and a pane can
follow a terminal's `cd`. Open one with **File › New Files Pane** (⇧⌘E) or `cmds files [PATH]`. Everything about them:
[files.md](files.md).

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

## Worktree workspaces

Agents working side by side in one checkout get in each other's way. A worktree workspace gives each its own branch
and folder (a [git worktree](https://git-scm.com/docs/git-worktree)) that shares the repository's history.

### Creating one

- **File › New Worktree Workspace…** (⌥⌘N), or **New Worktree Workspace…** in a workspace's sidebar menu: the
  repository (prefilled with the selected workspace's), the new branch, optionally the base, the location and a command
  to start (e.g. `claude`).
- `cmds new --worktree BRANCH [--base REF] [--path DIR] [--cwd DIR] [-- cmd…]`, e.g.
  `cmds new --worktree fix-login -- claude`.

cmds runs `git fetch` (a failure, e.g. offline, is only a warning: the branch then starts from what was fetched
before), then `git worktree add --no-track -b BRANCH PATH BASE`, and opens the workspace in the new folder.

- **Base**: default is the repository's default branch, the remote's when there is one (`origin/HEAD`, e.g.
  `origin/main`; else `main` or `master`). A name you give is taken as the remote's branch when it has one, else as a
  local branch, tag or commit. The new branch has no upstream, so a plain `git push` never goes to the base; push it
  with `git push -u origin BRANCH`.
- **Location**: default `<repo>-worktrees/<branch>` next to the repository (`~/src/app` → `~/src/app-worktrees/fix-login`;
  `/` in the branch becomes `-`). It is outside the repository's working tree, so its build tools, searches, file
  watchers and `git status` never see the other worktrees, and on the same volume. A location inside the repository is
  refused.
- An existing branch name (local, or on the remote after the fetch) and an existing folder are errors; nothing is
  created then.

cmds remembers the worktrees it created in `worktrees.json` in its support folder; only those are ever offered for
removal. `cmds ls --json` shows them as `worktree` of their workspace. Session restore keeps the workspace in its
worktree.

### Show Changes

**Show Changes** in a workspace's sidebar menu (any local git repository; `cmds changes [ws]`) opens a diff preview of
what the branch did since it left its base: the commits, then one diff from the merge base to the working tree
(commits, staged and unstaged changes together, untracked files included). The base is the worktree's for one cmds
created, else the repository's default branch. Nothing is fetched. Choosing it again refreshes the same preview.

### Removing the worktree

Closing a workspace whose worktree cmds created (×, its sidebar menu, ⇧⌘W) asks: **Close Workspace** keeps the
worktree, **Close and Remove Worktree** also removes it with `git worktree remove` (never `rm -rf`, never `--force`).
Removing is refused, and the workspace stays open, while the worktree has

- uncommitted changes (also staged ones) or untracked files,
- commits that are on no remote branch and not on its base (push them, or merge them into the base),
- or a `git worktree lock`.

Files git ignores (build output, `node_modules`, `.env` files listed in `.gitignore`) go with the folder; the branch
stays (delete it with `git branch -d` once merged). Worktrees created with `git worktree add` or another tool, and a
worktree another open workspace is in, are never offered. `cmds close [ws] --remove-worktree` does the same from a
script.

## Session restore

When cmds quits and starts again, it restores the workspaces, their split layout and titles, and per pane the
working directory, browser URL (with its device size and color scheme), previewed file, files pane folder (with its hidden-files and Follow Terminal
settings) or SSH host. Terminals start fresh shells in their directories
(screen contents and running programs are not restored); SSH panes wait for you to connect. Coding-agent sessions that
ran in a pane are offered for resuming: [ai-agents.md](ai-agents.md#resuming-sessions). To move workspaces to another
instance or Mac, use File › Export Workspaces… / Import Workspaces… ([ai-agents.md](ai-agents.md#moving-to-a-new-version)).

## Menu bar

While you work in other apps, the cmds icon in the menu bar shows at a glance what needs you, without text:

- **Orange badge** with a number: workspaces that need you (orange in the sidebar: an agent asks for input or
  permission, or a notification you have not seen).
- **Blue badge** (your accent colour) with a number, circled by a turning arc: workspaces with an agent working.
- **Red dot** on the icon: an account limit is at 95 % or more, or memory pressure is critical (the tooltip says
  which).
- Only the icon: nothing waits or works.

Its menu starts with ring charts: CPU and memory (coloured by memory pressure), then per agent the Claude Code /
Codex account limits (5-hour, 7-day, …) with the time to their reset (`in 2h10m`, or the day and time when it is more
than a day away) — green, orange from 80 %, red from 95 %. Below them it lists every workspace where an agent ran,
with a mark for its state (orange "!" needs you, turning arc working, green check done, grey dot idle) and, in small
type, the agent and what it is doing or asking — for those that need you, since when (`3 min ago`). Those that need
you come first; choosing one (or ⌘1…⌘9 while the menu is open) brings cmds forward on it, at the pane that waits.
**Menu Bar Settings…** at the bottom opens Settings.

Settings › **Menu Bar** (also **Menu Bar Settings…** in the menu) lets you keep only what you want to see. **Show in
menu bar** turns the item off. For the icon: **Number of agents working** (the blue badge), **Red dot when a limit or
memory runs short**, **Animate while agents work** (off keeps the arc still, as does System Settings › Accessibility ›
Display › Reduce motion). For the menu: **CPU and memory**, **AI limits (Claude Code, Codex)**, **Workspaces with
agents**. All are on by default; the orange badge always shows. Isolated test instances (`CMDS_SUPPORT_DIR`) leave the
item off unless their own setting turns it on.

### Widget

The same at a glance on the desktop or in Notification Center: right-click the desktop › **Edit Widgets…** and add
**cmds** (small or medium).

- **Small**: the badges (orange needs you, blue working, red dot), the workspace that needs you (and since when, else
  the one working), and the most used account limit.
- **Medium**: up to four workspaces with their state mark and what the agent does or asks, and three rings (account
  limits first, then CPU and memory) with the time to their reset.

Clicking the widget, or a workspace in it, brings cmds forward on that workspace. The widget shows what cmds wrote last
(`~/Library/Application Support/cmds/widget.json`, refreshed within seconds of a change and at least every minute);
when that is older than five minutes it says "cmds isn't running". Isolated test instances (`CMDS_SUPPORT_DIR`) write
their own file and never change your widget.

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

**cmds › Settings…** (⌘,) has five tabs — General, Sidebar, Agents, Menu Bar, Updates — and applies every change at
once to all open panes and remembers it:

- **Terminal font and size**: a font family (installed monospaced fonts) and a custom size in points. Both are
  layered over your Ghostty config (`~/.config/ghostty/config`): left at **Ghostty Default** / unchecked, the config
  (or Ghostty's default) decides. Changing them also re-reads that config.
- **Bigger / Smaller / Actual Size** (View menu, ⌘+ / ⌘− / ⌘0) change only the focused pane: a terminal's font size
  (Ghostty's own font-size keys), a browser or preview pane's page zoom. A terminal zoomed this way keeps its size
  when you change the setting; ⌘0 returns it to the Settings size.
- **Sidebar text size**: Small, Medium (default) or Large. Rows, footer and the compact rail scale together.
- **Show in each workspace** (Sidebar): Git branch, directory, listening ports, the agent's model, context and cost,
  the latest notification — turn off what you don't need for shorter rows. The workspace name, the agent's state and
  its task always show. **Footer**: AI limits (Claude Code, Codex), CPU and memory. All on by default.
- **Browser page zoom** and **Preview zoom**: the starting zoom of browser panes and of rendered previews
  (Markdown, diffs, text).
- **Show subagents** (Agents): where Claude Code subagent cards appear — Off, In Tiled View Only (default),
  Everywhere ([Tiled view](#tiled-view)).
- **Menu Bar**: show the item, and what its icon and menu show ([Menu bar](#menu-bar)). All on by default.

Isolated test instances (`CMDS_SUPPORT_DIR`) keep their own settings
([internals/testing.md](../internals/testing.md#isolated-instances)). The iPhone companion has its own text size
setting ([iphone.md](iphone.md#what-the-companion-shows)).

## Language

The app follows the system language (English or Japanese; System Settings › General › Language & Region also has
per-app languages). **cmds › Language** switches between System, 日本語 and English and offers to relaunch. The `cmds`
CLI, the socket API and logs always stay English. More: [internals/localization.md](../internals/localization.md).
