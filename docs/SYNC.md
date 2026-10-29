# iOS companion sync protocol (v2)

The cmds Mac app streams workspaces and terminal screens to the iOS/iPadOS companion over the
local network. Code: `Packages/CmdsCore/Sources/CmdsCore/Sync/` (shared by both sides).

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
  the foreground. Opening the encrypted channel the first time triggers the system's Bluetooth pairing
  (bonding) prompt on the phone.

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
  session). The status shows in that window and in the pairing window. The pid is kept in
  `sync-remote-ssh.pid` so an ssh orphaned by a crash is ended at the next launch.
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
| `hello` | `protocolVersion:Int, deviceName:String, deviceID?:String, pairingCode?:String, token?:String, features?:[String]` | First message, sent only after the TLS handshake passed the pin check. The token saved with that pin, or the 6-digit code while pairing. `features`: optional additions the phone understands (`SyncFeature`): `"preview"` (see "Preview panes"). |
| `subscribe` | `paneIDs:[String]` | Replaces the streamed set. Mac sends a full `screen` for each new pane. `[]` stops streaming. |
| `requestScreen` | `paneID` | Ask for a full `screen` (after a diff gap). |
| `input` | `paneID, text` | Typed/pasted text, sent as-is (no newline translation). |
| `key` | `paneID, key:SyncKey` | `enter tab backtab esc backspace delete up down left right home end pageup pagedown` or `ctrl-<x>` (`ctrl-c`, `ctrl-d`, …). `SyncKey.terminalBytes(applicationCursor:)` gives xterm bytes. |
| `selectWorkspace` | `id` | Switch the Mac to that workspace. |
| `focusPane` | `id` | Focus a pane on the Mac. |
| `ping` | `nonce?:Int` | Phone pings every 10 s; reconnects if nothing received for 30 s. |
| `requestFile` | `paneID` | Optional (feature `preview`). The file shown in that preview pane. Answered with `file` pieces or `error` (`notFound`: no such pane / file missing; `badRequest`: not a preview pane, feature not announced, a request already running). Older Macs answer `error{badRequest}` (unknown type). |

## Mac → Phone (`ServerMessage`)

| type | fields | notes |
|---|---|---|
| `welcome` | `protocolVersion, macName, token` | Auth OK. Phone stores `token` together with the pinned fingerprint in the Keychain per Mac. |
| `error` | `code:SyncErrorCode, message` | Codes: `unsupportedVersion pairingRequired invalidPairingCode invalidToken rateLimited notAuthenticated badRequest notFound internal`. After auth errors (`isAuthFailure`) the Mac closes the socket. |
| `state` | `workspaces:[WorkspaceInfo], system?:SystemStats, agentLimits?:[AgentLimits]` | `agentLimits` = latest account limits per coding agent (`{agent: claude/codex/other, limits:[{id: five_hour/seven_day/spend/…, usedPercent, resetsAt? (epoch s), windowMinutes?, usedUSD?, limitUSD?, period?}], plan?, updatedAt}`), omitted when none is known or by older Macs; panes running an agent carry `PaneInfo.agent?` (`AgentUsage`, see ARCHITECTURE.md). Agent figures alone change at the same ≤ 2 s cadence as CPU/memory. Full snapshot (CmdsCore `WorkspaceInfo`/`PaneInfo`/`LayoutNode`). Sent after `welcome` and on any change; changes of CPU/memory figures alone are pushed at most every 2 s and only while a phone is connected. `WorkspaceInfo.cpuPercent?` (processes of the workspace, 100 = one core) and `memoryBytes?` (physical footprint). `system` = `{cpuPercent (0–100, all cores), memoryUsedBytes, memoryTotalBytes, memoryPressure? (1 normal, 2 warning, 4 critical)}`; absent from Macs that predate it. |
| `screen` | `paneID, seq:UInt64, rows, cols, lines:[String], cursorRow?, cursorCol?` | Full visible screen (no scrollback). Trailing spaces may be trimmed. Cursor nil = hidden. |
| `screenDiff` | `paneID, seq, baseSeq, changes:[{row,text}], cursorRow?, cursorCol?` | Only when rows/cols unchanged. Applies to the screen with `seq == baseSeq`; cursor is absolute. |
| `notification` | `paneID?, workspaceID, title, body` | Pane raised attention (agent waiting, OSC 9/777…). Phone posts a local notification. |
| `pong` | `nonce?` | Echo of `ping.nonce`. |
| `file` | `paneID, name, mime, size:Int, offset:Int, data:base64, truncated?:Bool` | Answer to `requestFile`: bytes `offset ..< offset+len(data)` of the `size`-byte file, in pieces of ≤ 2 MiB (`SyncFile.chunkBytes`, so a frame stays under 4 MiB), in order; complete when the pieces reach `size` (an empty file is one piece with `size` 0). `truncated: true` (no data): over `SyncFile.maxBytes` (10 MB) or unreadable. |

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
`SyncFileAssembler` (CmdsCore) joins the pieces; pieces out of order restart it.

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
   `streamer.fullScreen(paneID:)`.
