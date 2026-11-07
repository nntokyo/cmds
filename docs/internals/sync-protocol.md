# iOS companion sync protocol (v2)

> The wire protocol between the Mac app and the iOS/iPadOS companion: transports (LAN, Bluetooth, SSH relay),
> messages, pairing, the Mac's identity and the threat model.

The cmds Mac app streams workspaces and terminal screens to the iOS/iPadOS companion over the local network.
Setting it up as a user: [guide/iphone.md](../guide/iphone.md). Code: `Packages/CmdsCore/Sources/CmdsCore/Sync/` (shared by both sides).

## Transport

- WebSocket over **TLS 1.3** (Network.framework `NWProtocolWebSocket` over `NWProtocolTLS` on both
  sides, settings in `SyncTLS`). One JSON object per **text** frame, UTF-8, max 4 MiB
  (`SyncCodec.maxFrameBytes`). Path is ignored. TLS session resumption and tickets are off on both
  sides, so every connection is a full handshake in which the phone checks the certificate.
- The Mac presents its own **sync identity**: an ECDSA P-256 key and a self-signed X.509 certificate
  (CN `cmds <Mac name>`, 20-year validity), see "Mac identity". The phone accepts only the certificate
  whose SHA-256 it pinned when pairing; there is no CA and no plaintext fallback.
- The Mac listens with `NWListener` and advertises Bonjour `_cmds._tcp`
  (`SyncProtocol.bonjourServiceType`). TXT record (`SyncProtocol.txtRecord(macName:fingerprint:)`):
  `name` = Mac display name, `version` = protocol version, `fp` = certificate fingerprint. `fp` is a
  hint for diagnostics only; anyone can advertise anything, and the phone never trusts it.
- Manual entry fallback: `host[:port]`, default port `47823` (`SyncProtocol.defaultPort`). The phone
  connects to `wss://host:port/`.
- **Bluetooth fallback** when the Mac cannot be reached over IP (e.g. Wi‑Fi off): the same TLS
  WebSocket session, carried over a Bluetooth LE L2CAP channel. See "Bluetooth".
- **Remote access via SSH** (optional) away from the LAN: the same TLS WebSocket session, carried through
  an SSH server the user already has (the relay host). See "Remote access via SSH".

## Bluetooth

Bluetooth is a dumb byte pipe. The phone runs exactly the same pinned TLS 1.3 WebSocket session as over
the network; only the bytes travel over an L2CAP channel. Code: `CmdsCore/Sync/SyncBluetooth.swift`,
`SyncStreamRelay.swift` (shared), `App/Sources/Sync/SyncBluetoothPeripheral.swift`,
`iOS/Sources/Connection/BluetoothTransport.swift`, `FallbackTransport.swift`.

- **Mac (peripheral).** While the sync listener runs and **Allow Bluetooth Sync** (app menu, on by default)
  is on, a `CBPeripheralManager` publishes an L2CAP channel without link encryption
  (`publishL2CAPChannel(withEncryption: false)`: an encrypted channel requires a Bluetooth bond, and the bonding prompt
  made `openL2CAPChannel` fail with "Unknown error" on a real iPhone) and advertises service `SyncBluetooth.serviceUUID` (local
  name `cmds`). Its characteristic `SyncBluetooth.infoCharacteristicUUID` is readable without pairing and
  holds `SyncBluetooth.Info`: `version(1)=1 | PSM (UInt16 LE) | first 8 bytes of the certificate
  fingerprint | Mac name (UTF-8, ≤ 64 bytes)`. Like the Bonjour TXT record these are hints only.
- **Relay (Mac).** For each opened channel (at most 8) the Mac binds a TCP socket on 127.0.0.1, registers
  its local port as peer `bluetooth:<first 8 hex digits of the CBCentral identifier>`
  (`SyncLoopbackPeers`), connects to its own sync listener and copies bytes both ways
  (`SyncStreamRelay`: 64 KiB buffer per direction; a full buffer stops reading that side, so Bluetooth and
  TCP flow control push back; either side ending closes both). The sync server sees an ordinary TLS
  client. On accept it maps a loopback connection whose remote port is registered to that peer label, so
  every per-host limit (pending connections, failed pairing attempts, lockouts) applies per phone, not to
  all Bluetooth peers as one "127.0.0.1". The port is registered before `connect()`, so the entry always
  exists when the server accepts; only this process can register, any other loopback client stays
  "127.0.0.1". No check is skipped or relaxed for relayed connections.
- **Phone (central).** `BluetoothTransport` scans for the service, connects, reads the info of every
  cmds service on the peripheral and opens the L2CAP channel of the one whose fingerprint hint matches the
  pin (other Macs are skipped). It then listens on 127.0.0.1 (ephemeral port), relays the first accepted
  socket to the channel and connects the normal `WebSocketTransport` to `wss://127.0.0.1:<port>/` with
  the pinned policy. Pairing (QR or manual compare) and tokens work unchanged. The identity probe of
  manual pairing is network-only.
- **Selection.** `FallbackTransport` starts the network connection (Bonjour or address) and, if it has not
  connected after 3 s, has failed, or the phone has no Wi‑Fi/Ethernet at all, starts the Bluetooth attempt
  as well. The first one to finish the pinned handshake wins and the other is closed. An identity mismatch
  on either path ends the attempt (it is never worked around via the other path). The status shows the
  active path ("Wi‑Fi" / "Bluetooth"). A connection that started on Bluetooth stays there until it drops.
- **Throttling.** Screen updates to a relayed connection go out at most every 250 ms (4 Hz,
  `SyncBluetooth.screenInterval`); changes in between are coalesced into one diff per pane. This is a
  per-connection setting on the Mac, not a protocol change.
- **Permissions.** Both apps declare `NSBluetoothAlwaysUsageDescription`; the phone asks for Bluetooth
  access the first time it needs the fallback. No background mode: the fallback runs while the app is in
  the foreground. The L2CAP channel is opened without link encryption, so there is no Bluetooth pairing
  (bonding) prompt; the pinned TLS session protects the data.

## Remote access via SSH

