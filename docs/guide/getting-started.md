# Getting started

> Install cmds, open your first workspace, learn the basic moves and the `cmds` command, and find where cmds keeps
> its data.

## Install

Download the notarized DMG from [cmds.n-n.tokyo](https://cmds.n-n.tokyo/) (Apple silicon Mac, macOS 14 or later), or
build from source as described in the [README](../../README.md#build-from-source).

1. Drag `cmds.app` to `/Applications` (or `~/Applications`) and open it from there. Keep it in one place:
   macOS ties the firewall and notification permissions to the app's path and signature.
2. If the macOS firewall is on, macOS asks whether cmds may accept incoming connections. Choose **Allow** if you want
   to use the iPhone companion; the terminal works either way.
3. Allow notifications when asked, so panes that need attention can notify you while cmds is in the background.
4. Updates (the downloaded release, 0.2.0 and later): cmds checks cmds.n-n.tokyo once a day, downloads a new version
   in the background and installs it when cmds quits; **cmds › Check for Updates…** installs it now. Turn either off in
   **cmds › Settings… › Updates**. Builds from source never update themselves.
5. Optional: **cmds › Install Command Line Tool…** links `/usr/local/bin/cmds` to the CLI inside the app (asks for an
   administrator password if needed), so `cmds` also works in other terminals. Terminals inside cmds have it already.

## Your first workspace

cmds opens with one workspace: a terminal in your home directory, listed as a vertical tab in the sidebar.

- **⌘N** new workspace, **⌘1…⌘9** switch, **⇧⌘R** rename (or double-click the tab).
- **⌘D** split right, **⇧⌘D** split down, **⌥⌘ + arrows** move between panes, **⇧⌘↩** zoom one pane, **⌘W** close it.
- **⇧⌘B** opens a browser next to the terminal; **⇧⌘O** shows a file (image, PDF, Markdown, diff, …) in a preview
  pane, and **⌘-click** on a file path in the terminal does the same.
- **⇧⌘N** opens an SSH workspace on a server from your `~/.ssh/config`.

When a program in a pane you are not looking at wants attention (an agent waiting for approval, a finished build that
rings the bell), the pane gets an orange ring and the sidebar shows its message; **⇧⌘U** jumps there. More:
[workspaces-and-panes.md](workspaces-and-panes.md); every shortcut: [reference/shortcuts.md](../reference/shortcuts.md).

## The `cmds` command

Every cmds terminal knows which pane it is (`CMDS_PANE_ID`), so `cmds` acts on the pane you run it in:

```sh
cmds ls                                   # workspaces and panes
cmds split down -- npm run dev            # run a dev server in a new pane below
cmds browser open http://localhost:3000   # open it in a browser pane
cmds open README.md                       # preview a file
make test; cmds notify "tests done: $?"   # light this pane's ring when done
cmds stats                                # CPU and memory per workspace and for the Mac
```

`cmds --help` and `cmds <command> --help` list everything; the full reference is [reference/cli.md](../reference/cli.md).

## Next steps

- Coding agents: set up Claude Code's hooks and status line, Codex notifications and the Claude skill:
  [ai-agents.md](ai-agents.md).
- iPhone/iPad: pair the companion with **cmds › Pair iPhone/iPad…**: [iphone.md](iphone.md).
- Long agent runs: cmds keeps the Mac from idle sleep while it runs; for a closed lid see
  [Keeping the Mac awake](workspaces-and-panes.md#keeping-the-mac-awake).

## Where cmds keeps its data

| What | Where |
|---|---|
| Workspaces and layout (`session.json`), paired devices (`sync-devices.json`, token hashes only), remote-access settings (`sync-remote.json`), the API socket (`cmds.sock`), per-pane SSH sockets (`ssh/`) | `~/Library/Application Support/cmds/` |
| The Mac's sync identity (private key and certificate) | Login keychain, label `cmds sync identity` |
| Preferences (language, keep-awake, sidebar, resume mode) | `defaults read tokyo.n-n.cmds` |
| Command line tool link | `/usr/local/bin/cmds` (only if installed from the menu) |

To remove cmds, quit it, delete the app and the items above.