5. Phone reconnects with exponential backoff (`SyncBackoff`, 0.5 s → 30 s, ±20 % jitter), immediately
   on returning to the foreground. Auth failures and identity mismatches do not auto-retry.

Mac-side limits: hello within 10 s; at most 16 connections and 4 unauthenticated ones per host; 1 MiB
per incoming frame, read one frame at a time; 16 KiB per `input` and 64 KiB of input per second;
32 subscribed panes; screens at most 4 per second over Bluetooth; 16 relayed SSH connections; no pairing codes over SSH; failed pairing attempts 5 per host per minute (then a 5-minute lockout) and 20 in
total per minute (then 1 minute); a client that does not read 8 MiB of output is dropped.

## API summary (CmdsCore)

- `SyncCodec`: `encode(ServerMessage) -> Data`, `decodeClientMessage(Data)`, `peekType(Data)`.
- `PairingToken`: `generateCode()`, `generate()`, `constantTimeEquals(_:_:)`, `matchesAny(_:in:)`.
- `PairingAuthenticator.evaluate(...) -> .accepted(token:isNewToken:) | .rejected(ErrorInfo)`.
- `SyncTLS`: `serverOptions(identity:)`, `clientOptions(policy:queue:onCheck:)` (`.pinned(fp)` /
  `.probe`), `evaluate(presented:policy:)`, `leafFingerprint(of:)`.
- `SyncFingerprint` (`base64url`, `short`, `hex`, `matches(_:)`), `SyncPairingPayload` (`uri`,
  `parse(_:)`), `SyncCertificate.make(...)`, `DER`.
- `ScreenStreamer` (per connection), `ScreenSnapshot` (rows, cols, lines, cursor).
- `ScreenDiffer.diff(from:to:)` / `apply(_:to:)` for custom use.
- `SyncKey.terminalBytes(applicationCursor:)` if writing keys straight to the pty.

## Security

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
  of every shell in cmds (typing into terminals). Anyone with the unlocked phone, a malicious app able
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

## Testing with an isolated instance

Never test against the cmds instance in use or the user's phone. In addition to `CMDS_SUPPORT_DIR`
(see ARCHITECTURE.md), which also selects separate keychain items for the sync identity:

- `CMDS_SYNC_PORT=<port>`: listen on this port; unlike the default port it never falls back to another.
- `CMDS_SYNC_NO_BONJOUR=1`: do not advertise, so no phone discovers the instance.
- `CMDS_SYNC_NO_BLUETOOTH=1`: no Bluetooth peripheral (no advertising, no L2CAP channel). Use it for
  every test instance that does not test Bluetooth.
- Relay test against an isolated instance: `CMDS_RELAY_E2E_PAIRING=$CMDS_SUPPORT_DIR/sync-test-pairing.txt
  swift test --filter SyncRelayTests` (in `Packages/CmdsCore`) pins the instance's certificate and pairs
  through two relays and a simulated L2CAP channel.
- `CMDS_SYNC_REMOTE_SSH_CONFIG=<file>` (isolated instances only): remote access runs `ssh -F <file>`, so
  a test never reads `~/.ssh`. Remote access E2E: `Packages/CmdsSSH/Scripts/test-relay-sshd.sh start <dir> <port>`
  starts a throwaway sshd as the current user on 127.0.0.1 (temp host keys, `authorized_keys`, client
  config with Host `cmds-test-relay` and its own known_hosts). Put `{"enabled":true,"host":"cmds-test-relay","relayPort":<relay port>}`
  in `$CMDS_SUPPORT_DIR/sync-remote.json`, start the instance with `CMDS_SYNC_REMOTE_SSH_CONFIG=<dir>/ssh_config`
  and the switches here, then in `Packages/CmdsSSH`: `CMDS_SSH_E2E_DIR=<dir> CMDS_SSH_E2E_PORT=<port>
  CMDS_SSH_E2E_PAIRING=$CMDS_SUPPORT_DIR/sync-test-pairing.txt CMDS_SSH_E2E_RELAY_PORT=<relay port> swift test`
  (host key TOFU/mismatch, unauthorized key, restricted key, pairing refused over SSH, token → welcome/state,
  wrong certificate, phone-side and Mac-side tunnel drops). `test-relay-sshd.sh stop <dir>` afterwards.
- `CMDS_SYNC_TEST_PAIRING=1` (DEBUG builds with `CMDS_SUPPORT_DIR` only): listen on 127.0.0.1 only,
  keep pairing open without the window and write the current QR payload (host 127.0.0.1) to
  `$CMDS_SUPPORT_DIR/sync-test-pairing.txt` (0600), so a local client can pair like the scanner does.

## Testing on a device

The sync paths can be checked end to end on a real iPhone without touching it: `xcrun devicectl` installs,
launches and screenshots the app over Wi‑Fi, the `CmdsDeviceDriver` UI test target taps and reads it, and
`cmds sync` shows the Mac's side. Wi‑Fi has to stay on for `devicectl`, so a debug build of the companion can
be told to use only one path. Use a device and Mac instance meant for testing, never the ones in use.