SSH is a dumb byte pipe, like Bluetooth. The phone runs exactly the same pinned TLS 1.3 WebSocket session as
on the LAN; the Mac and the phone each log in to a relay host the user controls, and the relay only joins two
TCP streams on its loopback. Code: `CmdsCore/Sync/SyncRemote.swift`, `App/Sources/Sync/SyncRemoteAccess.swift`
(+ `SyncRemoteAccessWindowController.swift`), `Packages/CmdsSSH` (SSH client, iOS only),
`iOS/Sources/Connection/SSHTransport.swift`, `iOS/Sources/Support/RemoteAccessStore.swift`,
`iOS/Sources/Views/RemoteAccessView.swift`.

- **Mac.** cmds › Remote Access via SSH…: on/off, relay host (a `Host` alias from `~/.ssh/config`, or
  `user@host`) and relay port (default `47824`, `SyncRemote.defaultRelayPort`). Saved in
  `<support dir>/sync-remote.json` (0600), so isolated instances never share it. While on and the sync
  listener runs, cmds runs `/usr/bin/ssh -N -T -o BatchMode=yes -o ExitOnForwardFailure=yes
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ControlPath=none … -R 127.0.0.1:<relay port>:127.0.0.1:<ingress port> -- <host>`
  (`SyncRemote.sshArguments`). ssh uses the user's config, keys, agent and known_hosts and never prompts;
  a host it does not know yet fails (connect once in Terminal first). It is restarted when it exits (2 s
  doubling to 60 s; `ExitOnForwardFailure` makes it exit while the relay still holds the port of a dead
  session). The status shows in that window and in the pairing window. The pid and the process start time
  are kept in `sync-remote-ssh.pid` so an ssh orphaned by a crash is ended at the next launch (only if pid,
  start time and `/usr/bin/ssh` still match and it has no parent, so a reused pid is never killed).
- **Ingress (Mac).** The forward does not end at the sync listener: it ends at a loopback listener of cmds
  ("ingress", ephemeral port), which relays each connection (at most 16) to the sync listener from a socket
  registered as peer `ssh:<relay host>` (`SyncServer.relayedPeers`, the mechanism of the Bluetooth relay).
  The sync server applies every check as for any client, keeps SSH clients apart from other loopback
  clients for per-host limits, and **refuses pairing codes** from them (`pairingRequired`): remote access
  only reuses a pairing made on the LAN (QR code or manual compare). All phones behind one relay share
  the `ssh:<host>` label (the relay does not tell who opened the channel).
- **Phone.** Per paired Mac, ⋯ › Remote Access via SSH…: relay host, SSH port, user, relay port, on/off.
  The phone generates an Ed25519 key once (Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
  service `tokyo.n-n.cmds.companion.ssh-key`) and shows the line for the relay's `authorized_keys`
  (copy/share), restricted to what cmds needs:
  `restrict,port-forwarding,permitopen="127.0.0.1:<relay port>",permitlisten="127.0.0.1:1",command="false" ssh-ed25519 AAAA… cmds-<device>`
  (one `permitopen` per relay port of all Macs set up on the phone, since one key gets one line)
  (`restrict` alone still allows shell/exec requests and `port-forwarding` re-enables `-R`, hence the forced
  command and the listen limit to a privileged port; OpenSSH 7.8+). The app
  never asks for or sends a password (public key only, offered once). **Host key:** "Check Connection"
  connects without a pin; the presented key's `SHA256:` fingerprint is shown for comparison with
  `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the relay; only "It Matches" pins it (per
  `host:port`). Remote access is used only with a pinned host key; any other key later fails the login before
  authentication. The check then opens the channel to the relay port, so it also tells whether the Mac's
  forward is up.
- **Connection.** `SSHTransport` (swift-nio-ssh over Network.framework via NIOTransportServices) logs in,
  opens a `direct-tcpip` channel to `127.0.0.1:<relay port>` on the relay (refused = the Mac is not
  forwarding), listens on the phone's 127.0.0.1 (ephemeral port), glues the first accepted socket to the
  channel (later ones are closed) and connects the usual `WebSocketTransport` to `wss://127.0.0.1:<port>/`
  with the pinned policy.
- **Selection.** `FallbackTransport` starts SSH (only if set up and its host key is pinned) 6 s after the
  network attempt, as soon as the network and Bluetooth attempts have both failed, or at once when the
  phone has no Wi‑Fi. First pinned handshake wins, as before; an identity mismatch on any path ends the
  attempt. The status badge shows "<Mac> · SSH".
- **Relay host requirements.** OpenSSH with `AllowTcpForwarding yes` (or `local` for the phone's user and
  `remote` for the Mac's), `GatewayPorts no` (the forward binds loopback only either way, because cmds asks
  for `127.0.0.1`), public-key login for both users; recommended `ClientAliveInterval 15` and
  `ClientAliveCountMax 3` so a dead Mac session frees the relay port quickly.

## Envelope

Every message is a flat object with a `type` discriminator; other keys are the payload.
Unknown keys are ignored. Unknown `type`s throw `UnknownSyncMessageType` (the phone ignores them; the
Mac should answer `error{badRequest}`). Optional fields are omitted when nil.

```json
{"type":"input","paneID":"p1","text":"ls\n"}
```

## Phone → Mac (`ClientMessage`)

