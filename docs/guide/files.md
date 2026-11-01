# Files panes

> A local folder as a list next to your terminals: browse, preview, copy and move between two panes, rename, new
> folder, Move to Trash, follow a terminal's `cd`, and drop files on a terminal to type their paths.

A files pane is one more kind of pane, like a browser or preview pane: split it, zoom it, close it with ⌘W, and it
comes back after a relaunch. Two of them side by side give a two-pane file manager. Folders on SSH hosts (SFTP),
transfer queues and folder sync are planned for later phases of
[#26](https://github.com/nntokyo/cmds/issues/26).

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
```

Files panes list folders on this Mac only, so `cmds files` is not available from SSH panes.

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
  installed.

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
copies the item and then puts the original in the Trash.

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

## iPhone and iPad

The companion lists files panes with a folder icon and shows the folder's path; browsing it from the phone comes in a
later phase. Older companion versions show a files pane as a browser pane with the folder's `file://` URL
([sync protocol](../internals/sync-protocol.md#files-panes)).

## Keys

All keys of the list: [shortcuts](../reference/shortcuts.md#files-panes).
