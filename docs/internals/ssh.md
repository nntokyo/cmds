# SSH panes (internals)

> How SSH panes work: the `ssh` command line, the forwarded per-pane socket and what the server may do with it,
> `cmds-remote.sh`, and server requirements.

Using them (opening, reconnecting, the remote helper, cwd/branch reporting):
[guide/workspaces-and-panes.md](../guide/workspaces-and-panes.md#ssh-workspaces).

An SSH pane runs your own `ssh` (so `~/.ssh/config`, keys, agents, jump hosts and `ControlMaster` apply) and gives
programs on the server a restricted way back to cmds: notifications, sidebar status, Claude Code usage, the pane's
cwd and branch. Nothing is installed on the server unless you ask for it.

## How it works

The pane runs (as libghostty's `bash -c "exec -l …"`):

```sh
ssh -t -o StreamLocalBindUnlink=yes -R /tmp/cmds-<96 random bits>.sock:<local pane socket> -- HOST \
  "exec env 'CMDS_SOCKET_PATH=/tmp/cmds-….sock' 'CMDS_PANE_ID=p7' 'CMDS_WORKSPACE_ID=w3' ['CMDS_REMOTE_CWD=DIR'] sh -c '<bootstrap>'"
```

- **Forwarding**: OpenSSH Unix-socket remote forwarding (`-R remote_socket:local_socket`, OpenSSH ≥ 6.7 on both ends).
  sshd creates the remote socket with `StreamLocalBindMask` (default `0177`, so mode `0600`: only the remote user and
  root can connect). Each connection uses a fresh random path: sshd leaves the socket file behind when a connection
  drops, and reusing a path would fail unless the server sets `StreamLocalBindUnlink yes` (a server option; the client
  option is harmless and only covers local forwards).
- **Environment**: the bootstrap is the remote command, not `SetEnv`/`SendEnv`, because those need `AcceptEnv` on the
  server (Debian/Ubuntu accept only `LANG LC_*`). It is one line without `'`, `\` or `!`, so whatever the remote login
  shell is (sh, bash, zsh, fish, tcsh) hands it unchanged to `sh -c`. It
  1. exports `CMDS_SOCKET_PATH` only if the socket exists and is owned by the remote user (`[ -S ] && [ -O ]`; waits
     1 s once), else unsets it and prints a one-line warning (forwarding refused by the server);
  2. sets `TERM=xterm-256color` when the server has no `xterm-ghostty` terminfo;
  3. `cd`s to the remote directory (`~` expanded);
  4. runs `"$SHELL" -l`, then removes the socket file when the shell exits.
- **Local side**: each SSH pane has its own socket, `~/Library/Application Support/cmds/ssh/<pane>.sock` (directory
  0700, socket 0600, peer uid checked like the main socket), served by an `APIServer` with a `RemoteScope`. It exists
  while the pane exists and is reused across reconnects. Local env of the `ssh` process is the usual `CMDS_*` set.

## What the server may do (enforced in the app)

`RemoteAPIPolicy` (`CmdsCore/RemoteAccess.swift`) checks every request on a pane socket:

| Allowed | Scope |
|---|---|
| `system.ping`, `system.identify` | identify returns only `version`, `build` |
| `notify`, `agent.report`, `agent.claude_hook`, `agent.claude_status`, `agent.sessions`, `agent.resume`, `remote.location`, `pane.read_text`, `pane.send_text` | `pane` forced to the SSH pane; another pane → 403 (`agent.resume` with `all: true` → 403) |
| `sidebar.set_status`, `pane.list`, `workspace.list` | `workspace` forced to the pane's workspace; results only contain that workspace and that pane (no layout) |

Everything else is refused with 403: other panes and workspaces, `workspace.create/close/select/rename`,
`pane.split/focus/close/reconnect` (a new local terminal would mean code execution on the Mac), `browser.*`,
`events.subscribe`, `system.stats`, `agent.list`, `sync.status`. `agent.report`'s `pid` is dropped (a remote pid means nothing here);
reported usage is removed when the SSH connection drops (else after 30 min without updates). `agent.claude_hook` never
reads the transcript (a remote path); `Stop` uses `last_assistant_message`.

Threat model: whoever controls the server account (or root there) can light the ring, set this workspace's sidebar
text, show fake agent usage, read this pane's screen and type into this pane — all things they could already do
through the SSH session itself. They cannot reach other panes, the browser, or start anything on the Mac.

## `cmds-remote.sh`

A POSIX sh client (`CmdsCore/RemoteHelperScript.swift`; `cmds remote-helper` prints it). Transport: `python3`, else
`socat`, else `nc -U` (OpenBSD nc gets `-N`). Commands: `notify [--title T] <text|->`, `status <text>`,
`hook claude`, `hook claude-status` (stdin JSON wrapped as `{"input": …}`; silent, always exit 0, no-op outside an SSH
pane), `prompt` (reports `$PWD` and the git branch), `ls`, `panes`, `send [--enter] <text|->`,
`read [--scrollback N]`, `ping`, `identify`, `rpc <method> [json]`. Exit codes as `cmds`: 0, 1 refused/failed, 2 usage,
3 unreachable.

**Install Remote Helper…** (Pane menu, focused SSH pane, after a confirmation) types one line into the remote shell:
`sh -c '…' <base64>` writing `~/.local/bin/cmds-remote.sh` and, if the server has no `cmds`, a `~/.local/bin/cmds`
link to it — so the hook lines from [guide/ai-agents.md](../guide/ai-agents.md#claude-code) (`command -v cmds >/dev/null && cmds hook claude || true`) work
on the server unchanged. Make sure a shell prompt is showing first. It is never done automatically.

## Server requirements

Default OpenSSH sshd settings work: `AllowStreamLocalForwarding yes` (default), `StreamLocalBindMask 0177` (default).
Forwarding is unavailable when the server sets `AllowStreamLocalForwarding no`/`local`, `DisableForwarding yes`, or the
key has `restrict`/`no-port-forwarding` in `authorized_keys`; the terminal then still works and the bootstrap prints a
warning. A `RemoteCommand` for the host in `~/.ssh/config` conflicts with the bootstrap (ssh refuses both). `/tmp` must
be writable on the server. With `ControlMaster`, the forward is set up through the master connection.