| type | fields | notes |
|---|---|---|
| `hello` | `protocolVersion:Int, deviceName:String, deviceID?:String, pairingCode?:String, token?:String, features?:[String]` | First message, sent only after the TLS handshake passed the pin check. The token saved with that pin, or the 6-digit code while pairing. `features`: optional additions the phone understands (`SyncFeature`): `"preview"` (see "Preview panes"), `"files"` (see "Files panes"), `"scrollbackStream"` (see "Scrollback"), `"styles"` (see "Styles"), `"schedules"` (see "Schedules"), `"filesBrowse"` (see "Files panes"). The Mac lists what it answers in `welcome.features`. |
| `subscribe` | `paneIDs:[String]` | Replaces the streamed set. Mac sends a full `screen` for each new pane. `[]` stops streaming. |
| `requestScreen` | `paneID` | Ask for a full `screen` (after a diff gap). |
| `input` | `paneID, text` | Typed/pasted text, sent as-is (no newline translation). |
| `key` | `paneID, key:SyncKey` | `enter tab backtab esc backspace delete up down left right home end pageup pagedown` or `ctrl-<x>` (`ctrl-c`, `ctrl-d`, …). `SyncKey.terminalBytes(applicationCursor:)` gives xterm bytes. |
| `selectWorkspace` | `id` | Switch the Mac to that workspace. |
| `focusPane` | `id` | Focus a pane on the Mac. |
| `ping` | `nonce?:Int` | Phone pings every 10 s; reconnects if nothing received for 30 s. |
| `requestFile` | `paneID, path?` | Optional (feature `preview`). The file shown in that preview pane; with `path` (feature `filesBrowse`) that file of a files pane, see "Files panes". Answered with `file` pieces or `error` (`notFound`: no such pane / file missing; `badRequest`: not a preview pane, feature not announced, a request already running). Older Macs answer `error{badRequest}` (unknown type). |
| `requestListing` | `paneID, path?` | Optional (Macs whose `welcome.features` has `"filesBrowse"`). A folder of a files pane: `path` (absolute) or, absent, the folder the pane shows. Answered with `listing`, also on failure. See "Files panes". |
| `requestScrollback` | `paneID, lines:Int` | Optional (Macs whose `welcome.features` has `"scrollback"`). Up to `lines` rows above the pane's screen (1…1000, `SyncScrollback.maxLines`). Answered with a full `screen` and right after it `scrollback` under the same `seq`, or `error` (`notFound`: no such pane; `badRequest`: not a terminal pane, or not subscribed). Within 0.5 s of the previous answer for that pane, or while output keeps the screen moving, it is answered later (one waiting request per pane; a newer one replaces it). Older Macs answer `error{badRequest}` (unknown type). See "Scrollback". |

## Mac → Phone (`ServerMessage`)

| type | fields | notes |
|---|---|---|
| `welcome` | `protocolVersion, macName, token, features?:[String]` | Auth OK. Phone stores `token` together with the pinned fingerprint in the Keychain per Mac. `features`: optional requests this Mac answers (`SyncFeature`): `"scrollback"`, `"scrollbackStream"` (see "Scrollback"), `"styles"` (see "Styles"), `"schedules"` (see "Schedules"), `"filesBrowse"` (see "Files panes"); absent from older Macs. |
| `error` | `code:SyncErrorCode, message` | Codes: `unsupportedVersion pairingRequired invalidPairingCode invalidToken rateLimited notAuthenticated badRequest notFound internal`. After auth errors (`isAuthFailure`) the Mac closes the socket. |
| `state` | `workspaces:[WorkspaceInfo], system?:SystemStats, agentLimits?:[AgentLimits], accountLimits?:[{name, resetsAt, estimated}]` | `accountLimits` = the Mac's Claude accounts (Settings › Agents › Claude accounts) at a limit now, with its end (epoch s); `name` matches `PaneInfo.account`; names only; omitted when none is limited or by older Macs (#112). `agentLimits` = latest account limits per coding agent (`{agent: claude/codex/other, limits:[{id: five_hour/seven_day/spend/…, usedPercent, resetsAt? (epoch s), windowMinutes?, usedUSD?, limitUSD?, period?}], plan?, updatedAt}`), omitted when none is known or by older Macs; panes running an agent carry `PaneInfo.agent?` (`AgentUsage`, see [reference/api.md](../reference/api.md#types)). Agent figures alone change at the same ≤ 2 s cadence as CPU/memory. Full snapshot (CmdsCore `WorkspaceInfo`/`PaneInfo`/`LayoutNode`). Sent after `welcome` and on any change; changes of CPU/memory figures alone are pushed at most every 2 s and only while a phone is connected. `WorkspaceInfo.cpuPercent?` (processes of the workspace, 100 = one core) and `memoryBytes?` (physical footprint). `system` = `{cpuPercent (0–100, all cores), memoryUsedBytes, memoryTotalBytes, memoryPressure? (1 normal, 2 warning, 4 critical)}`; absent from Macs that predate it. |
| `screen` | `paneID, seq:UInt64, rows, cols, lines:[String], cursorRow?, cursorCol?, scrolledOff?:[String], historyReset?:Bool, styles?:[{row, runs}]` | Full visible screen, i.e. the Mac's viewport (the rows above it: `requestScrollback`). Trailing spaces may be trimmed. Cursor nil = hidden. `scrolledOff` / `historyReset`: phones with `"scrollbackStream"` only, see "Scrollback". `styles`: phones with `"styles"` only, the rows that have colours or attributes, see "Styles"; `scrolledOffStyles?:[{row, runs}]` the same for `scrolledOff`. |
| `screenDiff` | `paneID, seq, baseSeq, changes:[{row,text,runs?}], cursorRow?, cursorCol?, scrolledOff?, historyReset?, scrolledOffStyles?` | Only when rows/cols unchanged. Applies to the screen with `seq == baseSeq`; cursor is absolute. `scrolledOff` / `historyReset` / `scrolledOffStyles` as in `screen`. `runs`: phones with `"styles"` only; a row changes when its text or its runs change, and a changed row without `runs` is plain. |
| `notification` | `paneID?, workspaceID, title, body` | Pane raised attention (agent waiting, OSC 9/777…). Phone posts a local notification. |
| `pong` | `nonce?` | Echo of `ping.nonce`. |
| `file` | `paneID, name, mime, size:Int, offset:Int, data:base64, truncated?:Bool, path?` | Answer to `requestFile`: bytes `offset ..< offset+len(data)` of the `size`-byte file, in pieces of ≤ 2 MiB (`SyncFile.chunkBytes`, so a frame stays under 4 MiB), in order; complete when the pieces reach `size` (an empty file is one piece with `size` 0). `truncated: true` (no data): over `SyncFile.maxBytes` (10 MB) or unreadable. `path`: the `requestFile.path` answered (files panes), in every piece. |
| `listing` | `paneID, path, entries:[{name, kind, linksToFolder?, size?, modified?}], truncated?:Bool, error?` | Phones with `"filesBrowse"` only: answer to `requestListing`. See "Files panes". |
| `schedules` | `schedules:[{id, name, enabled, trigger?, action:{type, agent?, to?}, nextFireAt?, activeRun?, lastRun?}], runs:[ScheduleRun], readOnly?:Bool` | Phones with `"schedules"` only: the Mac's schedules, read only. Sent after `welcome` and `state`, and on change at most once per second. See "Schedules". |
| `scrollback` | `paneID, seq, lines:[String], styles?:[{row, runs}]` | Answer to `requestScrollback`, sent right after the full `screen` with the same `seq`: the rows above that screen, oldest first, the last one directly above its first row. One entry per displayed row (soft wraps kept, trailing spaces trimmed); empty when there are none. `styles`: phones with `"styles"` only, see "Styles". |

