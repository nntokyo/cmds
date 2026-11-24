# Keyboard shortcuts

> Every default key equivalent of the Mac app, by menu (source of truth: `App/Sources/Shortcuts/MainMenu.swift`).

Help › Keyboard Shortcuts (⌘?) shows a short version in the app (the defaults). To change them, see
[Changing shortcuts](#changing-shortcuts).

## Changing shortcuts

Every menu item can get another key, or none, from a terminal:

```sh
cmds shortcuts                              # the items with a key: key, id, menu (* = changed)
cmds shortcuts --all                        # also the items without a key
cmds shortcuts set splitRight ctrl+opt+d    # Pane › Split Right becomes ⌃⌥D
cmds shortcuts set selectWorkspace-1 ""     # Workspace › Workspace 1 loses ⌘1
cmds shortcuts reset splitRight             # back to ⌘D
cmds shortcuts reset                        # every item back to its default
```

- An item's id is its action (`splitRight`), the same in every language; items sharing one get `-1`, `-2`, … in menu
  order (`selectWorkspace-1` … `selectWorkspace-9`).
- Keys are written as modifiers and a key joined by `+`: `cmd`, `shift`, `opt` (`alt`), `ctrl`, then a letter, digit
  or sign (`cmd+,`, `cmd+plus`), `left` / `right` / `up` / `down`, `return`, `tab`, `space`, `delete`, `escape`,
  `home` / `end`, `pageup` / `pagedown` or `f1`–`f20`. `⇧⌘D` works too. A key needs ⌘, ⌃ or ⌥ (except F1–F20), as
  it would otherwise be taken from what you type.
- A key another item has is refused, naming that item: free it first (`cmds shortcuts set <its id> ""`). The hidden
  alternates (⌃Tab / ⌃⇧Tab for the next / previous workspace, ⌘+ for Bigger) keep their keys.
- Changes apply at once and are kept in cmds' settings; the menus show the new keys. Help › Keyboard Shortcuts and
  this page list the defaults. API: `shortcuts.list`, `shortcuts.set`, `shortcuts.reset`.

## Workspaces

| Action | Key | Menu |
|---|---|---|
| New workspace | ⌘N | File |
| New SSH workspace… | ⇧⌘N | File |
| New worktree workspace… | ⌥⌘N | File |
| Close workspace | ⇧⌘W | File |
| Rename workspace… | ⇧⌘R | Workspace |
| Next / previous workspace | ⇧⌘] / ⇧⌘[, also ⌃Tab / ⌃⇧Tab | Workspace |
| Select workspace 1–9 | ⌘1 … ⌘9 | Workspace |

## Tiled view

| Action | Key | Menu |
|---|---|---|
| Tile several workspaces | ⌘-click / ⇧-click rows in the sidebar | – |
| Tile all workspaces (toggle) | ⌃⌘T | View |
| Tile the last selection again | – | View › Tile Selected Workspaces |
| Show one workspace again | Esc (sidebar focused), ⌃⌘T | View › Show Single Workspace |
| Zoom the active tile (toggle) | ⇧⌘↩ | View › Zoom Tile |
| Move to the tile left / right / up / down | ⌥⌘← / ⌥⌘→ / ⌥⌘↑ / ⌥⌘↓ | Pane |
| Move the active tile left / right / up / down | ⌃⇧⌘← / ⌃⇧⌘→ / ⌃⇧⌘↑ / ⌃⇧⌘↓ | View › Move Tile … |
| Tile a workspace beside / above / below a tile, or in its place | drag its sidebar row onto the tile's edge or middle | – |
| Move or swap tiles | drag a tile header onto another tile's edge or middle | – |
| Take a tile out of the tiled view | drag its header onto the sidebar (or out of the window with ⌥) | – |

## Panes

| Action | Key | Menu |
|---|---|---|
| Split right | ⌘D | Pane |
| Split down | ⇧⌘D | Pane |
| New tab beside the focused pane (browser tab in a browser, else a terminal) | ⌘T | Pane |
| Next / previous tab of the focused pane | ⌥⌘] / ⌥⌘[ | Pane |
| Move the focused tab left / right | ⌃⇧⌘[ / ⌃⇧⌘] | Pane |
| All tabs of a group (when they do not fit) | click ⌄ next to + | – |
| Show a tab / close it | click it / its × or a middle click | – |
| Make a pane a tab of another | drag its grip or tab onto a tab bar, or onto the top strip of a pane | – |
| Focus pane left / right / up / down | ⌥⌘← / ⌥⌘→ / ⌥⌘↑ / ⌥⌘↓ | Pane |
| Swap the focused pane with the pane left / right / above / below (also across tiles) | ⌥⇧⌘← / ⌥⇧⌘→ / ⌥⇧⌘↑ / ⌥⇧⌘↓ | Pane |
| Move the focused pane to another workspace (picker) / to a new workspace | – | Pane › Move to Workspace… / Move to New Workspace |
| Move a pane by drag | drag the grip at the pane's top edge | – |
| Zoom pane (toggle; zooms the tile in the tiled view) | ⇧⌘↩ | View |
| Jump to latest attention pane | ⇧⌘U | Pane |
| Find in the terminal (find bar; Esc closes) | ⌘F | Edit › Find |
| Export the focused terminal's scrollback to a file | – | Pane › Export Scrollback… |
| Next / previous hit (also Return / ⇧Return in the find bar) | ⌘G / ⇧⌘G | Edit › Find |
| Find in all terminals (lines of every scrollback; Return shows the pane with its find bar) | ⇧⌘F | Edit › Find |
| Close pane (a tab: Close Tab) | ⌘W | File |
| Open browser split | ⇧⌘B | File |
| Open a Chrome bookmark in a new tab | ⌘-click it in the bookmarks bar | – |
| View page source (browser pane) | ⌥⌘U | View › Developer |
| Show / hide the console drawer (browser pane) | ⌥⌘C | View › Developer |
| SEO report of the page | – | View › Developer |
| Point at an element and tell the agent what is wrong (browser pane; again or Esc: give up) | ⇧⌘C | View › Developer |
| Open in Preview… (file picker) | ⇧⌘O | File |
| Preview a file path shown in a terminal | ⌘-click the path | – |
| New files pane (lists the focused pane's folder; an SSH pane's remote folder on its host) | ⇧⌘E | File |
| New remote files pane (a folder on an SSH host) | ⌥⇧⌘E | File |
| Transfers window | ⌥⌘T | Window |

## Browser, preview and SSH panes

| Action | Key | Menu |
|---|---|---|
| Focus address bar | ⌘L | View |
| Reload (browser page; preview file; files pane's folder; **reconnect** a disconnected SSH pane) | ⌘R | View › Reload Page |
| Back / forward (browser; files pane) | ⌘[ / ⌘] | View |

## Files panes

In the list of a files pane ([guide](../guide/files.md)). F-keys, Space and Return are taken by the list only, never
as menu shortcuts, so programs in terminals keep them.

| Action | Key | Menu |
|---|---|---|
| Open (folder in the pane, file in its default app) | Return, ⌘↓, double-click | right-click › Open |
| Show in the preview pane | Space | Pane › Files |
| Enclosing folder | ⌘↑ | Pane › Files |
| Back / forward | ⌘[ / ⌘] | View |
| Go to folder (type a path; the list takes ⇧⌘G before Find Previous) | ⇧⌘G | Pane › Files |
| Show hidden files (toggle) | ⇧⌘. | Pane › Files |
| Select by name | type its first letters | – |
| Copy / move to the other files pane | F5 / F6 | Pane › Files |
| Keyboard to the other files pane | Tab | – |
| Rename | F2 | Pane › Files |
| Compare and sync with the other files pane | ⇧F2 | Pane › Files |
| Edit (on an SSH host: a copy uploaded on every save) | F4 | Pane › Files |
| New folder | F7 | Pane › Files |
| Move to Trash | ⌘⌫ | Pane › Files |
| Copy items / paste (copy) here / move here | ⌘C / ⌘V / ⌥⌘V | Edit (⌘C, ⌘V) |
| Reload the folder | ⌘R | View |

## Text size

| Action | Key | Menu |
|---|---|---|
| Settings (default terminal font and size, sidebar text size, browser/preview zoom) | ⌘, | cmds › Settings… |
| Bigger text in the focused pane (terminal font size; browser/preview page zoom) | ⌘+ (⌘=) | View › Bigger |
| Smaller text in the focused pane | ⌘− | View › Smaller |
| Back to the Settings size in the focused pane | ⌘0 | View › Actual Size |
| Reconnect a disconnected SSH pane | Return (on the overlay) or ⌘R | – |

## Window and sidebar

| Action | Key | Menu |
|---|---|---|
| Command palette (workspaces, panes, commands, agent sessions, ports) | ⇧⌘P | View |
| Toggle sidebar | ⌘B | View |
| Compact sidebar (52 pt rail; also the button at the top of the sidebar) | ⌃⌘S | View |
| Filter workspaces (⌘F while the sidebar has the keyboard; Esc closes) | ⌥⌘F | View |
| Group workspaces by project | – | View |
| Enter full screen | ⌃⌘F | View |
| Minimize | ⌘M | Window |
| Keyboard shortcuts | ⌘? | Help |

## Standard

| Action | Key |
|---|---|
| Undo / redo | ⌘Z / ⇧⌘Z |
| Cut / copy / paste / select all | ⌘X / ⌘C / ⌘V / ⌘A |
| Hide cmds / hide others | ⌘H / ⌥⌘H |
| Quit cmds | ⌘Q |

Menu items without a shortcut (Pair iPhone/iPad…, Keep Awake With Lid Closed…, Language, Export/Import Workspaces…,
Resume Agent Sessions on Launch, Recent Agent Sessions, Install Remote Helper…, …) are described in the [guides](../README.md#user-guides).
