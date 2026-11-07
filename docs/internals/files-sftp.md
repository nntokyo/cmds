# Files panes on SSH hosts (internals)

> How remote files panes and the transfer queue work: the `ssh` command line, the SFTP v3 client, connections,
> transfers, the server's Trash, and what is never done.

Using them: [guide/files.md](../guide/files.md#folders-on-ssh-hosts). Design discussion:
[#26](https://github.com/nntokyo/cmds/issues/26#issuecomment-6567549621).

## Transport

cmds runs the user's own `ssh` with the `sftp` subsystem and speaks SFTP version 3 over its stdin and stdout
(`CmdsCore/Files/SSHFileConnection.swift`, `SSHFileCommand.arguments`):

```sh
/usr/bin/ssh [-F $CMDS_FILES_SSH_CONFIG] -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ControlMaster=no \
  -o RemoteCommand=none -o ClearAllForwardings=yes -o ForwardAgent=no -o ForwardX11=no -o PermitLocalCommand=no \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ConnectTimeout=15 -s -- HOST sftp
```

- **The user's `ssh`**, as for SSH panes: `~/.ssh/config`, keys, the agent, `ProxyJump`, `Match`, hardware keys and
  `known_hosts` apply, and cmds stores no credentials. A library (libssh2, swift-nio-ssh) would need all of that
  rebuilt, would need secrets in the Keychain, and would put SwiftNIO into the Mac app.
- **Not the `sftp` program**: its batch mode prints `ls -l` text, which does not survive names with spaces or newlines
  and has no per-chunk progress, pause or cancel. The protocol gives exact attributes and status codes.
- `BatchMode=yes`: ssh never prompts. A host that wants a password, or a key whose passphrase is not in the agent,
  fails at once; the pane says to add a key (`ssh-copy-id`) or add the key to the agent (`ssh-add`). Nothing secret is
  ever handled, so nothing goes in the Keychain.
- `StrictHostKeyChecking=yes` on the command line wins over the config (ssh takes the first value it gets). Unknown
  hosts are refused, nothing is added to `known_hosts` (even with `accept-new` in the config), and a changed key is
  refused with ssh's warning, classified.
- `ControlMaster=no`: an existing master connection (the user's `ControlPath`) is reused, but cmds never becomes the
  master, so closing a files pane cannot cut terminals multiplexed through it.
- `RemoteCommand=none`, `ClearAllForwardings`, `ForwardAgent=no`, `ForwardX11=no`, `PermitLocalCommand=no`: settings
  meant for interactive logins (forwards that would collide with the terminal's, a `RemoteCommand` that conflicts
  with `-s`) do not apply.
- The host is validated by `SSHLaunch.validateHost` and comes after `--`.

`SSHFailure.classify` turns ssh's stderr into: authentication (password-only, key not accepted), unknown host key,
changed host key, unresolved host, refused, timed out, no sftp subsystem, or the last line of stderr. The app shows
its own text for each (`SSHFailure.localizedText`); `description` stays English.

## SFTP client

`CmdsCore/Files/SFTPPacket.swift` encodes and decodes the packets (pure, unit-tested); `SFTPClient` sends requests
from any thread and a reader thread matches replies by id, so one connection serves a listing while a transfer runs.
Calls block the calling thread: the app makes them from background queues and transfer threads only, never from the
main thread. When the stream ends, waiting requests fail with `SFTPError.disconnected(reason)`.

- Reads keep 16 requests of 32 KiB in flight; a short reply is completed with plain reads. Writes keep 16 in flight
  and `finish` waits for all of them.
- `rename` is SFTP v3's: it fails when the target exists (OpenSSH links and unlinks, and checks first for other
  types), so nothing is overwritten.
- `symlink` sends the target first, then the link (OpenSSH's order, the reverse of the draft).
- `posixRename` sends OpenSSH's `posix-rename@openssh.com` extension (offered in the `VERSION` reply, kept in
  `extensions`): `rename(2)`, which replaces an existing file. It is used only to save an edited file over the one it
  came from; without the extension it fails with `unsupported`.
- `remove` exists only for a transfer's own temporary file (`TransferNames.isPart`) and a just-written `.trashinfo`;
  there is no `rmdir`.

## Connections (app)

`RemoteConnections` (`App/Sources/Files`) keeps one `SSHFileConnection` per host, shared by that host's panes and
transfers, made on first use under a per-host lock (two panes opening the same host start one ssh). A connection
nobody has used for 2 minutes, and that no unfinished transfer needs, is closed; a dropped one is made again on the
next use. Quitting cancels transfers and closes every connection.

## Files tree and transfers

`FileTree` (`CmdsCore/Files/FileTree.swift`) is what a transfer needs on either side: item, list, make folder,
read, create (exclusive), rename (never overwriting), trash, remove a part file, links, set times and permissions.
`LocalFileTree` uses POSIX calls (`renamex_np(RENAME_EXCL)`, `O_EXCL`), `SFTPFileTree` the client. Each tree says how
its paths are joined and compared (`FilePathStyle`: the Mac's, or `RemotePath` on a server), so a transfer never
checks which kind of tree it has.

`TransferJob` (rules in its header comment) copies or moves top-level items into a folder:

- Files are written to `.cmds-part-<8 hex>-<name>` next to the target, then renamed into place; cancel or failure
  removes that file only. Each part file is recorded in `transfer-parts.json` in the support folder
  (`TransferPartJournal`) until it is renamed or removed. Ones an earlier run left (quit, crash, or a removal that
  failed with the connection) are removed at launch on this Mac and when a host is connected; only recorded paths with
  a part name are ever removed, and an entry that is not a part name is dropped without touching the file.
- Failures are `TransferFailure` cases: `description` is the English text of the API, CLI and logs; the app shows its
  own text for each (`localizedText`), so only a server's or ssh's own message reaches the UI as it came.
- Name conflicts: the policy, or `onConflict` (the pane's Keep Both / Replace / Skip / Stop alert). Replace moves the
  existing item to the Trash of its side first and is refused when that fails.
- Moves within one tree are renames (a failed rename, e.g. another file system on the server, falls back to copy and
  Trash). Across trees: copy, then the original goes to its Trash.
- Pause holds at the next chunk (files stay open); Cancel stops there and moves a folder the interrupted item had
  created to the Trash. Retry runs the items not done, filling in folders the job made (files of the same size are
  kept).
- Symbolic links are copied as links, special files are logged as not copied.

`TransferQueue` runs at most 2 jobs at once and one per destination folder, each on its own thread, and reports
changes (throttled) on the main queue. `TransferCenter` (app) owns it, asks conflicts in the pane that started a job
(or the Transfers window), and posts `transferDidFinish` so remote panes showing the folders list them again.
Copies between two folders on this Mac keep using `FileOperation` (copyfile, footer progress).

## Editing a server's file

`RemoteEdits` (`App/Sources/Files/RemoteEdits.swift`) keeps one `RemoteEditSession` per edited file:

- **Start** (Edit, F4): `RemoteEditCopy.download` (`CmdsCore/Files/RemoteEdit.swift`) resolves the path with `realpath`
  (a link is edited at its file), refuses anything but a file, and writes the copy (mode 0600, through a part file) into
  a new folder `remote-edits/<host>-<random>/` in the cache (the support folder of isolated instances), recording the
  server file's `RemoteFileVersion` (size, mtime in seconds) and the content's SHA-256. The copy opens in its default
  app (`NSWorkspace.open`). The same file edited again opens the existing copy.
- **Watching**: `FileWatcher` (vnode source on the copy, which follows atomic saves). Each write is an event for
  `RemoteEditUploads` (pure, unit-tested): a debounce of 1 s, one upload at a time, another one after it when the copy
  changed during the upload, and ending uploads what is pending first. An upload whose hash equals the last uploaded
  or downloaded content does nothing.
- **Upload**: a `TransferJob` in `.save` mode (`TransferCenter.startSave`), so it runs in the queue (Transfers window,
  footer, log, Retry, `transfer.list` with `mode: save`). It `lstat`s the server's file and compares it with the
  version (`RemoteFileVersion.change`): unchanged → upload; a folder or link now → fails (`notAFile`); changed or
  gone → `onConflict` with the save's own alert (Keep Mine = `.replace`, Keep Theirs = `.skip`, Save Mine as a Copy =
  `.keepBoth`, Cancel = `.stop`). With nobody to ask (no pane, no window), the job stops: Skip would overwrite the copy.
- The upload goes to a part file created with the server file's permissions (| 0600 while writing, then set exactly),
  then `renameReplacing` (`posix-rename@openssh.com`) puts it over the file in one step. A server without the
  extension: the file goes to the server's Trash, then a plain rename (logged as replaced). Keep Theirs downloads the
  server's file into a part file next to the copy and renames it over the copy (`rename(2)`). The job's
  `SaveResult` (name, new version, content hash) becomes the session's base for the next save; after Save Mine as a
  Copy, the session follows the copy's name.
- **End**: Stop Editing, the pane's `tearDown`, or quit. The copy's folder is removed unless the copy holds changes the
  server does not have (an upload pending, running, failed or stopped, or a hash that differs); quitting asks first
  when there are such copies (`applicationShouldTerminate`). Nothing is restored after a relaunch. A dropped
  connection does not end an edit: the next upload connects again (`RemoteConnections`).
- Known limits: SFTP v3 gives mtimes in seconds, so a change of the same size within the second of the last download
  or upload is not seen; between the check and the rename there is a short window in which a change on the server is
  overwritten; the rename makes the login user the owner, and needs a writable folder.

## The server's Trash

`RemoteTrash` moves items into the login user's freedesktop.org Trash, `~/.local/share/Trash/files`, after writing
`info/<name>.trashinfo` (`Path=` percent-encoded, `DeletionDate=` local time) with an exclusive create; taken names get
a number. It is a rename, so an item on another file system than the home folder cannot go there: the operation then
fails, the `.trashinfo` it just wrote is removed, and the item stays where it is. The Trash itself, or a folder
containing it, is refused. `gio trash --list`, `trash-cli`'s `trash-restore` or a desktop file manager on the server
list and restore these items.

## Remote panes (app)

`FilesPane` with a `host` (`FilesPane+Remote.swift`): the listing resolves `~`, `~/…` and relative paths against
the login folder (`RemotePath.absolute`) and then with `realpath`, follows a path that names a file to its folder
(selecting it), and `stat`s symbolic links to know whether they open like folders. Kinds come from the extension (`UTType`). There is no Git column, no folder watching (⌘R,
the pane's own commands and finished transfers list it again) and no Follow Terminal. Open and Space download a copy
into `~/Library/Caches/tokyo.n-n.cmds/remote-files/<host>-<hash>/` (in the support folder for isolated instances),
read only; Edit downloads an editable copy instead ([above](#editing-a-servers-file)). Restored remote panes wait
for Connect. `PaneInfo.remote = {host, connected}`; the workspace's location
never follows a files pane.

## Not done (later phases of #26)

Compare and sync, dragging remote items to the Finder (file promises),
the Git column on servers, following an SSH pane's `cd`, other protocols, and browsing from the iPhone.