`seq` increases per pane for every `screen`/`screenDiff` and never goes backwards on a connection.
The phone (`ScreenMirror`) ignores stale messages and sends `requestScreen` when a diff's `baseSeq`
does not match.

## Preview panes

Preview panes (`PaneKind.preview`, `PaneInfo.file` = path on the Mac) appear in `state` only for phones whose
`hello.features` contains `"preview"`. Other (older) phones fail to decode an unknown pane kind, so the Mac sends
them preview panes as `browser` panes with `url` = `file://<path>` (`ServerMessage.State.withoutPreviewPanes`; the
state is encoded once per variant). Such a phone shows the pane like a browser pane.

The phone fetches images (`image/*`) and PDFs with `requestFile {paneID}` and shows them (SwiftUI image with
pinch zoom, PDFKit); other types show the name and "Open on Mac" (`focusPane`). What can be fetched is bounded by the
Mac: only the file currently shown in an existing preview pane (the request names a pane, never a path; the user or
an agent on the Mac chose that file), at most 10 MB, one request at a time per connection, read off the main thread.
The phone keeps the result per pane until the pane goes away or its file changes (reload button to fetch again).
Files panes are different: with `filesBrowse` the request names a path (see "Files panes").
`SyncFileAssembler` (CmdsCore) joins the pieces; pieces out of order restart it.

## Files panes

Files panes (`PaneKind.files`, `PaneInfo.workingDirectory` = the folder on the Mac) appear in `state` only for phones
whose `hello.features` contains `"files"`. Other phones (also those with `"preview"`) fail to decode the unknown pane
kind, so the Mac sends them files panes as `browser` panes with `url` = the folder's `file://` URL
(`ServerMessage.State.forPhone`, `withoutFilesPanes`; the state is encoded once per variant).

