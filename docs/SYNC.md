# iOS companion sync protocol (v1)

The cmds Mac app streams workspaces and terminal screens to the iOS/iPadOS companion over the
local network. Code: `Packages/CmdsCore/Sources/CmdsCore/Sync/` (shared by both sides).

## Transport

- WebSocket over plain TCP (Network.framework `NWProtocolWebSocket` on both sides). One JSON
  object per **text** frame, UTF-8, max 4 MiB (`SyncCodec.maxFrameBytes`). Path is ignored.
- The Mac listens with `NWListener` and advertises Bonjour `_cmds._tcp`
  (`SyncProtocol.bonjourServiceType`). TXT record (`SyncProtocol.txtRecord(macName:)`):
  `name` = Mac display name, `version` = protocol version.
- Manual entry fallback: `host[:port]`, default port `47823` (`SyncProtocol.defaultPort`).
- No TLS in v1. Traffic is LAN-only and authenticated by token; see "Security" below.

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
| `hello` | `protocolVersion:Int, deviceName:String, deviceID?:String, pairingCode?:String, token?:String` | First message. Token if stored, else the 6-digit code. |
| `subscribe` | `paneIDs:[String]` | Replaces the streamed set. Mac sends a full `screen` for each new pane. `[]` stops streaming. |
| `requestScreen` | `paneID` | Ask for a full `screen` (after a diff gap). |
| `input` | `paneID, text` | Typed/pasted text, sent as-is (no newline translation). |
| `key` | `paneID, key:SyncKey` | `enter tab backtab esc backspace delete up down left right home end pageup pagedown` or `ctrl-<x>` (`ctrl-c`, `ctrl-d`, …). `SyncKey.terminalBytes(applicationCursor:)` gives xterm bytes. |
| `selectWorkspace` | `id` | Switch the Mac to that workspace. |
| `focusPane` | `id` | Focus a pane on the Mac. |
| `ping` | `nonce?:Int` | Phone pings every 10 s; reconnects if nothing received for 30 s. |

## Mac → Phone (`ServerMessage`)

| type | fields | notes |
|---|---|---|
| `welcome` | `protocolVersion, macName, token` | Auth OK. Phone stores `token` in the Keychain per Mac. |
| `error` | `code:SyncErrorCode, message` | Codes: `unsupportedVersion pairingRequired invalidPairingCode invalidToken rateLimited notAuthenticated badRequest notFound internal`. After auth errors (`isAuthFailure`) the Mac closes the socket. |
| `state` | `workspaces:[WorkspaceInfo], system?:SystemStats` | Full snapshot (CmdsCore `WorkspaceInfo`/`PaneInfo`/`LayoutNode`). Sent after `welcome` and on any change; changes of CPU/memory figures alone are pushed at most every 2 s and only while a phone is connected. `WorkspaceInfo.cpuPercent?` (processes of the workspace, 100 = one core) and `memoryBytes?` (physical footprint). `system` = `{cpuPercent (0–100, all cores), memoryUsedBytes, memoryTotalBytes, memoryPressure? (1 normal, 2 warning, 4 critical)}`; absent from Macs that predate it. |
| `screen` | `paneID, seq:UInt64, rows, cols, lines:[String], cursorRow?, cursorCol?` | Full visible screen (no scrollback). Trailing spaces may be trimmed. Cursor nil = hidden. |
| `screenDiff` | `paneID, seq, baseSeq, changes:[{row,text}], cursorRow?, cursorCol?` | Only when rows/cols unchanged. Applies to the screen with `seq == baseSeq`; cursor is absolute. |
| `notification` | `paneID?, workspaceID, title, body` | Pane raised attention (agent waiting, OSC 9/777…). Phone posts a local notification. |
| `pong` | `nonce?` | Echo of `ping.nonce`. |

`seq` increases per pane for every `screen`/`screenDiff` and never goes backwards on a connection.
The phone (`ScreenMirror`) ignores stale messages and sends `requestScreen` when a diff's `baseSeq`
does not match.

## Connection flow

1. Phone connects, sends `hello`.
2. Mac evaluates it with `PairingAuthenticator.evaluate(hello, currentCode:, knownTokens:)`:
   - valid token → `welcome` with the same token;
   - correct code (shown on the Mac, 6 digits, `PairingToken.generateCode()`) → new token
     (`PairingToken.generate()`, 32 random bytes base64url), persist it with the device name/ID,
     invalidate the code → `welcome`;
   - otherwise `error` (`pairingRequired` / `invalidPairingCode` / `invalidToken` /
     `unsupportedVersion`) and close. The Mac should rate-limit code attempts (e.g. 5 per code,
     then `rateLimited` and a new code).
3. Mac sends `state`. Any other message before `welcome` → `error{notAuthenticated}`.
4. Phone sends `subscribe` for visible panes; Mac keeps one `ScreenStreamer` per connection and on
   each screen tick (~10 Hz, changed panes only) sends `streamer.update(paneID:snapshot:)` if non-nil.
   On `subscribe`: `streamer.reset(paneID:)` for new panes and `retain(paneIDs:)`. On `requestScreen`:
   `streamer.fullScreen(paneID:)`.
5. Phone reconnects with exponential backoff (`SyncBackoff`, 0.5 s → 30 s, ±20 % jitter), immediately
   on returning to the foreground. Auth failures do not auto-retry.

## Mac-side API summary (CmdsCore)

- `SyncCodec`: `encode(ServerMessage) -> Data`, `decodeClientMessage(Data)`, `peekType(Data)`.
- `PairingToken`: `generateCode()`, `generate()`, `constantTimeEquals(_:_:)`, `matchesAny(_:in:)`.
- `PairingAuthenticator.evaluate(...) -> .accepted(token:isNewToken:) | .rejected(ErrorInfo)`.
- `ScreenStreamer` (per connection), `ScreenSnapshot` (rows, cols, lines, cursor).
- `ScreenDiffer.diff(from:to:)` / `apply(_:to:)` for custom use.
- `SyncKey.terminalBytes(applicationCursor:)` if writing keys straight to the pty.

## Security

- Tokens are bearer secrets: store them in the Keychain (Mac) and compare in constant time.
  Revoking a device = deleting its token.
- v1 is unencrypted on the LAN; anyone on the network can read the stream and replay a sniffed token.
  Planned v2: TLS with a pre-shared key derived at pairing time (`NWProtocolTLS` PSK), or a pinned
  self-signed certificate whose fingerprint is shown with the pairing code.

## Versioning

`SyncProtocol.version` (= 1) is checked in `hello`. Adding optional fields or new message types is
backward compatible (receivers ignore unknown keys/types). Removing or changing fields requires a bump.
