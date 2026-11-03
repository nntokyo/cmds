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

GitHub Actions runs the package tests and String Catalog checks on every pull request; `scripts/ci/run-local.sh` runs
the same jobs here ([ci.md](ci.md)).

| Package | Command | Covers |
|---|---|---|
| `Packages/CmdsCore` | `swift test` (in that directory) | RPC and client, models, agent usage and Claude/Codex parsing, session resume, keep-awake, previews, resource sampling, workspace export bundles, the remote-access policy and helper script (also: `schedule.*` refused on remote sockets), schedules (`ScheduleCalendarTests`: weekly in Tokyo and New York, the DST gap and repeat, a leap day, `limitReset` following a limit, catch-up; `ScheduleRunTimingTests`: every run state, busy / asking / subagent / switch / queued resume, another session or program in the pane; `PaneReadinessTests`: the one readiness check shared with resuming and account switching; `ScheduleCodableTests` / `ScheduleValidationTests`: file format, lenient decoding, newer versions read only, moving a damaged file aside, history retention, limits), the whole sync protocol (codec, pairing, TLS pinning, screens, relays, remote access, status) |
| `Packages/CmdsCore` | `swift test --filter 'SFTP\|FileLocation\|SSHFileCommand'` | the SFTP codec and client, ssh arguments and failure classification, `HOST:PATH`, the server Trash and the transfer job and queue (in-process server, no network) |
| `Packages/CmdsCore` | `swift test --filter CmdsCLITests` | the CLI's English output, `cmds schedule` argument mapping (`ScheduleCLITests`), the `cmds mcp` server with the app API stubbed (`MCPServerTests`) |
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
  (web content via WKWebView's snapshot; Quick Look's out-of-process view stays blank), and
  `debug.files_snapshot {pane}` the same for a files pane. `debug.files {pane, action?, …}` drives a files pane
  without UI scripting and returns its folder, rows, selection, Git states and status line: `select {names}`,
  `copyToOther`, `moveToOther`, `newFolder`, `rename {name, newName}`, `paste {paths, move?}`, `hidden {on?}`,
  `follow {on?}`, `preview`, `terminal`, `back`, `forward`, `up`; `conflict` (`keepBoth`/`replace`/`skip`/`stop`)
  answers name conflicts instead of the alert. Point it only at folders the test created.

### Schedules end to end

In an isolated instance (`CMDS_SUPPORT_DIR`, `CMDS_SYNC_DISABLED=1`), with the CLI called as
`env -u CMDS_PANE_ID -u CMDS_WORKSPACE_ID -u CMDS_SOCKET_PATH CMDS_SUPPORT_DIR=… <app>/Contents/Resources/bin/cmds`:

- `cmds schedule add --name t --in 5s --start <tmp dir> -- echo scheduled-ok`, then `cmds read` on the new pane and
  `cmds schedule history` (succeeded; the selected workspace stays selected).
- A pane of a workspace the test created, with a session reported through `cmds rpc agent.claude_status` and
  `sleep 60` running: a `--continue --pane` schedule is skipped (`otherProgram`) and nothing is typed.
- Catch-up: schedules `--in 1h` (default late policy) and `--in 1h --late skip`, then
  `cmds rpc debug.schedule_clock '{"offset": 3720}'` (DEBUG builds): one catch-up run and one missed entry.
