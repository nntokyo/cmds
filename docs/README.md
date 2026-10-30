# cmds documentation

> Index of every document: start with the guides, look things up in the reference, read the internals before
> changing the code.

Overview, requirements and build steps: [project README](../README.md) ([日本語](../README.ja.md)).

## User guides

| Document | What it covers |
|---|---|
| [guide/getting-started.md](guide/getting-started.md) | Install, first workspace, basic moves, the `cmds` command, where data is kept |
| [guide/workspaces-and-panes.md](guide/workspaces-and-panes.md) | Workspaces and sidebar, splits, attention ring, browser and preview panes, SSH workspaces, session restore, keeping the Mac awake, language |
| [guide/iphone.md](guide/iphone.md) | The iPhone/iPad companion: pairing (QR or manual), what it shows, local network / Bluetooth / SSH relay, troubleshooting |
| [guide/ai-agents.md](guide/ai-agents.md) | Claude Code hooks and status line, the Claude skill, Codex, usage and limits, resuming sessions, moving to a new version, agents on servers |

## Reference

| Document | What it covers |
|---|---|
| [reference/cli.md](reference/cli.md) | Every `cmds` command, targeting, exit codes, export/import bundle format |
| [reference/api.md](reference/api.md) | Socket API: wire format, methods, events, types |
| [reference/shortcuts.md](reference/shortcuts.md) | Keyboard shortcuts of the Mac app |
| [reference/environment.md](reference/environment.md) | `CMDS_*` environment variables, test switches, launch arguments |

## Internals

| Document | What it covers |
|---|---|
| [internals/architecture.md](internals/architecture.md) | Repository layout, targets, key concepts, resource and agent usage, keep-awake implementation |
| [internals/sync-protocol.md](internals/sync-protocol.md) | Companion sync protocol v2: transports, messages, pairing, Mac identity, threat model |
| [internals/ssh.md](internals/ssh.md) | SSH panes: the `ssh` command, forwarded socket and its allowlist, `cmds-remote.sh`, server requirements |
| [internals/localization.md](internals/localization.md) | String Catalogs, adding strings, what stays English, Japanese style |
| [internals/testing.md](internals/testing.md) | Unit tests, isolated instances, sync and SSH end-to-end tests, device driver, UI tests, machine load |
| [internals/release.md](internals/release.md) | Versions, signing, building a release |

## Elsewhere in the repository

- [CHANGELOG.md](../CHANGELOG.md): what changed, per version.
- [integrations/claude/skills/cmds/SKILL.md](../integrations/claude/skills/cmds/SKILL.md): Claude Code skill (Japanese).
- [design/icon/README.md](../design/icon/README.md): app icon artwork and how to regenerate the icons.
- `scripts/check-links.py`: checks every relative link and anchor in the Markdown files
  (`python3 scripts/check-links.py`).