**Browsing** (#26 phase 4). A phone that lists `"filesBrowse"` (`SyncFeature.filesBrowse`) in `hello.features` can ask a
Mac that lists it in `welcome.features` for the contents of a files pane's folders and for their files. Read only:
there is no message to write, rename, move, delete or transfer, and the Mac pane does not move (the phone keeps its
own place). Code: `CmdsCore/Sync/SyncListing.swift` (`SyncFolderReader`, `SyncListing`), `App/Sources/Sync/SyncServer+Files.swift`.

- **`requestListing {paneID, path?}`**: `path` absolute; absent = the folder the pane shows. The path is standardized
  lexically (`.`/`..` removed, repeated `/` collapsed, `..` stops at `/`; no `~`, no symlink resolution); a relative
  path, control characters or more than 4096 bytes fail with `badPath`. Any folder can be asked for, not only below
  the pane's: a paired phone already has a shell in every terminal pane, so this adds no reach.
- **`listing {paneID, path, entries, truncated?, error?}`**: `path` = the folder listed (standardized; for a request
  without a path, the pane's folder; on failure the requested path). `entries` = `{name, kind: file | folder | symlink |
  other, linksToFolder?: true (a link whose target is a folder, opened like one), size? (bytes of files and links to
  files), modified? (epoch s)}`, folders and links to folders first, then by name like the Mac's list
  (`FileSorting`), at most 2000 (`SyncListing.maxEntries`; `truncated: true` when there were more). Names with `/`,
  `.`/`..` or NUL are left out. Hidden items (dot names, and on this Mac the hidden flag) only when the pane shows
  hidden files. `error` (no entries) = a `SyncListing.Failure`: `paneNotFound`, `notFilesPane`, `badPath`,
  `notFound`, `notAFolder`, `permissionDenied`, `remoteNotConnected`, `other`; phones show unknown codes as `other`.
  Unknown entry kinds decode as `other`, entries the phone cannot read are dropped.
- **Files**: `requestFile {paneID, path}` sends that file of a files pane in `file` pieces exactly like a preview
  pane's (10 MB cap, `truncated` beyond), each piece carrying `path`. Only regular files (after following links) are
  read, so a pipe or device never blocks the reader; anything else is `error{badRequest, "notAFile"}`, a missing file
  `error{notFound, "notFound"}` (the message is a `SyncListing.Failure`). One file at a time per connection, shared
  with preview panes.
- **The Mac** reads off the main thread, one listing at a time per phone (a request that arrives meanwhile waits; a
  newer one replaces it, so the phone asks again for a folder whose answer never came). A pane on an SSH host is read
  through the SFTP connection that pane already has (`RemoteConnections.openTree`, which never connects); without one
  the answer is `remoteNotConnected` ("Not available for remote folders while the pane is not connected"). A phone never
  makes cmds start ssh.
- **The phone** (`FolderBrowserStore`, `FolderBrowserView`) asks for the pane's folder by its path when
  `PaneInfo.workingDirectory` is absolute (else without one), matches answers by `path`, and keeps the folders gone
  into per pane; at the top it starts over when the Mac pane shows another folder.
- **Older phones** never send these. **Older Macs** do not list the feature; the phone then shows the folder's path.

## Scrollback

The phone asks for the rows above a pane's screen with `requestScrollback {paneID, lines}`, only from Macs that list
`"scrollback"` (`SyncFeature.scrollback`) in `welcome.features`.

- **Relative to the viewport.** `screen` is what the pane shows on the Mac (its viewport); `scrollback` has the rows
  above it, oldest first: at most `lines` (clamped to 1…`SyncScrollback.maxLines` = 1000), fewer when the history is
  shorter. Rows are what the terminal displays, like `screen` lines: a soft-wrapped line is several rows, trailing
  spaces are trimmed.
- **Aligned by `seq`.** The Mac reads the screen and the rows back to back (up to three times while output moves the
  viewport in between), then sends a full `screen` under a new `seq` and right after it `scrollback` with that `seq`;
  later `screenDiff`s build on that screen as usual. The last row is directly above that screen's first row. Rows that
  scroll off the screen afterwards come with the screen updates to phones that stream (below); other phones ask
  again.
- **Answered late rather than never.** While output keeps moving the viewport, the Mac keeps the request and answers
  once it can read the screen and the rows together, trying again every 0.5 s while the pane stays subscribed (never
  an empty `scrollback` in its place). One request waits per pane; a newer one replaces it (its `lines` count).
- **Empty** when there is no history: the alternate screen (vim, less, other full-screen programs) has none. While the
  pane is scrolled up on the Mac, the rows are the ones above what it shows there.
- **Limits.** Subscribed terminal panes only. A request within 0.5 s of the previous answer for the same pane waits
  until 0.5 s have passed. 1000 rows of a wide pane can be about a megabyte; ask for fewer over Bluetooth.
- **Older Macs** send no `welcome.features` and answer `requestScrollback` with `error{badRequest}` (unknown type), so
  the phone does not send it to them. **Older phones** never send it and ignore `welcome.features`.

### Stream

A phone that lists `"scrollbackStream"` (`SyncFeature.scrollbackStream`) in `hello.features` gets the rows that leave
the top of the screen from Macs that list it in `welcome.features`, so the rows above the screen stay continuous
without asking again.

- **From the answer on.** Once the Mac answered `requestScrollback` for a pane, each `screen` / `screenDiff` of that
  pane to this phone may carry `scrolledOff`: the rows that left the top of the screen since the previous update sent
  to this phone, oldest first, as `scrollback` rows; append them to the rows above the screen. Each `scrolledOff` ends
  right above the screen it comes with. When only those rows changed (output scrolled rows with the same text, or an
  earlier update could not carry them), the Mac sends a full `screen` with the same lines to carry them.
- **Late, never wrong.** An update read while output moved the viewport carries none; a later one carries them all.
  Until then the rows above end above the screen's first row, with a gap but no overlap.
- **`historyReset: true`**: the rows above this screen do not continue the ones sent before. Ask again with
  `requestScrollback`; until the next answer the Mac sends no `scrolledOff` for the pane, and the phone's rows no
  longer continue the screen (the phone may keep showing them until the answer, see below). The Mac resets when
  the pane was resized (its rows were rewrapped), the scrollback was cleared (`CSI 3 J`, `clear` in some shells), the
  pane switched to the alternate screen, its viewport on the Mac moved up, or more than 1000 rows
  (`SyncScrollback.maxLines`) left the screen between two updates.
- **A full scrollback does not reset.** Once the scrollback is full, Ghostty drops its oldest page (a few hundred
  rows) as output continues; the stream carries on across that. Only when everything above the phone's last rows was
  pruned too, which takes more pruning between two updates than the whole history above them, the Mac resets.
- **Older Macs** send no `scrollbackStream` and never these fields; **older phones** do not list it, so they never get
  them (0.3.0 phones ask again as the screen scrolls).
- **The phone** (`CompanionClient`; the rows are kept by `HistoryMirror` in CmdsCore) asks once per pane and
  connection, again after `historyReset`, and repeats a request that got no answer every 3 s (10 s over Bluetooth).
  It appends `scrolledOff` in the same update as the screen, so both are drawn in one frame. It keeps 2000 rows, and
  up to 10 000 while the pane's earlier output is being read, when nothing above the rows being read is dropped or
  replaced. After a reset it keeps its rows until the answer (on a new connection only those of a pane being read):
  when the answer still has its last 24 rows, only the rows after them are added; otherwise the answer replaces them,
  while the pane is read only once reading ends.

### How the Mac reads it

cmds builds libghostty with a patch (`vendor/ghostty-patches`, applied by `scripts/build-ghostty.sh`): exact
`GHOSTTY_POINT_SCREEN` points of `ghostty_surface_read_text` reach every row of the scrollback (upstream clamps every
point to the viewport height), and `ghostty_surface_scrollbar` returns, at once, the scrollbar (rows of the whole
screen, screen row at the viewport's top, viewport rows; the scrollbar action only comes when the renderer draws, so
it stops while the pane is hidden) and the rows pruned from the top of the scrollback so far (`PageList.pruned_rows`,
counted where Ghostty prunes past the scrollback limit; clearing the history and resizes do not count). Screen rows
count from the top of the scrollback, so pruning moves every row up by the rows pruned.

- `TerminalSurface.historyRows` reads screen rows `offset − n ..< offset` one by one without moving the viewport, so
  nothing flickers on the Mac, and returns nil when the scrollbar changed meanwhile. It never reads the whole
  history, which can be megabytes and partly compressed. About 1.8 ms for 1000 rows (0.18 ms for 100) on a full
  scrollback (42 000 rows kept of 100 000 printed, M1 Debug build).
- The answer reads the scrollbar before the screen and after the rows: the same both times, or it tries again (three
  times per try, a try every 0.5 s while the request waits).
- The stream keeps, per phone and pane, a mark (`HistoryMark` in CmdsCore, used by `SyncServer+Scrollback.swift`):
  the viewport of the last screen sent with rows above it (`offset`, total, rows, pruned count, cols) and its last 4
  rows. Each screen tick reads the scrollbar right before and right after reading a marked pane's screen; when both
  agree, the mark is moved up by the rows pruned since, and an update to that phone carries screen rows
  `mark ..< offset`; then the mark moves on. Without the pruned count, a page pruned in the same tick as new output
  that made up for the total would go unnoticed (a test with a full scrollback: 6 of 8 bursts of 800 rows). The last
  4 rows are read again with the new ones as a safety net: history cannot change, so different text means it changed
  in a way the counts do not show (`historyReset`). Cost per tick: about 35 µs for the scrollbar reads, and about
  3 µs per row sent (0.33 ms for 100 rows).

## Styles

A phone that lists `"styles"` (`SyncFeature.styles`) in `hello.features` gets the colours and attributes of the screen
rows from Macs that list it in `welcome.features` (#113). Code: `CmdsCore/TerminalStyle.swift`.

- **Runs.** A row's style is a list of runs, sorted and not overlapping, only for cells that are not plain: the
  default colours and no attributes are implicit, and a plain row has no runs. A run is an array of integers
  `[column, length, attributes, fg, bg]` (`StyleRun`), trailing defaults left out: `[0,4,1]` bold, `[6,3,0,1]` palette
  red, `[0,80,16,-1,4]` inverse on palette blue.
  - `column`, `length`: cells of the phone's grid over the row's text, counted with `TerminalCells` (a wide character
    is 2). A run may reach past the end of the text (a background up to the right edge, over blank cells).
  - `attributes`: bits, 1 bold, 2 faint, 4 italic, 8 underline (any style), 16 inverse, 32 strikethrough, 64
    invisible. Unknown bits are ignored.
  - `fg`, `bg`: -1 the default colour; 0–255 a palette index (0–15 the ANSI colours, which the phone maps to its own
    palette, 16–255 the xterm cube and greys); `0x1000000 + 0xRRGGBB` an RGB colour. Other values are ignored.
    Underline colour, blink, overline and fonts are not sent.
- **`screen.styles`**: `[{row, runs}]` for the rows that have runs (`row` indexes `lines`); omitted when every row is
  plain. **`screenDiff`**: each changed row carries its `runs` (omitted: plain). A row whose runs changed is a change
  even when its text did not.
- **Size.** Only styled rows carry anything, so plain output costs nothing and a coloured prompt a few bytes; a
  full-colour TUI can add a few kilobytes per screen. The Mac reads styles only for panes a phone with the feature
  streams.
- **Rows above the screen** carry theirs the same way, indexed into their own array: `scrollback.styles` into
  `scrollback.lines`, and `scrolledOffStyles` (on `screen` / `screenDiff`) into `scrolledOff`; omitted when none of
  those rows has runs (and never without rows, e.g. with `historyReset`). The Mac reads them like the screen's rows
  (screen points, `ghostty_surface_read_text_vt`) only for phones with the feature. The phone keeps them by row number
  with the rows (`PaneHistory.runs`); an answer that continues the shown rows adds only the newer rows' runs.
- **Older Macs** send none of these fields; **older phones** do not list the feature and get exactly the plain messages
  (`ScreenSnapshot.withoutStyles`; a change of styles alone sends them nothing).
- **The Mac** reads each row of a pane streamed to such a phone with `ghostty_surface_read_text_vt` (cmds' libghostty
  patch `0002`: Ghostty's formatter in VT mode, without a palette, so colours stay palette indexes) and
  `TerminalStyledText` turns it into the row's text and runs (SGR, CUF over blank cells as spaces, ECH for cells that
  only carry a background, OSC 8 skipped). The text is the plain read's, trailing spaces aside.
- **The phone** (`TerminalGrid` in `PaneView.swift`) draws backgrounds as cells of the grid behind the text, inverse
  swaps the colours, faint dims the text, invisible text takes the background colour. Its terminal screen is always
  dark; ANSI 0–15 come from `TerminalPalette` (CmdsCore), made for it.

## Schedules

A phone that lists `"schedules"` (`SyncFeature.schedules`) in `hello.features` gets the Mac's
[schedules](../guide/schedules.md) from Macs that list it in `welcome.features` (#45 phase 3). Read only: there is no
client message for schedules, so a paired phone cannot add, change, skip or run one. Code:
`CmdsCore/Sync/SyncSchedules.swift`, `App/Sources/Sync/SyncServer+Schedules.swift`.

- **When**: right after `welcome` and `state`, and when the Mac's schedules or runs change (`ScheduleRunner.changes`),
  at most once per second (`SyncSchedules.interval`); a summary equal to the last one broadcast is not sent again.
  Always the whole list.
- **`schedules`**, in the Mac's order: `id`, `name`, `enabled`, `trigger` (as in `schedules.json`: `once {at}`,
  `weekly {weekdays, times, timeZone?}`, `limitReset {account, delay, repeats?}`, `codexLimitReset {delay, repeats?}`),
  `action` = `{type: startWorkspace | continueSession | sendText, agent?: claude | codex (continueSession),
  to?: shell | agent (sendText)}`, `nextFireAt?` (absent when the schedule is off or has no next run), `activeRun?`
  (the run in progress) and `lastRun?` (the latest ended run).
- **`runs`**: the latest runs, active ones first, then newest first, at most 30 (`SyncSchedules.maxRuns`), each a
  `ScheduleRun` as in the API (`id, scheduleID, scheduleName, cause, dueAt, startedAt, endedAt?, state, reason?,
  workspace?, pane?, account?`).
- **`readOnly: true`** when the Mac's schedule files were made by a newer cmds (shown there, never run).
- **Never sent**: prompts, commands, the text of a `sendText`, folders, workspace titles of targets, pane tags and
  session ids. `SyncScheduleAction` carries only the kind of action; `SyncSchedulesTests` checks that none of these
  reach the JSON. Account names are sent, as in `state.accountLimits`. Dates are epoch seconds.
- **Lenient**: a schedule or run the phone cannot read (a trigger type, run state or field of a newer Mac) is dropped or
  shown without that part, never the whole message; an unknown reason reads as `other`.
- **Older phones** do not list the feature and never get the message (an unknown `type` would be ignored anyway).
  **Older Macs** do not list it; the phone then hides ⋯ › Schedules.

## Mac identity

- Created on the first sync start (`SyncIdentityStore`, `App/Sources/Sync/SyncIdentity.swift`): an
  ECDSA P-256 private key generated in the login keychain (not extractable, application tag
  `tokyo.n-n.cmds.sync-identity`, label `cmds sync identity`) and a self-signed certificate built in
  Swift (`SyncCertificate`: DER encoder + `SecKeyCreateSignature`), stored next to it. The certificate
  is found again through the key's public key hash; the keychain names it after its common name.
- Fingerprint (`SyncFingerprint`) = SHA-256 of the certificate DER. Full form: unpadded base64url (QR
  code, TXT hint, phone storage). Short form for people: first 48 bits as `A1B2-C3D4-E5F6`, shown in the
  Mac's pairing window ("Mac identity") and by the phone during manual pairing.
- Creating an identity revokes every paired device (they pinned another certificate, or paired over
  plaintext v1). If the keychain cannot be read (locked, access denied), sync does not start and the
  identity is left alone; it is only replaced when it does not exist.
- **Reset Sync Identity…** (pairing window) deletes key and certificate, revokes all devices, rotates
  the code and restarts the listener with a new identity. Connected phones are told they were
  unpaired; phones that were away report "This Mac's identity changed" on their next connection.
- Isolated instances (`CMDS_SUPPORT_DIR`) use their own keychain items: label and tag get the suffix
  `test-<first 12 hex digits of SHA-256(support directory)>`, so a test never touches the identity of
  the app in use.

## Pairing

The code (6 digits, `PairingToken.generateCode()`) is accepted only while the Mac's "Pair
iPhone/iPad…" window is open; it changes every 10 minutes, after each pairing and after 5 wrong tries.
The phone always pins the Mac's fingerprint **before** it sends the code, and sends the code only on a
TLS connection whose certificate matched that pin.

1. **QR code (preferred).** The pairing window shows a QR code (CoreImage `CIQRCodeGenerator`) with
   `SyncPairingPayload.uri`:

   ```
   cmds-pair:v2?name=<Bonjour name>&host=<IPv4 or .local host>&port=<port>&fp=<SHA-256 base64url>&code=<6 digits>
   ```

   Values are percent-encoded (only RFC 3986 unreserved characters are left as they are); unknown keys
   are ignored; `name` is omitted when the Mac does not advertise. The phone scans it (VisionKit
   `DataScannerViewController`, AVFoundation on devices without DataScanner support), pins `fp`,
   connects to the Bonjour service `name` if it sees it (else `host:port`) and sends `code` in `hello`.
   The phone has no `cmds-pair:` URL handler: a pairing code is only read by the in-app scanner.
2. **Without a camera (manual host, no camera, camera denied).** The phone opens a TLS connection whose
   verify block only records the presented certificate's fingerprint and refuses the handshake
   (`SyncTLS.PeerPolicy.probe`), so nothing at all is sent. It shows the short fingerprint and asks the
   user to compare it with "Mac identity" in the Mac's pairing window. Only after "It Matches" does it
   ask for the code and connect pinned to that fingerprint. "It Doesn't Match" sends nothing and
   suggests the QR code.

On `welcome` the phone stores `{fingerprint, token}` as one Keychain item per Mac
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, service `tokyo.n-n.cmds.companion.pairing.v2`,
account `MacTarget.id`). Tokens of protocol v1 are deleted at launch and never sent again.

Later connections are pinned to the stored fingerprint and send the stored token. If the Mac presents
any other certificate, the handshake is refused before anything is written and the phone stops with
"This Mac's identity changed — re-pair": no automatic retry, no fallback to plaintext or to manual
pairing. The user re-pairs (scan the new QR code) or cancels.

## Connection flow

1. Phone connects (TLS 1.3; the verify block compares the leaf certificate's SHA-256 with the pin) and,
   once the connection is ready, sends `hello`.
2. Mac evaluates it with `PairingAuthenticator.evaluate(hello, currentCode:, knownTokens:)`:
   - valid token → `welcome` with the same token;
   - correct code → new token (`PairingToken.generate()`, 32 random bytes base64url), persist its
     SHA-256 with the device name/ID, invalidate the code → `welcome`. Re-pairing the same device ID
     revokes its previous token (sessions using it are dropped);
   - otherwise `error` (`pairingRequired` / `invalidPairingCode` / `invalidToken` /
     `unsupportedVersion` / `rateLimited`) and close.
3. Mac sends `state`. Any other message before `welcome` → `error{notAuthenticated}`.
4. Phone sends `subscribe` for visible panes; Mac keeps one `ScreenStreamer` per connection and on
   each screen tick (~10 Hz, changed panes only) sends `streamer.update(paneID:snapshot:)` if non-nil.
   On `subscribe`: `streamer.reset(paneID:)` for new panes and `retain(paneIDs:)`. On `requestScreen`:
   `streamer.fullScreen(paneID:)`. On `requestScrollback`: `streamer.full(paneID:snapshot:)`, then
   `scrollback` with its `seq`. Phones with `scrollbackStream` then get their updates of that pane with
   `withHistory(scrolledOff:reset:)` (a `streamer.full` screen when only rows above it changed; see "Scrollback").
5. Phone reconnects with exponential backoff (`SyncBackoff`, 0.5 s → 30 s, ±20 % jitter), immediately
   on returning to the foreground. Auth failures and identity mismatches do not auto-retry.

Mac-side limits: hello within 10 s; at most 16 connections and 4 unauthenticated ones per host; 1 MiB
per incoming frame, read one frame at a time; 16 KiB per `input` and 64 KiB of input per second;
32 subscribed panes; screens at most 4 per second over Bluetooth; `requestScrollback` up to 1000 rows, one answer per pane
per 0.5 s (one request waits per pane); up to 1000 `scrolledOff` rows per update (more: `historyReset`); 16 relayed SSH connections; no pairing codes over SSH; failed pairing attempts 5 per host per minute (then a 5-minute lockout) and 20 in
total per minute (then 1 minute); a client that does not read 8 MiB of output is dropped.

## API summary (CmdsCore)

- `SyncCodec`: `encode(ServerMessage) -> Data`, `decodeClientMessage(Data)`, `peekType(Data)`.
- `PairingToken`: `generateCode()`, `generate()`, `constantTimeEquals(_:_:)`, `matchesAny(_:in:)`.
- `PairingAuthenticator.evaluate(...) -> .accepted(token:isNewToken:) | .rejected(ErrorInfo)`.
- `SyncTLS`: `serverOptions(identity:)`, `clientOptions(policy:queue:onCheck:)` (`.pinned(fp)` /
  `.probe`), `evaluate(presented:policy:)`, `leafFingerprint(of:)`.
- `SyncFingerprint` (`base64url`, `short`, `hex`, `matches(_:)`), `SyncPairingPayload` (`uri`,
  `parse(_:)`), `SyncCertificate.make(...)`, `DER`.
- `ScreenStreamer` (per connection; `full(paneID:snapshot:)` for `requestScrollback`), `ScreenSnapshot` (rows, cols,
  lines, cursor); `ServerMessage.withHistory(scrolledOff:reset:)` for `scrollbackStream`.
- `ScreenDiffer.diff(from:to:)` / `apply(_:to:)` for custom use (lines, or snapshots with their styles).
- `TerminalStyledText.parse(_:)` (VT row → text and `StyleRun`s), `TerminalPalette.rgb(_:)`.
- `SyncSchedules.message(list:runs:)` (the `schedules` summary), `SyncSchedules.isWanted(by:)`, `delay(lastSentAt:)`.
- `SyncFolderReader.local()` / `.server(_:)` (`path(requested:paneFolder:)`, `listing(paneID:path:showHidden:)`,
  `file(paneID:path:)`), `SyncListing.entries(_:showHidden:…)`, `SyncListing.path(requested:paneFolder:)`.
- `SyncKey.terminalBytes(applicationCursor:)` if writing keys straight to the pty.

## Security and threat model

### Protected

- **Confidentiality and integrity on the network.** Everything after the TCP handshake is TLS 1.3
  (ECDHE, so recorded traffic cannot be decrypted later even with the Mac's key): screens, keystrokes,
  pairing codes and tokens. A passive listener on the LAN learns only metadata (see below).
- **Mac authentication.** A paired phone talks only to the certificate it pinned. Someone answering as
  the saved Bonjour name or address (spoofed mDNS, ARP/DHCP tricks, a rogue access point) fails the
  handshake before the phone writes a byte, so the token cannot be collected and fake terminal content
  cannot be shown.
- **Pairing.** The code is sent only to the pinned identity: with the QR code against the full
  256-bit fingerprint, which defeats an active man in the middle; without a camera against the
  identity the user compared. Codes are accepted only while the pairing window is open, are
  rate-limited, and change after use. A phone that is not paired never sends anything secret.
- **Tokens.** 256-bit random bearer tokens. The Mac keeps only their SHA-256
  (`sync-devices.json`, mode 0600) and compares in constant time; the phone keeps the token with its
  pin in the Keychain (this device only, not in backups that move to another device). Revoking a
  device, revoking all, re-pairing a device and resetting the identity all invalidate tokens and drop
  live sessions.

### Not protected

- **A compromised or unlocked paired phone.** The phone holds a bearer token that gives full control
  of every shell in cmds (typing into terminals), and through a files pane (`filesBrowse`) lets it list folders and
  read files of the Mac user (10 MB at a time, read only). Anyone with the unlocked phone, a malicious app able
  to read its Keychain item (jailbreak), or the token itself has that access. Revoke the device on the
  Mac ("Revoke All Devices…") if a phone is lost. There is no client certificate or per-command
  confirmation.
- **A compromised Mac account.** Malware running as the user can read terminals directly; it can also
  use the sync key in the login keychain (subject to the keychain's access control), and read the
  device list.
- **Manual pairing is only as strong as the comparison.** The short fingerprint has 48 bits. An
  attacker on the network during a manual pairing who has precomputed a certificate whose SHA-256
  starts with the same 48 bits (about 2^48 hash computations, feasible with dedicated hardware) and
  who intercepts that connection could pass the comparison, receive the code and pair with the real
  Mac in the user's place. The QR code checks all 256 bits; prefer it.
- **Seeing the pairing window.** The QR code and the code are on screen while the window is open.
  Someone who can see (or photograph) them and reach the Mac before the user can pair a device. Close
  the window after pairing; check the device list.
- **A malicious QR code.** The scanner trusts whatever `cmds-pair:` code the user points it at; a
  forged one pairs the phone with an attacker's machine, which then sees what the user types on the
  phone. Only scan the code shown by cmds on your own Mac.
- **Bluetooth.** Trust never comes from Bluetooth: the Mac is authenticated by the pinned TLS
  certificate exactly as on the network, and the TLS session is end to end through the relays. The
  L2CAP channel is not link-encrypted (no Bluetooth bond needed); it only ever carries the TLS stream. A peripheral that copies the cmds
  service and fingerprint hint can only fail the handshake (the phone then reports "identity changed"
  and stops). Per-phone limits key on the CBCentral identifier, which a hostile device can vary, like an
  address on the LAN; the global limit on failed pairing attempts still applies. On the phone, another
  app could connect to the short-lived loopback port first; it would only get the TLS byte stream to the
  Mac (no token, which is sent only by our pinned connection) and make this attempt fail.
- **Remote access via SSH.** Trust never comes from SSH: the Mac is authenticated by the pinned TLS
  certificate end to end, and the relay host only carries TLS records. A compromised relay host (or its
  root, or another user able to connect to its loopback) sees connection timing and sizes, can drop or
  delay traffic, and can reach the Mac's sync listener through the forward, where it still needs a token
  (pairing codes are refused over SSH; failed tokens are rate-limited per `ssh:<host>`, so such an
  attacker can lock out other phones using that relay for a few minutes). It cannot read or change the
  session or learn the token. A stolen phone SSH key (or relay account) gives the same reach and nothing
  more; remove its line from `authorized_keys`. A wrong relay host key is refused before login; the first
  key is trusted only after the user compared its fingerprint. The Mac's ssh trusts whatever the user's
  `known_hosts` says. Anyone on the relay host can bind the relay port first while the Mac is offline; a
  phone would then fail the pinned handshake ("identity changed"), never send its token.
- **Metadata and availability.** The Bluetooth advertisement reveals that a cmds Mac is nearby; its info
  characteristic gives the Mac name and a fingerprint prefix to anyone in range. Bonjour advertises the Mac's name and certificate fingerprint;
  connection timing and sizes are visible on the network. Anyone on the network can connect and
  attempt handshakes (bounded by the connection limits) or disrupt the network.

## Testing

Isolated instances for sync (`CMDS_SYNC_PORT`, `CMDS_SYNC_NO_BONJOUR`, `CMDS_SYNC_NO_BLUETOOTH`,
`CMDS_SYNC_TEST_PAIRING`), the relay and SSH end-to-end tests, forcing a transport on a device, the phone's
diagnostics and `cmds sync`: [testing.md](testing.md#sync-against-an-isolated-instance) and
[testing.md](testing.md#testing-sync-on-a-device).

## Versioning

`SyncProtocol.version` (= 2) is checked in `hello`. Version 2 introduced TLS with pinned Mac
certificates; version 1 (plaintext) is no longer accepted by either side and v1 pairings must be
redone. Adding optional fields or new message types is backward compatible (receivers ignore unknown
keys/types). Removing or changing fields requires a bump.
