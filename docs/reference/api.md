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
| `sync.devices` | – | `[SyncPairedDevice]`: `id`, `name`, `pairedAt`, `lastSeen` (ISO 8601), `connectedFrom` (peers of open sessions); no tokens; local socket only |
| `sync.revoke` | `id` | `{revoked}`: unpairs that device and closes its sessions (`invalidToken`); the others stay paired; 404 for an unknown id; local socket only |
| `agent.report` | `pane?`, `usage` (`AgentUsage`), `pid?` (agent process), `configDir?` (Claude Code's `CLAUDE_CONFIG_DIR`, `""` = not set; names the pane's [Claude account](../guide/ai-agents.md#several-claude-accounts); dropped on SSH panes' sockets) | – (sets the pane's agent usage; its `limits` become that agent's account limits; a window at 100 % marks the pane's Claude account limited) |
| `agent.claude_hook` | `pane?`, `input` (Claude Code hook JSON, object or JSON text) | – (notifies and updates the agent state like `cmds hook claude`; never reads the transcript) |
| `agent.codex_hook` | `pane?` (a hint only), `input` (`hook_event_name`, `session_id?`, `cwd?`, `message?`, `last_assistant_message?`, as `cmds hook codex` forwards them) | – (notifies and updates the agent state of the pane running that Codex session; dropped when no pane can be told; local socket only) |
| `agent.claude_status` | `pane?`, `input` (status-line JSON) | – (like `cmds hook claude-status`, without a pid) |
| `agent.list` | – | `{"panes": [{"workspace", "pane", "usage": AgentUsage}], "limits": [AgentLimits]}` |
| `agent.subagents` | `pane?`, `workspace?` (default: all) | `SubagentList` `{"subagents": [{"id", "workspace", "pane", "agentType"?, "description"?, "state": "running"/"done", "startedAt", "endedAt"?, "action"?, "tokens"?, "elapsedSeconds"}]}`: Claude Code subagents from the `SubagentStart`/`SubagentStop` hooks (dates in seconds since 2001); local socket only |
| `agent.sessions` | `pane?` (default: all panes) | `AgentSessionList` `{"mode": "ask"/"always"/"never", "sessions": [{"workspace", "pane", "state", "session": AgentSession, "command"?}]}` |
| `agent.history` | `limit?` (default 20, all kept) | `[{"session": AgentSession, "pane"?, "state"?, "command"?}]`, newest first: the recent sessions of all panes (`pane`/`state`: the pane holding it now; [Recent sessions](../guide/ai-agents.md#recent-sessions)); local socket only |
| `agent.resume` | `pane?` or `all: true` | `{"queued": [pane], "skipped": [{"pane", "reason"}]}` (types the resume command once the pane's prompt is ready; [Resuming sessions](../guide/ai-agents.md#resuming-sessions)) |
| `account.list` | – | `ClaudeAccountList` `{"accounts": [{"name", "configDir", "exists", "limit"?: {"kind": "usageLimit"/"rateLimit", "resetsAt", "estimated", "detectedAt", "message"?}, "sessions": "shared"/"missing"/"separate"/"elsewhere"/"noConfigDir", "panes": [id]}], "autoSwitch"}` (`limit` only while active). All `account.*` methods: local socket only |
| `account.add` | `name`, `configDir` (absolute or `~/…`) | `ClaudeAccountList` |
| `account.remove` | `name` | – (the folder is left as it is; panes using the account no longer have one) |
| `account.move` | `name`, `index` (0-based, less than the number of accounts; others are refused) | – |
| `account.set` | `autoSwitch?` (bool) | `ClaudeAccountList` |
| `account.clear_limit` | `name` | – |
| `account.share` | `apply?` (default false: only the plan) | `[{"account", "projects", "action": "none"/"link"/"moveAside"/"skip", "backup"?, "reason"?}]` ([Sharing sessions](../guide/ai-agents.md#sharing-sessions-between-accounts)) |
| `account.switch` | `pane?`, `account?` (default: the next without a limit) | `{"account"}`; the switch waits for Claude Code's idle prompt; refused when the session id is unknown, not reachable from the account, or the pane is an SSH pane |
| `schedule.list` | – | `ScheduleList` `{"schedules": [{"schedule": Schedule, "nextFireAt"?, "activeRun"?: ScheduleRun, "lastRun"?: ScheduleRun, "problem"?, "targetPane"?}], "readOnly"}` (`targetPane`: the pane a `sendText` target names now) (`readOnly`: the files were written by a newer cmds or could not be read; nothing is run or saved). All `schedule.*` methods: local socket only ([Schedules](../guide/schedules.md)) |
| `schedule.add` | `schedule` (a `Schedule` without `id`, `origin`, `createdAt`, `nextFireAt`, `lastDueAt`; `enabled` and `warn` default true, `late` and `notify` default as below; a `sendText` target may be `{"pane": "p3"}`, stored as that pane's tag), `pane?` (the caller's pane, recorded as the origin) | the new entry as in `schedule.list`; `invalidParams` listing every problem (`; `-separated) |
| `schedule.update` | `id`, and any of `name`, `enabled`, `trigger`, `action`, `late`, `notify`, `warn` to replace | the entry; a new trigger or turning it on recomputes `nextFireAt` from now |
| `schedule.remove` | `id` | – (an active run is cancelled; its history is kept) |
| `schedule.run` | `id` | `{"run": ScheduleRun}` (cause `manual`; also for a schedule that is off) |
| `schedule.skip` | `id` | `{"run": ScheduleRun}` (`skipped`, reason `skippedByUser`): the next run is not made and the schedule moves on (a one-shot is turned off); `invalidParams` when it has no next run |
| `schedule.cancel` | `run` (run id) | – (nothing more is typed) |
| `schedule.history` | `id?`, `limit?` (default 20, at most 300) | `{"runs": [ScheduleRun]}`, active runs first, then newest first |
| `state.export` | – | `WorkspaceBundle` (workspaces, layout, per-pane agent sessions; [bundle format](cli.md#moving-workspaces-to-another-cmds)); local socket only |
| `state.import` | `bundle` (object or JSON text), `mode?` (`append` default / `replace`), `resume?` (`ask`/`always`/`never`, default: the app setting) | `{"workspaces": [id], "panes", "closed", "resume", "offers": [{"workspace", "pane", "agent", "sessionID", "command"?}]}`; validates the bundle first; local socket only |
| `remote.location` | `pane?`, `cwd?`, `branch?` | – (SSH panes: remote cwd/branch from `cmds-remote.sh prompt`) |
| `workspace.list` | – | `[WorkspaceInfo]` |
| `workspace.create` | `title?`, `cwd?`, `command?`, `account?` (Claude account name or `auto`) or `ssh` (host), `remoteCwd?` | `WorkspaceInfo` |
| `workspace.select` | `id` | – |
| `workspace.close` | `id` | – |
| `view.tile` | one of `off: true`, `all: true`, `workspaces` ([id], at least two); `active?` (workspace to give the keyboard); `zoom?` (bool: show the active tile alone); no params = query | `TileStatus` `{"mode": "off"/"all"/"selected", "workspaces": [id] (display order), "active"?, "zoomed"?, "hidden"}` (`hidden` = left out beyond 9), `"rows"?` ([[id]], top to bottom: only while the user's dragged arrangement is shown; `workspaces` lists the same ids in reading order). Calling with `workspaces` resets to the automatic layout. [Tiled view](../guide/workspaces-and-panes.md#tiled-view); local socket only |
| `workspace.rename` | `id`, `title` | – |
| `pane.list` | `workspace?` | `[PaneInfo]` |
| `pane.split` | `pane?` (to split from; a browser split off a terminal pane records it as its `openedBy`, as do `pane.open_file`, `files.open` and `browser.open`), `direction` (`right`/`down`), `kind?` (`terminal`/`browser`), `url?`, `cwd?`, `command?`, `focus?` (default true), `ssh?` (host), `remoteCwd?`, `account?` (local terminals) | `PaneInfo` |
| `pane.open_file` | `path` (absolute, existing file), `pane?` (to split from; a preview pane shows the file itself instead), `direction?` (`right`/`down`), `focus?` (default true), `format?` (`markdown`/`diff`/`quicklook`) | `PaneInfo` (kind `preview`); refused (403) on SSH panes' sockets |
| `files.open` | `path` (absolute, existing folder or file), `pane?` (to split from; a files pane shows the folder itself instead), `direction?` (`right`/`down`), `focus?` (default true); `host?` (an SSH host: `path` is then a folder there, absolute, `~/…`, relative to the remote home or empty, checked by the listing) | `PaneInfo` (kind `files`, `workingDirectory` = the folder, `remote` = `{host, connected}` on a host; a file's folder is listed with the file selected); refused (403) on SSH panes' sockets. [Files panes](../guide/files.md) |
| `files.compare` | `left`, `right` (absolute folders on this Mac or `HOST:PATH`), `direction?` (`leftToRight`, `rightToLeft`, `both`; default `both`), `delete?` (one-way: plan extra items for the Trash), `conflicts?` (`newer` (default), `left`, `right`, `skip`), `hidden?`, `same?` (also list identical items) | `FolderCompareInfo`. Compares off the main thread (may take a while for large or remote folders); refused on SSH panes' sockets. [Comparing and syncing](../guide/files.md#comparing-and-syncing-folders) |
| `files.sync` | as `files.compare` (without `same`) | `FolderCompareInfo` with `transfer` = the id of the queued sync (nil when there was nothing to do); compares again first. Error when the comparison stopped at the item limit |
| `transfer.list` | – | `[TransferInfo]`: the transfer queue, oldest first. All `transfer.*` methods: local socket only. [Transfers](../guide/files.md#transfers) |
| `transfer.pause` / `transfer.resume` / `transfer.cancel` / `transfer.retry` | `id` | – (`retry`: a failed or cancelled transfer; else 400) |
| `transfer.clear` | – | – (removes finished transfers) |
| `pane.reconnect` | `pane?` | – (restarts an SSH pane's `ssh`) |
| `pane.focus` | `pane` | – |
| `pane.close` | `pane`, `openedBy?` (a terminal pane: close only a pane opened from it, else an invalid-params error) | – |
| `pane.send_text` | `pane?`, `text` | – |
| `pane.read_text` | `pane?`, `scrollback?` (lines) | `{"text": ...}` |
| `notify` | `pane?`, `title?`, `body` | – |
| `sidebar.set_status` | `workspace?`, `text` | – (sets the sidebar text without ringing; `""` clears) |
| `browser.open` | `pane?` (terminal to split from), `url`, `focus?` (default true) | `PaneInfo` |
| `browser.navigate` | `pane`, `url` | – |
| `browser.eval` | `pane`, `script` | `{"value": ...}` (JSON-serializable result) |
| `browser.get_url` | `pane` | `{"url", "title"}` |
| `browser.snapshot` | `pane` | `{"png_base64"}` (with a device size: the page at that size, not scaled to the pane) |
| `browser.set_viewport` | `pane`, `device?` (a preset id, `WIDTHxHEIGHT` or `off`) or `width?` + `height?` (CSS pixels, 100–4096), `rotate?` (swap width and height), `userAgent?` (`""` = WebKit's own; without it a new size brings the preset's user agent, custom sizes and `off` WebKit's own), `colorScheme?` (`system` / `light` / `dark`) | `BrowserEmulation`; only what is given changes, no params just reads (`cmds browser device`; [guide](../guide/workspaces-and-panes.md#device-sizes-and-color-scheme)) |
| `events.subscribe` | – | `{"subscribed": true}`, then events (below) on the same connection |
| `debug.preview_snapshot` | `pane` (a preview pane) | `{"png_base64"}`; DEBUG builds only, for tests ([testing.md](../internals/testing.md#isolated-instances)) |
| `debug.show_settings` | – | `{"window"}` (window number); opens cmds › Settings…; DEBUG builds only, for tests |
| `debug.browser` | `pane` (a browser pane) | `{"indicator", "indicatorToolTip", "webViewFrame", "webViewSize", "scale", "pageZoom", "appearance", "menu", "png_base64"}`: the toolbar's width and breakpoint text, the web view's frame, the device menu's items and the pane drawn without its page; DEBUG builds only, for tests |
| `debug.schedule_clock` | `offset` (seconds) | `{"now"}`: moves the schedule runner's clock by `offset` (a simulated sleep) and checks what fell due, as after a wake; DEBUG builds only, for tests |

## Events

After `events.subscribe` the server pushes one object per line, `{"event": <name>, "params": {…}}`, until the
connection closes:

| Event | Params |
|---|---|
| `workspaces.changed` | `workspaces`: `[WorkspaceInfo]` (workspaces added, removed or reordered) |
| `workspace.changed` | `workspace` (id), `info`: `WorkspaceInfo` |
| `pane.changed` | `workspace`, `pane` (ids), `info`: `PaneInfo` |
| `notification` | `workspace`, `pane`, `title` (or `null`), `body` |
| `schedule.changed` | `id?` (one schedule added, changed or removed; absent: several). Re-read with `schedule.list` |
| `schedule.run` | `run`: `ScheduleRun` (started, moved to another state, or ended) |

CPU/memory and agent-usage updates do not produce events (they would fire every few seconds); poll `system.stats` /
`agent.list` instead. `cmds events` prints the stream.

## Types

The Swift definitions are in `Packages/CmdsCore/Sources/CmdsCore` (`Models.swift`, `AgentUsage.swift`,
`SystemStats.swift`, `KeepAwake.swift`). Unknown keys are ignored; optional fields are omitted when absent.

- `WorkspaceInfo` (also used by events and the sync protocol) = `id`, `title`, `selected`, `gitBranch?`,
  `workingDirectory?`, `ports`, `notificationText?`, `attention`, `panes` (`[PaneInfo]`), `layout?` (split tree), and
  optional `cpuPercent` (100 = one core), `memoryBytes` (physical footprint), `remoteHost` (while the focused pane is
  an SSH pane).
- `PaneInfo` = `id`, `kind` (`terminal` / `browser` / `preview` / `files`), `title`, `focused`, `attention`,
  `workingDirectory?` (files: the listed folder), `url?` (browser), `file?` (preview: absolute path), `remote?` =
  `{host, connected, branch?}` (SSH panes; files panes on a host, `connected` false until it was listed, e.g. after a
  relaunch), `agent?` (`AgentUsage`), `account?` (the Claude account the pane's Claude
  Code runs under), `openedBy?` (browser, preview and files panes split off a terminal pane named in the request: that
  terminal; kept across a relaunch).
- `TransferInfo` = `id`, `mode` (`copy`/`move`, `save`: the upload of an edited file over the server's file, with
  `sources` the edited copy, or `sync`: `sources[0]` is the left folder, `destination` the right one, with
  `direction` and `trashed`, the extra items moved to the Trash), `state` (`queued`, `running`, `paused`, `waiting`, `done`,
  `failed`, `cancelled`), `sources` and `destination` (`HOST:PATH` on SSH hosts, else paths), `itemsDone`,
  `itemsTotal`, `bytesDone`, `bytesTotal`, `current?` (the file being written), `error?` (why the whole transfer
  stopped, e.g. the connection), `asking?` (a name conflict waiting for an answer in the app), `copied`, `moved`,
  `skipped`, `failed` (counts of the log) and `failures` (`[{path, message}]`, the first 50).
- `FolderCompareInfo` = `left`, `right` (as compared; remote folders absolute), `direction`, `truncated` (the
  comparison stopped at 50 000 items and cannot be synced), `itemsRead`, `entries`, `summary` (`toRight`, `toLeft`,
  `trashLeft`, `trashRight`, `unsettled` conflicts) and `transfer?`. Each entry: `path` (relative), `status`
  (`leftOnly`, `rightOnly`, `modified`, `same`, `skipped` (a symbolic link or special file, never synced),
  `unreadable` (with `error`)), `left?` / `right?` (`kind` `file`/`folder`/`symlink`/`other`, `size?`, `modified?`
  in seconds since 1970), `newer?` (`left`/`right`), `action?` (`toRight`, `toLeft`, `trashLeft`, `trashRight`) and
  `conflict` (two-way: modified on a side, which one is not known).
- `SystemStats` = `cpuPercent` (0–100, all cores), `memoryUsedBytes`, `memoryTotalBytes`, `memoryPressure` (1 normal,
  2 warning, 4 critical; optional).
- `AgentUsage` = `agent` (`claude`/`codex`/`other`), `updatedAt`, `limits` and optional `model`, `effort`,
  `sessionID`, `contextUsedPercent`, `contextTokens`, `contextWindow`, `contextOver200k`, `costUSD`,
  `sessionDurationMs`, `apiDurationMs`, `linesAdded`, `linesRemoved`, `cacheHitRatio` (0–1), `cacheWarm`,
  `inputTokens`, `cachedInputTokens`, `outputTokens`, `reasoningTokens`, `plan`, `stale` (only when true).
- `UsageLimit` = `id` (`five_hour`, `seven_day`, `spend`, …), `usedPercent`, optional `resetsAt`, `windowMinutes`,
  `usedUSD`, `limitUSD`, `period`. `AgentLimits` = `agent`, `limits`, `plan?`, `updatedAt`.
- `Schedule` = `id` (`s` + 8 hex digits), `name`, `enabled`, `trigger`, `action`, `late`, `notify`, `warn` (the
  "starts in 1 minute" notice; absent = true), `origin`, `createdAt`, `nextFireAt?`, `lastDueAt?` (the last firing
  handled; a repeating limit trigger never fires the same reset twice). `trigger`: `{"type": "once", "at"}`,
  `{"type": "weekly", "weekdays": ["mon"…"sun"], "times": ["09:00"], "timeZone"?}` (no zone: the Mac's),
  `{"type": "limitReset", "account", "delay", "repeats"?}` (seconds, 0–3600; `repeats`: every time a limit of the
  account resets, else once), `{"type": "codexLimitReset", "delay", "repeats"?}` (Codex's limit: the latest reset of
  a window at 100 % in its session files). `action`: `{"type": "startWorkspace", "cwd", "title"?, "account"?` (name or
  `auto`), `"command"?, "prompt"?}`; `{"type": "continueSession", "agent": "claude"|"codex", "sessionID", "cwd"?,
  "account"?, "prompt", "pane"?, "paneTag"?}` (`pane`, input only: the pane to use when several hold the session,
  stored as that pane's tag `paneTag`; without it, or when that pane no longer holds the session, such a run is skipped
  with `ambiguousSession`; no `account` for Codex); or `{"type": "sendText",
  "target": {"tag"} | {"workspace"}, "text", "to": "shell"|"agent"}` (`tag`: `t` + 8 hex digits, a pane's tag kept in
  `session.json`; `workspace`: the only terminal pane of the workspace with that title). `late`:
  `{"type": "skip"}` or `{"type": "runIfWithin", "seconds"}` (default 21600 for `once`/`limitReset`, 900 for
  `weekly`). `notify`: `failures` (default), `always`, `never`. `origin`: `{"type": "app"}` or
  `{"type": "api", "pane"?}`. The same format is stored in `schedules.json`, whose `version` is 1 while it holds
  only schedules that cmds 0.6 can run, else 2 (`sendText`, Codex, `codexLimitReset`, `repeats`): a cmds that knows
  an older version opens it read only.
- `ScheduleRun` = `id` (`r` + 8 hex digits), `scheduleID`, `scheduleName`, `cause` (`scheduled`/`catchUp`/`manual`),
  `dueAt`, `startedAt`, `endedAt?`, `state` (active: `waitingForAccount`, `waitingForPane`, `typing`,
  `waitingForAgent`, `confirming`; ended: `succeeded`, `failed`, `skipped`, `missed`, `cancelled`), `reason?` (a code
  such as `confirmed`, `unconfirmed`, `commandTyped`, `otherProgram`, `agentBusy`, `paneNotFound`, `ambiguousTarget`,
  `notCodex`, `skippedByUser`, `missed`; `cmds schedule history`
  prints its English text), `workspace?`, `pane?`, `account?`.
- `BrowserEmulation` (result of `browser.set_viewport`) = `device` (preset id, kept after rotating; `null` for a
  custom size or none), `width`, `height` (CSS pixels; `null` when the page fills the pane), `userAgent` (`null` =
  WebKit's own), `colorScheme` (`system` / `light` / `dark`), `scale` (what the page is shown at, 1 when it fits).
  Presets: `iphone-se` 375×667, `iphone` 393×852, `iphone-pro-max` 440×956, `pixel` 412×915, `ipad` 820×1180,
  `ipad-landscape` 1180×820, `desktop-1280` 1280×800, `desktop-1440` 1440×900, `desktop-1920` 1920×1080
  (`cmds --json browser device --list` adds their pixel ratio and user agent; `DevicePreset` in CmdsCore).
- Dates are Unix epoch seconds (decoding also takes milliseconds and ISO 8601); unknown agent names decode as
  `other`, malformed fields are dropped instead of failing.
