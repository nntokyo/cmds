# Versioning, signing and release builds

> How versions are numbered, how the apps are signed, and how to produce a build to install — as things stand today
> (no automated release pipeline, no App Store or TestFlight distribution).

## Versions

| What | Where | Current |
|---|---|---|
| App version (`CFBundleShortVersionString`) | `MARKETING_VERSION` in `project.yml`, shared by the Mac app and the companion | 0.1.0 |
| Build number (`CFBundleVersion`) | `CURRENT_PROJECT_VERSION` in `project.yml` | 1 |
| Sync protocol | `SyncProtocol.version` (`CmdsCore/Sync/SyncProtocol.swift`); checked in `hello`, both sides must match ([sync-protocol.md](sync-protocol.md#versioning)) | 2 |
| `cmds-remote.sh` | `CMDS_REMOTE_VERSION` in `CmdsCore/RemoteHelperScript.swift` | 1 |
| Workspace export bundle | `WorkspaceBundle.currentVersion` (`CmdsCore/WorkspaceTransfer.swift`); newer bundles are refused | 1 |

`cmds identify` (`system.identify`) reports the running app's version and build. Changes are recorded in
[CHANGELOG.md](../../CHANGELOG.md) (Keep a Changelog). There are no git tags yet; tag releases as `vX.Y.Z` when the
first one is cut.

Compatibility rules worth keeping:

- Sync: adding optional fields or message types is backward compatible (receivers ignore unknown keys/types and
  older phones get preview panes as browser panes); removing or changing fields requires a protocol version bump,
  which forces every phone to update.
- Socket API and CLI output are consumed by scripts and agents; keep methods and `--json` shapes stable, add instead
  of changing. A newer CLI talks to an older app where it can (`cmds export --legacy`).
- `session.json` must keep decoding sessions written by older builds (new fields are optional).

## Signing

| Target | Identity | Notes |
|---|---|---|
| `cmds` (Mac app) | Apple Development, team `LY354RVYHA` (N.N. LLC) | Hardened runtime off. A stable identity keeps the firewall allowance and notification permission across rebuilds. |
| `cmds-cli` | Ad-hoc (`-`), re-signed when embedded | Copied into `cmds.app/Contents/Resources/bin`. |
| `CmdsCompanion`, `CmdsDeviceDriver` (iOS) | Automatic signing, team `LY354RVYHA` | Development provisioning only. |

To build with your own Apple account, change `DEVELOPMENT_TEAM` for the three targets in `project.yml` (or pass
`DEVELOPMENT_TEAM=<your team>` to `xcodebuild`) and regenerate the project. The iOS bundle identifiers
(`tokyo.n-n.cmds.companion`, `tokyo.n-n.cmds.devicedriver`) belong to that team; with another team you may also need
your own identifiers.

The Mac app is not notarized and not signed with a Developer ID, so it is meant for your own Macs. Distributing it
to others would need a Developer ID certificate, the hardened runtime (currently off) and notarization; none of that
is set up or tested.

## Building a release

1. Start from a clean, up-to-date `master` with the submodule at the committed revision
   (`git submodule update --init`), and rebuild GhosttyKit if the submodule moved (README, "Build from source").
2. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`, move the `Unreleased` entries in
   `CHANGELOG.md` under the new version, then `xcodegen generate`.
3. Run the unit tests ([testing.md](testing.md#unit-tests)).
4. Build the Mac app with the Release configuration:

   ```sh
   xcodebuild -scheme CmdsApp -configuration Release -derivedDataPath build/dd-release build
   ```

   The app is `build/dd-release/Build/Products/Release/cmds.app`. A build phase copies Ghostty's resources
   (`terminfo`, shell integration) from `vendor/ghostty/zig-out/share` into the bundle, so the GhosttyKit build must
   have run.
5. Install it by copying the app to the same place as before (keeps the firewall allowance), quit the old instance and
   start the new one. To keep the workspaces and agent sessions of a running instance, export them first
   ([guide/ai-agents.md](../guide/ai-agents.md#moving-to-a-new-version)).
6. iOS: build the `CmdsCompanion` scheme for the device and install it with Xcode or `xcrun devicectl device install
   app` ([testing.md](testing.md#testing-sync-on-a-device)).
7. Commit the version bump and tag it `vX.Y.Z`.

The Release configuration has not been exercised as much as Debug: check the built app (terminal, browser, preview,
sync) before replacing the instance you work in.
