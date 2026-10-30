# Socket API

> The JSON-lines API on the app's Unix socket: wire format, every method, the event stream and the shared types.

The `cmds` CLI ([cli.md](cli.md)) is a thin client of this API; use `cmds rpc <method> [json]` to call any method by
hand. Server: `App/Sources/API/APIServer.swift`; wire types: `Packages/CmdsCore/Sources/CmdsCore/RPC.swift`.

## Socket

- Path: `~/Library/Application Support/cmds/cmds.sock` (mode 0600), or `$CMDS_SUPPORT_DIR/cmds.sock` for an isolated
  instance ([environment.md](environment.md)).
- Only processes of the same user may connect (the peer uid is checked).
- SSH panes get their own restricted socket per pane, which is forwarded to the server; it accepts only an allowlist
  of methods pinned to that pane ([internals/ssh.md](../internals/ssh.md#what-the-server-may-do-enforced-in-the-app)).

## Wire format

One JSON object per line, in both directions. Lines are capped at 8 MB.

```
→ {"id":1,"method":"workspace.list"}
← {"id":1,"result":[…]}
→ {"id":2,"method":"pane.focus","params":{"pane":"p9"}}
← {"id":2,"error":{"code":404,"message":"pane not found: p9"}}
```

- Responses carry the request `id` and either `result` or `error {code, message}`. Methods without a result return
  `{}`.
- Error codes: `-32700` / `-32600` malformed line (answered with `id: 0`), `-32601` unknown method, `-32602` invalid
  params, `403` refused (restricted sockets), `404` no such workspace/pane, `500` anything else (e.g. a JavaScript
  exception in `browser.eval`).
- Requests are handled on the main actor in arrival order; `browser.eval` / `browser.snapshot` reply when done
  without blocking other requests.

## Targeting defaults

- `pane?` / `workspace?` default to `CMDS_PANE_ID` / `CMDS_WORKSPACE_ID` (the CLI sends them as explicit params when
  it runs inside a cmds terminal), else the focused pane / selected workspace.
- `browser.*` without `pane` use the focused (else first) browser pane of `workspace?` (default: selected).

## Methods

| Method | Params | Result |
|---|---|---|
| `system.ping` | – | `{"pong": true}` |
| `system.identify` | – | `{"version", "build", "pid", "socketPath", "cliPath"}` |
| `system.stats` | – | `{"system": SystemStats, "workspaces": [{"id", "cpuPercent", "memoryBytes"}], "agentLimits"?: [AgentLimits], "keepAwake": KeepAwakeStatus}` (`system` is omitted until two samples exist, ~1 s after launch; workspace fields until sampled or without processes; `agentLimits` while any is known; `keepAwake` = `idleAssertion`, `displayAssertion`, `lidCloseDisabled` (system `SleepDisabled`), `lidCloseByCmds`, `lidCloseAvailable`, `onBattery`, see [Keeping the Mac awake](../internals/architecture.md#keeping-the-mac-awake)) |
| `sync.status` | – | `SyncStatusReport` (iOS sync: `enabled`, `state`, `port`, `fingerprint`, `bonjour`, `pairingWindowOpen`, `pairedDevices`, `bluetooth` {`allowed`, `disabledByEnvironment`, `authorization`, `managerState`, `advertising`, `psm`, `channels`, `status`}, `remote` {`enabled`, `host`, `relayPort`, `forwarding`, `status`}, `clients` [{`deviceName`, `authenticated`, `peer`, `path`, `subscribedPanes`, `bytesSent`, `bytesReceived`, `connectedSince`, `connectedSeconds`}]); local socket only, see [Testing on a device](../internals/testing.md#testing-sync-on-a-device) |
| `agent.report` | `pane?`, `usage` (`AgentUsage`), `pid?` (agent process) | – (sets the pane's agent usage; its `limits` become that agent's account limits) |
| `agent.claude_hook` | `pane?`, `input` (Claude Code hook JSON, object or JSON text) | – (notifies and updates the agent state like `cmds hook claude`; never reads the transcript) |
| `agent.claude_status` | `pane?`, `input` (status-line JSON) | – (like `cmds hook claude-status`, without a pid) |
| `agent.list` | – | `{"panes": [{"workspace", "pane", "usage": AgentUsage}], "limits": [AgentLimits]}` |
| `agent.sessions` | `pane?` (default: all panes) | `AgentSessionList` `{"mode": "ask"/"always"/"never", "sessions": [{"workspace", "pane", "state", "session": AgentSession, "command"?}]}` |
| `agent.resume` | `pane?` or `all: true` | `{"queued": [pane], "skipped": [{"pane", "reason"}]}` (types the resume command once the pane's prompt is ready; [Resuming sessions](../guide/ai-agents.md#resuming-sessions)) |
| `state.export` | – | `WorkspaceBundle` (workspaces, layout, per-pane agent sessions; [bundle format](cli.md#moving-workspaces-to-another-cmds)); local socket only |
| `state.import` | `bundle` (object or JSON text), `mode?` (`append` default / `replace`), `resume?` (`ask`/`always`/`never`, default: the app setting) | `{"workspaces": [id], "panes", "closed", "resume", "offers": [{"workspace", "pane", "agent", "sessionID", "command"?}]}`; validates the bundle first; local socket only |
| `remote.location` | `pane?`, `cwd?`, `branch?` | – (SSH panes: remote cwd/branch from `cmds-remote.sh prompt`) |
| `workspace.list` | – | `[WorkspaceInfo]` |
| `workspace.create` | `title?`, `cwd?`, `command?` or `ssh` (host), `remoteCwd?` | `WorkspaceInfo` |
| `workspace.select` | `id` | – |
| `workspace.close` | `id` | – |
| `view.tile` | one of `off: true`, `all: true`, `workspaces` ([id], at least two); `active?` (workspace to give the keyboard); `zoom?` (bool: show the active tile alone); no params = query | `TileStatus` `{"mode": "off"/"all"/"selected", "workspaces": [id] (display order), "active"?, "zoomed"?, "hidden"}` (`hidden` = left out beyond 9), `"rows"?` ([[id]], top to bottom: only while the user's dragged arrangement is shown; `workspaces` lists the same ids in reading order). Calling with `workspaces` resets to the automatic layout. [Tiled view](../guide/workspaces-and-panes.md#tiled-view); local socket only |
| `workspace.rename` | `id`, `title` | – |
| `pane.list` | `workspace?` | `[PaneInfo]` |
| `pane.split` | `pane?`, `direction` (`right`/`down`), `kind?` (`terminal`/`browser`), `url?`, `cwd?`, `command?`, `focus?` (default true), `ssh?` (host), `remoteCwd?` | `PaneInfo` |
| `pane.open_file` | `path` (absolute, existing file), `pane?` (to split from; a preview pane shows the file itself instead), `direction?` (`right`/`down`), `focus?` (default true), `format?` (`markdown`/`diff`/`quicklook`) | `PaneInfo` (kind `preview`); refused (403) on SSH panes' sockets |
| `pane.reconnect` | `pane?` | – (restarts an SSH pane's `ssh`) |
| `pane.focus` | `pane` | – |
| `pane.close` | `pane` | – |
| `pane.send_text` | `pane?`, `text` | – |
| `pane.read_text` | `pane?`, `scrollback?` (lines) | `{"text": ...}` |
| `notify` | `pane?`, `title?`, `body` | – |
| `sidebar.set_status` | `workspace?`, `text` | – (sets the sidebar text without ringing; `""` clears) |
| `browser.open` | `pane?` (terminal to split from), `url`, `focus?` (default true) | `PaneInfo` |
| `browser.navigate` | `pane`, `url` | – |
| `browser.eval` | `pane`, `script` | `{"value": ...}` (JSON-serializable result) |
| `browser.get_url` | `pane` | `{"url", "title"}` |
| `browser.snapshot` | `pane` | `{"png_base64"}` |
| `events.subscribe` | – | `{"subscribed": true}`, then events (below) on the same connection |
| `debug.preview_snapshot` | `pane` (a preview pane) | `{"png_base64"}`; DEBUG builds only, for tests ([testing.md](../internals/testing.md#isolated-instances)) |
| `debug.show_settings` | – | `{"window"}` (window number); opens cmds › Settings…; DEBUG builds only, for tests |

## Events

After `events.subscribe` the server pushes one object per line, `{"event": <name>, "params": {…}}`, until the
connection closes:

| Event | Params |
|---|---|
| `workspaces.changed` | `workspaces`: `[WorkspaceInfo]` (workspaces added, removed or reordered) |
| `workspace.changed` | `workspace` (id), `info`: `WorkspaceInfo` |
| `pane.changed` | `workspace`, `pane` (ids), `info`: `PaneInfo` |
| `notification` | `workspace`, `pane`, `title` (or `null`), `body` |

CPU/memory and agent-usage updates do not produce events (they would fire every few seconds); poll `system.stats` /
`agent.list` instead. `cmds events` prints the stream.

## Types

The Swift definitions are in `Packages/CmdsCore/Sources/CmdsCore` (`Models.swift`, `AgentUsage.swift`,
`SystemStats.swift`, `KeepAwake.swift`). Unknown keys are ignored; optional fields are omitted when absent.

- `WorkspaceInfo` (also used by events and the sync protocol) = `id`, `title`, `selected`, `gitBranch?`,
  `workingDirectory?`, `ports`, `notificationText?`, `attention`, `panes` (`[PaneInfo]`), `layout?` (split tree), and
  optional `cpuPercent` (100 = one core), `memoryBytes` (physical footprint), `remoteHost` (while the focused pane is
  an SSH pane).
- `PaneInfo` = `id`, `kind` (`terminal` / `browser` / `preview`), `title`, `focused`, `attention`,
  `workingDirectory?`, `url?` (browser), `file?` (preview: absolute path), `remote?` = `{host, connected, branch?}`
  (SSH panes), `agent?` (`AgentUsage`).
- `SystemStats` = `cpuPercent` (0–100, all cores), `memoryUsedBytes`, `memoryTotalBytes`, `memoryPressure` (1 normal,
  2 warning, 4 critical; optional).
- `AgentUsage` = `agent` (`claude`/`codex`/`other`), `updatedAt`, `limits` and optional `model`, `effort`,
  `sessionID`, `contextUsedPercent`, `contextTokens`, `contextWindow`, `contextOver200k`, `costUSD`,
  `sessionDurationMs`, `apiDurationMs`, `linesAdded`, `linesRemoved`, `cacheHitRatio` (0–1), `cacheWarm`,
  `inputTokens`, `cachedInputTokens`, `outputTokens`, `reasoningTokens`, `plan`, `stale` (only when true).
- `UsageLimit` = `id` (`five_hour`, `seven_day`, `spend`, …), `usedPercent`, optional `resetsAt`, `windowMinutes`,
  `usedUSD`, `limitUSD`, `period`. `AgentLimits` = `agent`, `limits`, `plan?`, `updatedAt`.
- Dates are Unix epoch seconds (decoding also takes milliseconds and ISO 8601); unknown agent names decode as
  `other`, malformed fields are dropped instead of failing.