- `continueSession` with a stub `claude` script first on `PATH` (start the instance with `ZDOTDIR` pointing at a
  temporary `.zshrc` that puts it there, so the real `claude` is never run) that reports a session with
  `cmds hook claude-status` / `cmds hook claude`, and accounts whose `CLAUDE_CONFIG_DIR`s are temporary folders
  (never `~/.claude`): a running session (also waiting while the stub reports busy, and `--after-limit` with a
  status-line window at 100 %), an offered session after a relaunch (resumed, then the prompt), and a session no pane
  holds (resumed in a new workspace under the schedule's account).

- Phase 2 (#45), with a stub `codex` script first on `PATH` (via the `ZDOTDIR` `.zshrc`, with `CODEX_HOME` a
  temporary folder) that opens `$CODEX_HOME/sessions/…/rollout-…-<uuid>.jsonl` like Codex, writes `session_meta`
  and `token_count` lines, shows `• Working (Ns • esc to interrupt)` for a while, then logs what it reads:
  - `--send "echo …" --to shell --pane P` types at the empty prompt; into a pane running `sleep 60` the run is
    skipped (`otherProgram`) and nothing is typed; `--workspace TITLE` types into a one-pane workspace, and is skipped
    with `ambiguousTarget` / `paneNotFound` for a two-pane or missing one.
  - `--send … --to agent` into the stub while it shows its working line: the run waits and pastes once, 5 s after
    the line is gone.
  - `token_count` lines appended to the rollout file with `used_percent` 100 and a `resets_at` a few seconds ahead:
    `--after-codex-limit --delay 0 --continue --pane P` continues the Codex session after the reset;
    `--after-codex-limit --repeat --send …` runs once per new reset and not again for the same reset.
  - `cmds schedule skip ID`; a schedule `--in 70s` logs its notice after 10 s (`log show --info` for the instance's
    pid, category `schedule`).
  - Quit and relaunch: the tag still names the same pane (`schedule show` prints `(now pN)`); check the command ran
    on that pane's tty (`tty > file`), because `cmds read` of a restored pane currently returns the focused pane's
    screen (also on master).

Quit the instance (`cmds quit`) and delete the temporary folders afterwards.

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
- Scrollback test against an isolated instance: `CMDS_SCROLLBACK_E2E_PAIRING=$CMDS_SUPPORT_DIR/sync-test-pairing.txt
  swift test --filter SyncScrollbackTests` (in `Packages/CmdsCore`). Each test creates its own workspace through the
  instance's socket (next to that file), prints numbered rows there, pairs and checks:
  - `requestScrollback` for a phone without the stream: `welcome.features`, the full `screen` and `scrollback` under
    one `seq`, consecutive rows ending right above the screen, the 1000-row limit, a request within 0.5 s of an answer
    answered once 0.5 s have passed, the errors, and no `scrolledOff` / `historyReset`;
  - the stream (`scrollbackStream`): a script in a temporary directory prints in steps the test releases. The answer
    and every `scrolledOff` after it must form one consecutive sequence that ends right above each screen that carries
    rows (never overlapping it otherwise), through bursts of 100 rows and of 4000 rows (which may reset);
    `historyReset` after `printf '\033[3J'` while the screen's text stays the same, and no rows after it until the
    next answer; a second phone without the feature gets neither field;
  - the stream across pruning: 120 000 rows fill the scrollback (skipped when Ghostty keeps them all, e.g. with a
    raised `scrollback-limit`), then bursts of 100 and of 800 rows keep it pruning: no `historyReset`, one consecutive
    sequence; a request sent during heavy output (3.9 million rows) is answered once the rows can be read.

  It closes the workspaces when done.

### Files panes on SSH hosts

The same throwaway sshd serves SFTP, starting in `<dir>/sftp-home` (so the "home" and the server Trash of the test
stay inside `<dir>`). Never point a test at your own hosts, keys or `localhost` through `~/.ssh`.

1. `Packages/CmdsSSH/Scripts/test-relay-sshd.sh start <dir> <port>`.
2. Real ssh, no app: in `Packages/CmdsCore`, `CMDS_FILES_E2E_DIR=<dir> swift test --filter SFTPEndToEndTests`
   (connect, upload and download a folder, and the refusals: `cmds-test-unknown` with `accept-new` in its config stays
   out of its empty `known_hosts`, `cmds-test-changed` has another key pinned, `cmds-test-nokey` offers a key the server
   does not accept).
3. The app: an isolated instance started with `CMDS_FILES_SSH_CONFIG=<dir>/ssh_config`; `cmds files cmds-test-relay:`
   and `cmds files <local tmp dir>` in a workspace the test created, then `debug.files` (`select`, `copyToOther`,
   `moveToOther` from the remote pane only (a local move would put the originals in your Trash), `rename`,
   `newFolder`, `trash`, `paste {paths}`, `preview`, `reload`, `conflict`), `cmds transfers` (`pause`, `cancel`,
   `retry` on a large file), the refusals in the pane's status, and a relaunch (remote panes wait for Connect).
4. `test-relay-sshd.sh stop <dir>` and delete `<dir>`.

The rules themselves (conflicts, cancel, retry, Trash, pipelining, drops) are unit-tested without a network against
an in-process SFTP server on a temporary folder (`SFTPTransferTests`).

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
| `swipe:<down\|up>[~count]` | Swipe the terminal screen (down scrolls back into earlier output) |
| `value:<identifier>` | Print `CMDS_UI_VALUE <identifier> <accessibility value>` |
| `waitValue:<id>~<text>[~secs]` | Wait (default 30 s) until that value contains the text, else fail |
| `back` | Navigation bar back button |
| `dump` | Print the accessibility tree between `CMDS_UI_DUMP_BEGIN` / `CMDS_UI_DUMP_END` |

Elements are found by accessibility identifier (e.g. `terminalScreen`, `connectionStatus`, key bar keys such as
`left`, `esc`, `ctrlc`), never by localized text.

## The simulator companion against an isolated instance

The simulator shares the Mac's loopback, so the companion can pair with an instance started with
`CMDS_SYNC_TEST_PAIRING=1 CMDS_SYNC_NO_BONJOUR=1 CMDS_SYNC_NO_BLUETOOTH=1` (DEBUG build, own `CMDS_SUPPORT_DIR`) and
show real panes, e.g. a workspace made with `cmds new` that ran `seq 1 1500` (earlier output, #19).
`sync-test-pairing.txt` is a `cmds-pair://v2?host=…&port=…&fp=…&code=…` URI. Launch the companion with
`-noNotify -AppleLanguages '(en)' -AppleLocale en_US` (the steps below use English labels), then drive it:

1. `tap:manualHost;;type:127.0.0.1:<port>;;tap:Connect;;wait:3;;tap:Pair Without Camera;;wait:3;;dump`
2. Check the label of `pairingFingerprint` in the dump against `fp` (base64url; its first 6 bytes in hex read
   `XXXX-XXXX-XXXX`).
3. `tap:It Matches;;wait:2;;tap:pairingCode;;type:<code>` pairs at the sixth digit.

Never pick a Mac under "On This Network": that is the instance someone works in.

## UI tests in the simulator

`TerminalScreenTests` (same target) launches the companion with `-mock -noNotify` and the demo flags it needs
(`-mockFullScreenTUI`, `-mockStreamOutput`, `-mockNoHistoryStream`, `-uiTestProbes`;
[reference/environment.md](../reference/environment.md#ios-companion-launch-arguments)) and checks rendering against the
demo data: the zoomed TUI, earlier output, and earlier output that keeps up while it is read (#22: the rows on screen
must not change, compared as text and as screenshots, and the rows above the screen must have no gap). It skips itself
on a real device. Run it with `-only-testing:CmdsDeviceDriver/TerminalScreenTests` and the companion installed on the
simulator. `-mock` alone (or "Try with demo data" on the connect screen) runs the app without a Mac.

## Terminal engine harness

`GhosttyHarness.swift` builds a one-window libghostty test app when compiled with
`SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG CMDS_GHOSTTY_HARNESS'`; its `CMDS_HARNESS_*` variables are listed in
[reference/environment.md](../reference/environment.md#libghostty-harness).
