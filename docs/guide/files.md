# Files panes

> A folder on this Mac or on an SSH host as a list next to your terminals: browse, preview, copy and move between
> two panes (also to and from servers, through a transfer queue), compare and sync two folders, edit a server's files,
> rename, new folder, Move to Trash, follow a terminal's `cd`, and drop files on a terminal to type their paths.

A files pane is one more kind of pane, like a browser or preview pane: split it, zoom it, close it with ⌘W, and it
comes back after a relaunch. Two of them side by side give a two-pane file manager. A files pane can also list a
folder on an SSH host ([below](#folders-on-ssh-hosts)), and two of them can be compared and synced
([below](#comparing-and-syncing-folders)).

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
  two files panes, "the other" is the one you used last; right after cmds restarts, until you use one, it is the first
  other files pane in the workspace. Tab moves the keyboard to it.
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
  in the preview pane. Editing that copy does not change the server's file; to change it, use **Edit** (F4, see
  [Editing files on a server](#editing-files-on-a-server)).
- **Rename** (F2), **New Folder** (F7) and **Copy Path** (`host:/path`) work as locally. **Open Terminal Here** opens
  an SSH pane at the folder.
- **Move to Trash** (⌘⌫) never deletes anything on the server: items go to your Trash there,
  `~/.local/share/Trash` (the freedesktop.org Trash that `gio trash`, `trash-cli` and Linux file managers use, so
  they can be restored there). An item on another file system than your home folder cannot be moved there; cmds then
  leaves it where it is and says so.
- A pane restored after a relaunch does not connect by itself; it shows **Connect** (⌘R).

Copying and moving between a remote pane and a local one, or two hosts, goes through the transfer queue.

## Editing files on a server

**Edit** (F4, the right-click menu or **Pane › Files**) on a file in a remote pane downloads it into an editable copy on
this Mac and opens that in the file's default app. Each time you save there, cmds uploads the copy over the server's
file, over the pane's SSH connection (no password, as for everything else in remote panes):

- The upload starts one second after the last write (editors often write a file in several steps); a save during an
  upload is uploaded after it. Saving without changing the content uploads nothing.
- Uploads show in **Window › Transfers** (as "Upload edited …") and below the list of the pane, like other transfers.
  The footer counts the files the pane is editing.
- The upload is written under a temporary name (`.cmds-part-…`) next to the file and then renamed over it in one step,
  so the file on the server is always either the old or the new version. It keeps the file's permissions. (The
  owner becomes your login user, and the folder must be writable for you; editing a file you can write in a folder
  you cannot write in fails.) On a server whose SFTP cannot rename over a file (OpenSSH's can), the old version
  goes to your Trash there first, as Replace does.
- **Changed on the server**: before each upload cmds checks the file's size and date against the version it last
  downloaded or uploaded. If someone changed (or removed) it meanwhile, it asks: **Keep Mine** uploads your version
  over theirs, **Keep Theirs** replaces your edited copy with the server's version (your app then shows it or asks to
  revert), **Save Mine as a Copy** uploads yours as a numbered name (`notes 2.txt`) and later saves go there, and
  **Cancel** uploads nothing now (saving again asks again). cmds is usually in the background while you edit, so a
  notification tells you to answer in cmds. The check uses what SFTP reports (size, and the date to the second): two
  changes of the same size within one second are not told apart.
- If an upload fails (the connection dropped, the disk is full), an alert and a notification say so. The edit goes on:
  your changes stay in the copy, saving again uploads them (reconnecting if needed), and **Retry** in Window ›
  Transfers works too.
- Editing the same file again opens the same copy. A link on the server is edited at the file it points to.
- **Stop Editing** (right-click menu or **Pane › Files**) uploads what is pending and stops watching the copy. Closing
  the pane does the same. The copy is then removed, unless it holds changes that could not be uploaded.
- **Quitting** cmds stops watching every copy. If some hold changes not uploaded yet, cmds asks first; those copies
  are kept in `~/Library/Caches/tokyo.n-n.cmds/remote-edits/` (one folder per edit, never reused), the others are
  removed.
- Edits do not survive a relaunch: after it, edit the file again from its pane.

## Comparing and syncing folders

**Compare and Sync with Other Pane…** (⇧F2, **Pane › Files** or the right-click menu) compares the folder of the
pane with the one of the other files pane of the workspace: two folders on this Mac, one here and one on an SSH host,
or two on servers. A window lists what differs and what a sync would do; nothing changes until you click **Sync**.

- **Left and right** are the panes as they sit in the window (the upper one counts as left when they are stacked).
  The window names both folders at the top.
- **Comparing** reads both folders and everything inside them in the background (**Stop** ends it). Items are
  matched by name. Files are the same when their sizes are equal and their dates differ by at most a second (SFTP
  gives dates to the second); otherwise they are modified. Contents are not read. A folder that exists on only one
  side is one item; a file on one side and a folder on the other count as modified.
- **Symbolic links** are listed but never followed or synced. A folder that cannot be read on one side is listed as
  such, and nothing in it is synced.
- **Hidden items** (names starting with a dot) take part when **Hidden items** is on; it starts as the pane's **Show
  Hidden Files**. Temporary `.cmds-part-…` files of transfers never do.
- Up to 50 000 items are read. A larger comparison stops there and cannot be synced (an item not read could look
  missing); compare smaller folders.

**Direction**:

- **Left → Right** / **Left ← Right** (one-way; it starts from the pane you opened the window in, as F5 copies):
  items new or modified on the source side are copied to the other side; a modified item replaces the other one,
  even when the other one is newer (the list says so). Items only on the target side stay, unless **Move extra
  items to the Trash** is on.
- **Both Ways**: items missing on either side are copied to it, and nothing is moved to the Trash. cmds keeps no
  record of earlier syncs, so for an item that differs it cannot tell which side changed: every modified item is a
  conflict, settled by **Conflicts**: **Newer wins** (default; the later date wins, and items with the same date, or a
  file against a folder, are left as they are), **Left wins**, **Right wins** or **Skip**.

Each row has a checkbox (unticked rows are not synced), and a modified item a menu to choose **Copy to right**,
**Copy to left** or **Skip** for it alone. The line below the list counts what will be copied each way, moved to the
Trash, and the conflicts left as they are. **Show identical items** lists the rest too.

**Sync** queues the checked actions as one transfer (Window › Transfers, and the footer of the pane): with progress,
**Pause**, **Cancel**, **Show Log** (each item with the folder it went to) and **Retry**, as other transfers. When
items will go to the Trash, cmds asks first.

- Nothing is deleted. A replaced item goes to the Trash of its side first (this Mac's Trash, or your Trash on the
  server, as **Move to Trash** does); if it cannot go there, it is not replaced. A file replacing a file is written in
  full under a temporary name first, so the old one goes to the Trash only once the new one is complete.
- Before each item, cmds checks that the side it changes still looks as compared (same kind, size and date). An
  item that changed or appeared after the comparison is left as it is and logged ("Changed since the folders were
  compared"); compare again to sync it. **Retry** does not take such items again.
- Dates and permissions are kept, so the folders compare as the same afterwards.

From a terminal: `cmds files compare LEFT RIGHT` prints the differences and the plan, `cmds files sync --to-right LEFT
RIGHT` (or `--to-left`, `--both`, with `--delete` and `--conflicts newer|left|right|skip`) queues a sync
([CLI reference](../reference/cli.md#commands)). Saving a compare as a favorite is not available (cmds has no
favorites for files panes yet).

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
