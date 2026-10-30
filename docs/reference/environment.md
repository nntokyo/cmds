# Environment variables and launch arguments

> Every `CMDS_*` variable cmds sets or reads, plus the test switches and launch arguments of both apps.

Names are defined in `CmdsEnv` (`Packages/CmdsCore/Sources/CmdsCore/RPC.swift`) unless noted.

## Set by cmds in every terminal

| Variable | Value |
|---|---|
| `CMDS_SOCKET_PATH` | Absolute path of the app's API socket ([api.md](api.md#socket)). |
| `CMDS_WORKSPACE_ID` | Id of the pane's workspace (`w1`, …). |
| `CMDS_PANE_ID` | Id of the pane itself (`p1`, …). The CLI sends it so commands act on *this* pane even when another one is focused. Ids are reassigned when cmds restarts. |
| `CMDS_SUPPORT_DIR` | Only in terminals of an isolated instance: the resolved absolute support directory, so the CLI there talks to that instance. |
| `PATH` | The bundled CLI's directory (`cmds.app/Contents/Resources/bin`) is added, so `cmds` is on `PATH`. |
| `TERM`, `TERM_PROGRAM` | `xterm-ghostty`, `ghostty` (set by libghostty): programs treat the pane like Ghostty. |

## Set on the server in SSH panes

Exported by the bootstrap command of an SSH pane ([internals/ssh.md](../internals/ssh.md#how-it-works)).

| Variable | Value |
|---|---|
| `CMDS_SOCKET_PATH` | The forwarded socket on the server (`/tmp/cmds-<random>.sock`). Unset, with a warning, when the server refused the forward. |
| `CMDS_PANE_ID`, `CMDS_WORKSPACE_ID` | Ids of the SSH pane and its workspace. |
| `CMDS_REMOTE_CWD` | Directory to start in; consumed and unset by the bootstrap. |
| `TERM` | `xterm-256color` when the server has no `xterm-ghostty` terminfo. |

`cmds-remote.sh` also reads `CMDS_TRANSPORT` (`python3`, `socat` or `nc`) to force how it talks to the socket;
by default it uses the first of those that exists.

## Read by the `cmds` CLI

Socket resolution, first match wins: `--socket PATH`, then `$CMDS_SUPPORT_DIR/cmds.sock`, then `$CMDS_SOCKET_PATH`,
then `~/Library/Application Support/cmds/cmds.sock`. `CMDS_PANE_ID` / `CMDS_WORKSPACE_ID` are the default targets
([cli.md](cli.md#targeting)).

## App switches (isolated and test instances)

Launch the binary directly (`build/dd/Build/Products/Debug/cmds.app/Contents/MacOS/cmds`); `open` does not pass the
environment reliably. How to use them together: [internals/testing.md](../internals/testing.md#isolated-instances).

| Variable | Effect |
|---|---|
| `CMDS_SUPPORT_DIR=<dir>` | Replaces `~/Library/Application Support/cmds` (`session.json`, `sync-devices.json`, `cmds.sock`, sync settings) and wins over an inherited `CMDS_SOCKET_PATH`. The instance also uses its own keychain items for the sync identity, keeps settings (language, keep-awake, resume mode, compact sidebar) in memory, leaves the saved window frames alone, never activates itself on launch and never runs `pmset` with privileges. |
| `CMDS_SYNC_DISABLED=1` | Do not start the iOS sync server (no Bonjour advert, no port, no Bluetooth). |
| `CMDS_SYNC_PORT=<port>` | Sync listen port instead of `47823`; unlike the default it never falls back to another port when taken. |
| `CMDS_SYNC_NO_BONJOUR=1` | Run the sync server without the Bonjour advert, so no phone discovers the instance. |
| `CMDS_SYNC_NO_BLUETOOTH=1` | No Bluetooth peripheral (no advertising, no L2CAP channel). Use it for every test instance that does not test Bluetooth. |
| `CMDS_SYNC_REMOTE_SSH_CONFIG=<file>` | Isolated instances only: remote access via SSH runs `ssh -F <file>`, so a test never reads `~/.ssh`. |
| `CMDS_SYNC_TEST_PAIRING=1` | DEBUG builds with `CMDS_SUPPORT_DIR` only: listen on 127.0.0.1 only, keep pairing open without the window and write the pairing QR payload to `$CMDS_SUPPORT_DIR/sync-test-pairing.txt` (0600). |
| `CMDS_SIDEBAR_COMPACT=1` | Isolated instances only (they never read the saved setting): start with the compact sidebar. |
| `CMDS_AGENT_RESUME=ask\|always\|never` | Isolated instances only: initial "Resume Agent Sessions on Launch" mode (default `ask`). |

Mac launch argument: `-AppleLanguages '(ja)'` or `'(en)'` starts the app in that language
([internals/localization.md](../internals/localization.md#choosing-the-language)).

## Test suites

| Variable | Used by |
|---|---|
| `CMDS_RELAY_E2E_PAIRING=<file>` | `SyncRelayTests` (CmdsCore): pairs through the Bluetooth relay against an isolated instance started with `CMDS_SYNC_TEST_PAIRING=1`. |
| `CMDS_SSH_E2E_DIR`, `CMDS_SSH_E2E_PORT`, `CMDS_SSH_E2E_PAIRING`, `CMDS_SSH_E2E_RELAY_PORT` | `SSHTunnelTests` (CmdsSSH): end-to-end remote access through a throwaway sshd. |
| `CMDS_UI_SCRIPT` | `DeviceDriverTests` (iOS UI test target `CmdsDeviceDriver`); pass it to `xcodebuild` as `TEST_RUNNER_CMDS_UI_SCRIPT=…`. Output lines start with `CMDS_UI_STEP`, `CMDS_UI_VALUE`, `CMDS_UI_DUMP_BEGIN` / `CMDS_UI_DUMP_END`. |

Details for all three: [internals/testing.md](../internals/testing.md).

## libghostty harness

`App/Sources/Terminal/Ghostty/GhosttyHarness.swift` is compiled only with
`SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG CMDS_GHOSTTY_HARNESS'`: one window with one terminal surface for testing
the engine. `CMDS_HARNESS_SEND` (or `CMDS_HARNESS_SEND_FILE`) sends text after 1.5 s, `CMDS_HARNESS_TYPE_FILE` types
a file's text after 2.5 s (`\e \n \r \t \xNN` decoded), `CMDS_HARNESS_ACTION` (e.g. `scroll_page_lines:-2`) runs a
libghostty binding action after 3 s, `CMDS_HARNESS_DUMP=<path>` writes the cursor position and visible lines after
3.5 s.

## iOS companion launch arguments

| Argument | Effect |
|---|---|
| `-mock` | Run against built-in demo data (no Mac needed; also "Try with demo data" on the connect screen). |
| `-mockFullScreenTUI` | With `-mock`: the Claude pane shows a large full-screen TUI (used by `TerminalScreenTests`). |
| `-noNotify` | Do not post local notifications. |
| `-cmdsTransport auto\|network\|bluetooth\|ssh` | Debug builds only: force one connection path ([internals/testing.md](../internals/testing.md#testing-sync-on-a-device)). |
