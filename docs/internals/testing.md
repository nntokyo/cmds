# Testing

> How to test cmds without disturbing the instance and phone in use: unit tests, isolated Mac instances, sync tests,
> device and UI tests, and the limits for heavy jobs.

## Ground rules

- **Never test against the cmds instance you work in, or the phone you use.** Start an isolated instance
  ([below](#isolated-instances)) and use a test device or the simulator.
- Never type into (`cmds send`) or close panes and workspaces your test did not create: someone may be working in
  them, also from the iPhone. Create a dedicated workspace with `cmds new` and use the ids it returns.
- Stop what the test started (instances, servers, sshd, simulators) when done.

## Machine load

Builds and test runs are heavy (Swift compiler, Xcode, the iOS simulator). On a shared Mac:

- Run at most two heavy jobs (build, test, simulator) at the same time; queue the rest.
- Check `sysctl kern.memorystatus_vm_pressure_level` first (1 = normal). At 2 (warning) or 4 (critical) start
  nothing new and wait. `cmds stats` shows the same pressure.
- Prefer targeted runs (`swift test --filter …`, `-only-testing:`) over full suites.

## Unit tests

| Package | Command | Covers |
|---|---|---|
| `Packages/CmdsCore` | `swift test` (in that directory) | RPC and client, models, agent usage and Claude/Codex parsing, session resume, keep-awake, previews, resource sampling, workspace export bundles, the remote-access policy and helper script, the whole sync protocol (codec, pairing, TLS pinning, screens, relays, remote access, status) |
| `Packages/CmdsCore` | `swift test --filter CmdsCLITests` | the CLI's English output |
| `Packages/CmdsSSH` | `swift test` (in that directory; fetches swift-nio-ssh and friends on first run) | the SSH tunnel; the end-to-end part needs a throwaway sshd ([below](#remote-access-via-ssh)) |

The app targets have no unit test target; logic that needs tests lives in CmdsCore.

## Isolated instances

Start a second instance from your build:

```sh
CMDS_SUPPORT_DIR=/tmp/cmds-test CMDS_SYNC_DISABLED=1 build/dd/Build/Products/Debug/cmds.app/Contents/MacOS/cmds &
cmds --socket /tmp/cmds-test/cmds.sock ls
```

- `CMDS_SUPPORT_DIR` replaces `~/Library/Application Support/cmds` (session.json, sync-devices.json, cmds.sock) and
  wins over an inherited `CMDS_SOCKET_PATH`, so neither the instance nor a CLI given the variable can reach the
  live app. Such an instance also leaves the saved window/sidebar frames alone and does not activate itself on
  launch (it never takes keyboard focus from the app in use). Its terminals get the resolved absolute path.
- `CMDS_SYNC_DISABLED=1` skips the iOS sync server (no Bonjour advert, no port). To test sync instead, see
  [below](#sync-against-an-isolated-instance).
- Settings that live in `UserDefaults` (language, keep-awake, resume mode, compact sidebar) are kept in memory only;
  `CMDS_AGENT_RESUME` and `CMDS_SIDEBAR_COMPACT` set their initial values. The lid-close item is disabled.
- cmds › Settings… (terminal font, sidebar text size, zoom) uses its own `UserDefaults` suite
  `tokyo.n-n.cmds.isolated.<first 16 hex digits of SHA-256 of the support directory path>`, read live, so a test can
  change it from outside: `defaults write tokyo.n-n.cmds.isolated.<hash> TerminalFontSize -float 20` (keys:
  `TerminalFontFamily`, `TerminalFontSize`, `SidebarTextSize` small/medium/large, `BrowserPageZoom`,
  `PreviewPageZoom`). `defaults delete` the suite afterwards. DEBUG builds open the window with
  `cmds rpc debug.show_settings` (→ `{"window"}`, its window number for `screencapture -l`).
- Launch the binary directly; `open` does not pass the environment reliably.
- A window that is not on screen (another Space, hidden) is not drawn, so `screencapture` shows nothing. DEBUG
  builds answer `debug.preview_snapshot {pane}` → `{"png_base64"}` with a picture of a preview pane drawn off screen
  (web content via WKWebView's snapshot; Quick Look's out-of-process view stays blank).

All switches: [reference/environment.md](../reference/environment.md#app-switches-isolated-and-test-instances).

## Sync against an isolated instance

In addition to `CMDS_SUPPORT_DIR`, which also selects separate keychain items for the sync identity:

- `CMDS_SYNC_PORT=<port>`: listen on this port; unlike the default port it never falls back to another.
- `CMDS_SYNC_NO_BONJOUR=1`: do not advertise, so no phone discovers the instance.
- `CMDS_SYNC_NO_BLUETOOTH=1`: no Bluetooth peripheral (no advertising, no L2CAP channel). Use it for every test
  instance that does not test Bluetooth.
- `CMDS_SYNC_TEST_PAIRING=1` (DEBUG builds with `CMDS_SUPPORT_DIR` only): listen on 127.0.0.1 only, keep pairing open
  without the window and write the current QR payload (host 127.0.0.1) to `$CMDS_SUPPORT_DIR/sync-test-pairing.txt`
  (0600), so a local client can pair like the scanner does.
- Relay test against an isolated instance: `CMDS_RELAY_E2E_PAIRING=$CMDS_SUPPORT_DIR/sync-test-pairing.txt
  swift test --filter SyncRelayTests` (in `Packages/CmdsCore`) pins the instance's certificate and pairs through two
  relays and a simulated L2CAP channel.

### Remote access via SSH

`CMDS_SYNC_REMOTE_SSH_CONFIG=<file>` (isolated instances only) makes remote access run `ssh -F <file>`, so a test never
reads `~/.ssh`.

1. `Packages/CmdsSSH/Scripts/test-relay-sshd.sh start <dir> <port>` starts a throwaway sshd as the current user on
   127.0.0.1 (temp host keys, `authorized_keys`, client config with Host `cmds-test-relay` and its own known_hosts).
2. Put `{"enabled":true,"host":"cmds-test-relay","relayPort":<relay port>}` in `$CMDS_SUPPORT_DIR/sync-remote.json`
   and start the instance with `CMDS_SYNC_REMOTE_SSH_CONFIG=<dir>/ssh_config` and the switches above.
3. In `Packages/CmdsSSH`: `CMDS_SSH_E2E_DIR=<dir> CMDS_SSH_E2E_PORT=<port>
   CMDS_SSH_E2E_PAIRING=$CMDS_SUPPORT_DIR/sync-test-pairing.txt CMDS_SSH_E2E_RELAY_PORT=<relay port> swift test`
   (host key TOFU/mismatch, unauthorized key, restricted key, pairing refused over SSH, token → welcome/state, wrong
   certificate, phone-side and Mac-side tunnel drops).
4. `test-relay-sshd.sh stop <dir>` afterwards.

## Testing sync on a device

The sync paths can be checked end to end on a real iPhone without touching it: `xcrun devicectl` installs,
launches and screenshots the app over Wi‑Fi, the `CmdsDeviceDriver` UI test target taps and reads it, and
`cmds sync` shows the Mac's side. Wi‑Fi has to stay on for `devicectl`, so a debug build of the companion can
be told to use only one path. Use a device and Mac instance meant for testing, never the ones in use.

**Forcing a path (debug builds only).** Launch argument `-cmdsTransport <auto|network|bluetooth|ssh>`:
`bluetooth` connects only through `BluetoothTransport` (no LAN/AWDL attempt even though Wi‑Fi works), `ssh`
only through `SSHTransport` (remote access must be set up for that Mac), `network` never falls back. The same
choice is in the ⋯ menu (`moreMenu`) › "Transport (Debug)" (`debugTransport`) › "Transport: bluetooth"
(`transport.bluetooth`, …; the driver's `tap:` also matches the labels); it reconnects at once, wins over the launch
argument for that run and is remembered for later launches without the argument. Every mode keeps the pinned TLS
check; a path that cannot be used fails with a reason instead of falling back. Release builds ignore the argument and
hide the menu.

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

Screenshots: `xcrun devicectl device capture screenshot --device $UDID --destination shot.png`.

The phone must already be paired with the Mac instance under test (pairing over Bluetooth works with a
scanned QR code; pairing codes are refused over SSH). For Bluetooth the instance must run without
`CMDS_SYNC_NO_BLUETOOTH`, and `cmds sync` should show `authorization allowedAlways` and `advertising on`.

## The device driver

`iOS/UITests/DeviceDriverTests.swift` drives the already-installed, already-running companion (device or simulator)
without reinstalling or relaunching it. Steps come from `CMDS_UI_SCRIPT` (passed as `TEST_RUNNER_CMDS_UI_SCRIPT`),
separated by `;;`:

| Step | Effect |
|---|---|
| `tap:<label or identifier>` | Tap the first element with that label/identifier |
| `tapContains:<text>` | Tap the first element whose label contains the text |
| `tapText:<text>` | Tap the first static text containing the text |
| `type:<text>` | Type into the focused element (`\n` = return) |
| `wait:<seconds>` | Wait |
| `pinch:<scale>` | Pinch the terminal screen (>1 zooms in) |
| `value:<identifier>` | Print `CMDS_UI_VALUE <identifier> <accessibility value>` |
| `waitValue:<id>~<text>[~secs]` | Wait (default 30 s) until that value contains the text, else fail |
| `back` | Navigation bar back button |
| `dump` | Print the accessibility tree between `CMDS_UI_DUMP_BEGIN` / `CMDS_UI_DUMP_END` |

Elements are found by accessibility identifier (e.g. `terminalScreen`, `connectionStatus`, key bar keys such as
`left`, `esc`, `ctrlc`), never by localized text.

## UI tests in the simulator

`TerminalScreenTests` (same target) launches the companion with `-mock -noNotify -mockFullScreenTUI` and checks
rendering against the demo data; it skips itself on a real device. Run it with
`-only-testing:CmdsDeviceDriver/TerminalScreenTests` and the companion installed on the simulator. `-mock` alone
(or "Try with demo data" on the connect screen) runs the app without a Mac.

## Terminal engine harness

`GhosttyHarness.swift` builds a one-window libghostty test app when compiled with
`SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG CMDS_GHOSTTY_HARNESS'`; its `CMDS_HARNESS_*` variables are listed in
[reference/environment.md](../reference/environment.md#libghostty-harness).