**Forcing a path (debug builds only).** Launch argument `-cmdsTransport <auto|network|bluetooth|ssh>`:
`bluetooth` connects only through `BluetoothTransport` (no LAN/AWDL attempt even though Wi‑Fi works), `ssh`
only through `SSHTransport` (remote access must be set up for that Mac), `network` never falls back. The same
choice is in the ⋯ menu (`moreMenu`) › "Transport (Debug)" (`debugTransport`) › "Transport: bluetooth"
(`transport.bluetooth`, …; the driver's `tap:` also matches the labels); it reconnects at once, wins over the launch argument for that run and is
remembered for later launches without the argument. Every mode keeps the pinned TLS check; a path that
cannot be used fails with a reason instead of falling back. Release builds ignore the argument and hide the
menu.

**Reading the phone's state.** The status badge (`connectionStatus`) carries, in debug builds, an
accessibility value like
`mode=bluetooth path=bluetooth | bluetooth: welcome` or
`mode=bluetooth path=none | bluetooth: error: Bluetooth is off. | lastError: bluetooth: Bluetooth is off.`
(release builds: the path, or the last error). Stages per path: network `connecting`; Bluetooth
`waiting for Bluetooth`, `scanning`, `found peripheral, connecting`, `connected peripheral, reading service info`,
`opening L2CAP (PSM n)`, `L2CAP open, TLS handshake`; SSH `connecting to the relay host`,
`relay login ok, opening the forward`, `forward open, TLS handshake`; then `TLS ok, hello sent` and `welcome`,
or `error: <reason>`. Debug builds also show it as a row at the bottom of the workspace list
(`syncDiagnostics`). No tokens, keys or codes appear in it.

**Mac side.** `cmds sync` (`--json` for everything; socket API `sync.status`, refused on SSH-pane sockets):

```
sync       enabled · Listening on port 47961 · identity 41F2-E114-519A · 1 paired
bonjour    on · "Mac"
bluetooth  allowed · authorization allowedAlways · manager poweredOn · advertising on · PSM 193 · 1 channel · Advertising (PSM 193)
ssh relay  off · forwarding off · Off
  ✓ iPhone  bluetooth:1a2b3c4d  bluetooth  2 panes  sent 1.2 MB  received 3.4 KB  for 1m05s
```

`authorization` is the Mac app's Bluetooth permission (`allowedAlways`, `denied`, `restricted`,
`notDetermined`); `manager` is `off` while the peripheral is not running (sync off, "Allow Bluetooth Sync"
off, `CMDS_SYNC_NO_BLUETOOTH`). A connection is `…` until its `hello` authenticated.

**Commands** (`UDID` = the test device, `$SOCK` = the Mac instance's socket):

```sh
# Build and install the debug companion and the driver once.
xcodebuild -scheme CmdsCompanion -destination id=$UDID -derivedDataPath build/dd-ios -allowProvisioningUpdates build
xcrun devicectl device install app --device $UDID build/dd-ios/Build/Products/Debug-iphoneos/CmdsCompanion.app
xcodebuild -scheme CmdsDeviceDriver -destination id=$UDID -derivedDataPath build/dd-driver -allowProvisioningUpdates build-for-testing

# Launch forced to Bluetooth (the app reconnects to its most recent Mac).
xcrun devicectl device process launch --device $UDID --terminate-existing tokyo.n-n.cmds.companion -cmdsTransport bluetooth

# Wait until it is connected over Bluetooth, then print the diagnostics.
TEST_RUNNER_CMDS_UI_SCRIPT='waitValue:connectionStatus~path=bluetooth~45;;value:syncDiagnostics' \
  xcodebuild test-without-building -xctestrun build/dd-driver/Build/Products/CmdsDeviceDriver_*.xctestrun \
  -destination id=$UDID | grep CMDS_UI_VALUE

# Or switch the running app without relaunching it.
TEST_RUNNER_CMDS_UI_SCRIPT='tap:moreMenu;;tap:debugTransport;;tap:transport.ssh;;waitValue:connectionStatus~path=ssh~45' \
  xcodebuild test-without-building -xctestrun build/dd-driver/Build/Products/CmdsDeviceDriver_*.xctestrun -destination id=$UDID

# The Mac's view of the same connection.
cmds --socket $SOCK sync --json | jq '.bluetooth, [.clients[] | {deviceName, authenticated, peer, path}]'

# Back to normal.
xcrun devicectl device process launch --device $UDID --terminate-existing tokyo.n-n.cmds.companion -cmdsTransport auto
```

The phone must already be paired with the Mac instance under test (pairing over Bluetooth works with a
scanned QR code; pairing codes are refused over SSH). For Bluetooth the instance must run without
`CMDS_SYNC_NO_BLUETOOTH`, and `cmds sync` should show `authorization allowedAlways` and `advertising on`.

## Versioning

`SyncProtocol.version` (= 2) is checked in `hello`. Version 2 introduced TLS with pinned Mac
certificates; version 1 (plaintext) is no longer accepted by either side and v1 pairings must be
redone. Adding optional fields or new message types is backward compatible (receivers ignore unknown
keys/types). Removing or changing fields requires a bump.
