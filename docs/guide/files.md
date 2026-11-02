# Files panes

> A folder on this Mac or on an SSH host as a list next to your terminals: browse, preview, copy and move between
> two panes (also to and from servers, through a transfer queue), rename, new folder, Move to Trash, follow a
> terminal's `cd`, and drop files on a terminal to type their paths.

A files pane is one more kind of pane, like a browser or preview pane: split it, zoom it, close it with ⌘W, and it
comes back after a relaunch. Two of them side by side give a two-pane file manager. A files pane can also list a
folder on an SSH host ([below](#folders-on-ssh-hosts)). Folder compare and sync, and editing remote files, are planned
for later phases of [#26](https://github.com/nntokyo/cmds/issues/26).

## Opening one

- **File › New Files Pane** (⇧⌘E) splits the focused pane to the right and lists its folder: a terminal's current
  directory, a files pane's folder (so pressing ⇧⌘E in a files pane gives the second pane), else the workspace's
  directory, else your home folder.
- `cmds files [PATH]` from a terminal lists `PATH` (default: the current directory); a file's folder opens with the
  file selected. `--pane` naming a files pane shows the folder in that pane instead; `--down` splits below,
  `--no-focus` keeps the keyboard where it is ([CLI reference](../reference/cli.md#commands)).

```sh
cmds files                    # this directory, to the right
cmds files --down ~/Downloads
cmds files home:/var/www      # a folder on the SSH host "home"
```

`cmds files` is not available from SSH panes (a script on the server cannot open panes on the Mac); press ⇧⌘E in the
SSH pane instead.

## The list

- Columns: **Name**, **Git** (only inside a Git repository), **Size**, **Date Modified** and **Kind**. Click a column
  header to sort by it, again to reverse. Folders stay above files.
- The bar above the list has **Back** / **Forward** (⌘[ / ⌘]), **Enclosing Folder** (⌘↑), the path (click a folder
  in it to go there), **Show Hidden Files** (⇧⌘.), **Follow Terminal** and **Open Terminal Here**. The line below the
  list counts the items and the selection, or shows a running copy.
- Type the first letters of a name to select it. ⇧⌘G (**Pane › Files › Go to Folder…**) takes a path: absolute,
  `~/…`, or relative to the shown folder.
- The list is read in the background and again whenever the folder changes on disk, so a pane never blocks while a
  large or slow folder loads.
- **Git column**: `M` modified, `A` added, `R` renamed, `D` deleted, `?` untracked, `U` conflict. A folder shows the
  most pressing state of what changed inside it. It comes from `git status` run in the background (without taking
  Git's index lock) and is left out for very large repositories that take more than a few seconds, or when Git is not
  installed. It is read again when the folder changes, when Git changes the repository (commit, `git add`, checkout,
  also from a terminal) and when the window becomes active again. Editing a tracked file inside a subfolder from the
  same window shows up at the next of those (or ⌘R).

## Opening and previewing files

- Return, ⌘↓ or a double-click opens a folder in the pane and files in their default app.
- Space shows the selected file in the workspace's preview pane (opening one to the right if there is none): images,
  PDF, Markdown, diffs and whatever Quick Look shows ([Preview panes](workspaces-and-panes.md#preview-panes)). The
  keyboard stays in the list, so you can walk through files with ↑/↓ and Space.
- The right-click menu also has **Open in Default App**, **Copy Path** and **Reveal in Finder**.

## Copying and moving

- **Between two files panes**: select items and press F5 to copy or F6 to move them to the other files pane of the
  workspace (or **Pane › Files › Copy to Other Pane / Move to Other Pane**, or the right-click menu). With more than
  two files panes, "the other" is the one you used last. Tab moves the keyboard to it.
- **Drag and drop**: drag rows onto the other pane's list, onto a folder in a list, or to and from the Finder. Like
  the Finder, items move within a volume and are copied to another volume; hold ⌥ to copy, ⌘ to move.
- **Pasteboard**: ⌘C puts the selected items on the pasteboard; ⌘V copies the pasteboard's files into the shown
  folder, ⌥⌘V moves them. This works with files copied in the Finder too.

Copies run in the background with their progress below the list and a **Cancel** button; cancelling removes the
partly copied item (never anything that was there before). Copies keep the files' dates, permissions and extended
attributes, and symbolic links are copied as links. A move within a volume is a rename. A move to another volume
copies the item and then puts the original in the Trash; if the original cannot go to the Trash, the copy stays
(and is selected) and the alert says so, with the original left where it was.

When a name is already taken in the destination, cmds asks:

- **Keep Both**: the new item gets a number, like the Finder (`photo.jpg` → `photo 2.jpg`).
- **Replace**: the existing item goes to the Trash first.
- **Skip**: leaves both as they are. **Stop** ends the copy there.
- **Apply to all** answers every further conflict of the same copy.

Copying an item into its own folder makes a numbered copy; a folder cannot be copied or moved into itself.

## Rename, new folder, Trash

- F2 (or **Rename** in the right-click menu) edits the name in place, with the name before the extension selected;
  Return keeps the new name, Escape the old one.
- F7 (**New Folder**) creates `untitled folder` and starts renaming it.
- ⌘⌫ (**Move to Trash**) moves the selected items to the Trash. Files panes never delete anything for good; use the
  Finder's **Put Back** to restore.

## Follow Terminal

With **Follow Terminal** on (the link button), the pane goes wherever the workspace's terminal goes: when you `cd` in
it, and when you switch to another terminal pane of the workspace. The terminal it follows is the local terminal pane
you used last. cmds learns a terminal's directory from the shell's OSC 7 reports, which Ghostty's shell integration
sends for zsh, bash and fish ([Workspaces and panes](workspaces-and-panes.md)). SSH panes are not followed (their
paths are on the server). The setting is saved with the session.

## Terminal integration

- **Open Terminal Here** (the terminal button in the bar, the right-click menu or **Pane › Files**) opens a terminal
  pane below, in the selected folder or else the shown one.
- Dropping files on a terminal pane types their paths, quoted for the shell (`My\ File\ \(1\).txt`), with spaces
  between them. This works for files dragged from a files pane, the Finder or anywhere else, and for file URLs pasted
  with ⌘V.

## Folders on SSH hosts

A files pane can list a folder on any host you reach with `ssh`, over SFTP. Nothing is installed on the server.

- **Opening**: File › New Remote Files Pane… (⌥⇧⌘E) asks for the host (the `Host` entries of `~/.ssh/config` are
  offered) and a folder (default: your home folder there). ⇧⌘E in an SSH pane opens its host at the pane's remote
  directory. From a terminal: `cmds files HOST:PATH`, with `PATH` absolute, `~/…`, relative to the remote home, or
  empty. As with `scp`, a colon before any `/` makes it remote; write `./a:b` for a local name with a colon.
- **Your ssh, never a password**: cmds runs your own `ssh`, so `~/.ssh/config`, keys, the agent, jump hosts and an
  open `ControlMaster` connection apply. It never asks for, types or stores a password, and never prompts: a host that
  wants a password, or a key whose passphrase is not in the agent, is refused with a note (add a key with
  `ssh-copy-id`, or the key to the agent with `ssh-add`). Host keys are always checked: a host whose key is not in
  `known_hosts` yet is refused (connect once in an SSH workspace or a terminal to check and accept it; cmds never adds
  host keys), and a changed key is refused with a warning.
- **The list**: like a local one, without the Git column and Follow Terminal. The bar shows `host:/path`. It is read in
  the background; ⌘R reads it again (the server's folder is not watched; the pane's own changes and finished
  transfers show up by themselves). Connection problems show in the list with **Connect** to try again.
- **Open and Space** download a copy of the file (read only, in cmds' cache) and open it in its default app or show it
  in the preview pane. Editing that copy does not change the server's file.
- **Rename** (F2), **New Folder** (F7) and **Copy Path** (`host:/path`) work as locally. **Open Terminal Here** opens
  an SSH pane at the folder.
- **Move to Trash** (⌘⌫) never deletes anything on the server: items go to your Trash there,
  `~/.local/share/Trash` (the freedesktop.org Trash that `gio trash`, `trash-cli` and Linux file managers use, so
  they can be restored there). An item on another file system than your home folder cannot be moved there; cmds then
  leaves it where it is and says so.
- A pane restored after a relaunch does not connect by itself; it shows **Connect** (⌘R).

Copying and moving between a remote pane and a local one, or two hosts, goes through the transfer queue.

## Transfers

Copies and moves that involve an SSH host (F5 / F6, drag and drop between panes, dropping files from the Finder on a
remote pane, ⌘C / ⌘V) are queued and run in the background:

- The pane that started a transfer shows its progress and **Cancel** below the list. **Window › Transfers** (⌥⌘T)
  lists every transfer with **Pause** / **Resume**, **Cancel**, **Retry** and **Show Log** (what happened to each
  item); **Clear Finished** removes the finished ones. `cmds transfers` shows the same.
- Two transfers run at a time; more wait their turn.
- Name conflicts ask as for local copies (Keep Both, Replace, Skip, Stop, Apply to all). Replace moves the existing
  item to the Trash of its side (this Mac's or the server's) first, and is refused if it cannot.
- A file is written under a temporary name (`.cmds-part-…`) and gets its real name only when it is complete, so a
  half-copied file never looks finished. **Cancel** removes that temporary file, and a folder the interrupted item had
  created goes to the Trash; nothing that was there before is touched. **Pause** holds the transfer at the next chunk.
- **Retry** runs the items that did not finish, and fills in folders the transfer had created (files already there with
  the same size are kept).
- A move within one host is a rename. Otherwise the items are copied and the originals then go to the Trash of their
  side; if that fails, the copy stays and the log says so.
- Dates and permissions are kept; symbolic links are copied as links.
- If the connection drops, the transfer fails and can be retried. Quitting cmds stops running transfers; a
  `.cmds-part-…` file they leave is removed the next time cmds starts (on this Mac) or connects to that host. cmds
  removes only the temporary files it recorded writing, nothing else.

Copies between two folders on this Mac do not use the queue (see [Copying and moving](#copying-and-moving)).

## iPhone and iPad

The companion lists files panes with a folder icon and shows the folder's path; browsing it from the phone comes in a
later phase. Older companion versions show a files pane as a browser pane with the folder's `file://` URL
([sync protocol](../internals/sync-protocol.md#files-panes)).

## Keys

All keys of the list: [shortcuts](../reference/shortcuts.md#files-panes).
