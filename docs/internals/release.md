# Versioning, signing and release builds

> How versions are numbered, how the apps are signed (hardened runtime, entitlements), and how to cut a release:
> signed and notarized DMG, website, GitHub release; iOS distribution is not set up yet.

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

| Target | Debug | Release |
|---|---|---|
| `cmds` (Mac app) | Apple Development, team `LY354RVYHA` (N.N. LLC), hardened runtime off | Hardened runtime on, entitlements `App/cmds.entitlements`; Xcode signs with Apple Development, `scripts/release/build-dmg.sh` re-signs with Developer ID |
| `cmds-cli` | Ad-hoc (`-`), re-signed when embedded | Hardened runtime on; re-signed with Developer ID inside the app |
| `CmdsCompanion`, `CmdsDeviceDriver` (iOS) | Automatic signing, team `LY354RVYHA` | Development provisioning only (no App Store distribution yet) |

A stable identity keeps the firewall allowance and notification permission across rebuilds. To build with your own
Apple account, change `DEVELOPMENT_TEAM` for the three targets in `project.yml` (or pass `DEVELOPMENT_TEAM=<your
team>` to `xcodebuild`) and regenerate the project. The iOS bundle identifiers (`tokyo.n-n.cmds.companion`,
`tokyo.n-n.cmds.devicedriver`) belong to that team; with another team you may also need your own identifiers.

### Hardened runtime and entitlements

Notarization requires the hardened runtime. The Release configuration turns it on for the app and the CLI, and the
app carries `App/cmds.entitlements` in every configuration (without the hardened runtime, Debug builds ignore them).
cmds is not sandboxed. Tested with an isolated Release instance (hardened runtime, then re-signed by
`build-dmg.sh`): terminals render (libghostty/Metal, bundled terminfo), browser panes (WKWebView), Markdown/diff
previews, SSH panes, the CLI socket, agent hooks and the tiled view all work.

| Entitlement | Why |
|---|---|
| `com.apple.security.automation.apple-events` | `NSAppleScript` "with administrator privileges" (Install Command Line Tool…, Keep Awake With Lid Closed), and `osascript` / Apple Events sent by programs in a terminal (macOS attributes them to cmds) |
| `com.apple.security.device.audio-input`, `…device.camera` | Programs in a terminal that record audio or use the camera; without them the hardened runtime refuses them before macOS can ask |
| `com.apple.security.personal-information.addressbook`, `…calendars`, `…location`, `…photos-library` | Same for terminal programs that read Contacts, Calendars, Location or Photos (each still asks the user) |

The set matches Ghostty.app's release entitlements; `project.yml` adds the matching usage strings
(`NSAppleEventsUsageDescription`, `NSMicrophoneUsageDescription`, … in `App/Resources/InfoPlist.xcstrings`).
Deliberately absent: `cs.allow-jit` / `cs.allow-unsigned-executable-memory` (libghostty has no JIT; WebKit's JIT runs
in its own WebContent process), `cs.disable-library-validation` (GhosttyKit is linked statically, no plug-ins),
`get-task-allow` (notarization rejects it; Xcode adds it to Apple Development builds, `build-dmg.sh` drops it), and
the sandbox keys for network and Bluetooth (not sandboxed: the `NSLocalNetworkUsageDescription`,
`NSBonjourServices` and `NSBluetoothAlwaysUsageDescription` strings are what macOS needs).

Not exercised under the hardened runtime yet: the administrator dialogs (Install Command Line Tool…, lid-closed
keep-awake), iOS sync over the network and Bluetooth (test instances run with sync disabled), and macOS
notifications. Check them on the signed build before publishing it.

## Releasing

### One-time setup (maintainer)

1. The **Developer ID Application: N.N. LLC. (LY354RVYHA)** certificate with its private key in the login keychain
   (`security find-identity -v -p codesigning`). If it is listed twice, pass the SHA-1 with `--identity`; codesign
   refuses an ambiguous name. The first `codesign` with this key may show a keychain prompt: choose **Always Allow**
   so later runs need no prompt.
2. A notarization profile in the keychain. Create an app-specific password at <https://account.apple.com> (Sign-In
   and Security › App-Specific Passwords), then run once, yourself:

   ```sh
   xcrun notarytool store-credentials cmds-notary --apple-id <Apple ID e-mail> --team-id LY354RVYHA
   ```

   `build-dmg.sh` only refers to the profile name; it never sees the password, and stops with this command when the
   profile is missing.
3. GhosttyKit built in the checkout (`vendor/GhosttyKit.xcframework` and `vendor/ghostty/zig-out/share`, README
   "Build from source"): without `zig-out/share` the app would ship without terminfo and shell integration, and the
   script refuses to continue.

### Mac app

1. Start from a clean, up-to-date `master` with the submodule at the committed revision
   (`git submodule update --init`); rebuild GhosttyKit if the submodule moved.
2. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in `project.yml`, move the `Unreleased` entries in
   `CHANGELOG.md` under `## [X.Y.Z] - YYYY-MM-DD` with a compare link, then `xcodegen generate`.
3. Run the unit tests ([testing.md](testing.md#unit-tests)).
4. Commit the version bump.
5. `scripts/release/build-dmg.sh` (`--dry-run` prints every step without running it). It
   - builds the Release configuration into `build/dd-release`,
   - copies the app to `build/release/stage`, re-signs `Contents/Resources/bin/cmds` and then the app with the
     Developer ID, `--options runtime`, `--timestamp` and `App/cmds.entitlements` (inside-out, no `--deep`),
   - verifies the signature, the runtime flag, the absence of `get-task-allow`, that every Mach-O is signed by the
     team, and that Ghostty's resources are in the bundle,
   - creates `build/release/cmds-X.Y.Z.dmg` (the app and an `Applications` link) and signs it,
   - submits it with `xcrun notarytool submit --keychain-profile cmds-notary --wait`, staples the ticket and checks
     it with `stapler validate` and `spctl`,
   - writes `site/public/download/cmds-X.Y.Z.dmg`, `SHA256SUMS` and `latest.json` (version, size, SHA-256).
   `--skip-notarize` stops after the signed DMG (for testing; not for publishing).
6. Smoke-test the stapled DMG on a Mac: open it, drag cmds to Applications, start it. Gatekeeper must not warn.
   Check terminal, browser, preview, sync with a phone, notifications, Install Command Line Tool….
7. Tag the commit `vX.Y.Z` and push the tag.
8. GitHub release for the tag with the CHANGELOG section and the DMG attached (`gh release create vX.Y.Z
   build/release/cmds-X.Y.Z.dmg --notes-file <section>`), once the repository is public.
9. Website: fill in the `TODO(release)` markers in `site/public/index.html`, `site/public/en/index.html` and the
   guide pages (download button, version, size, SHA-256 from `latest.json`, "notarized by Apple", GitHub link),
   then deploy (below).

### Website (cmds.n-n.tokyo)

Static files in `site/public` (no build step), Firebase Hosting in project `startup-project-4f8f8`, hosting target
`cmds` → site `cmds-n-n-tokyo` (`site/firebase.json`, `site/.firebaserc`), custom domain `cmds.n-n.tokyo`.

- Preview: `python3 -m http.server 8765 -d site/public` (or `firebase emulators:start --only hosting` in `site/`).
- Deploy: `cd site && firebase deploy --only hosting:cmds`. One-time, before the first deploy:
  `firebase hosting:sites:create cmds-n-n-tokyo --project startup-project-4f8f8`, then add the custom domain in the
  Firebase console and its DNS records.
- `firebase.json` sets the security headers (CSP without scripts, HSTS, nosniff, Referrer-Policy,
  Permissions-Policy) and caching: HTML revalidates; `/assets/**` and `/img/**` are cached for a year as immutable,
  so **give a changed file a new name** (`site-2.css`, new image name) instead of overwriting it. DMGs are versioned
  and immutable; `latest.json` / `SHA256SUMS` are cached 5 minutes.
- The DMG, `SHA256SUMS` and `latest.json` in `site/public/download/` are not committed (`.gitignore`).
- Screenshots come from an isolated demo instance (`CMDS_SUPPORT_DIR`, sync off, a fake home with demo repos,
  synthetic agent reports through `cmds hook claude-status` / `cmds hook claude`) and the companion with `-mock` in
  the simulator, converted to WebP (1600/800 px). Never use screenshots of a real working instance.

### iOS/iPadOS companion

Not distributed yet. App Store or TestFlight distribution needs an App Store Connect app record for
`tokyo.n-n.cmds.companion` (not created), an App Store distribution profile, the app's privacy details (no data
collected) and review notes (pairing needs a Mac: the reviewer can use **Try with demo data**). Then: archive the
`CmdsCompanion` scheme (Release) for "Any iOS Device", upload with Xcode Organizer or `xcrun altool`/Transporter,
test through TestFlight, submit. Until then, build it to a device with Xcode or `xcrun devicectl device install app`
([testing.md](testing.md#testing-sync-on-a-device)).

### Local builds for your own Macs

`xcodebuild -scheme CmdsApp -configuration Release -derivedDataPath build/dd-release build` gives a Release app
signed with Apple Development (hardened runtime on), without a keychain prompt. Copy it to the same place as before
(keeps the firewall allowance), quit the old instance and start the new one; export the workspaces first to keep
the agent sessions ([guide/ai-agents.md](../guide/ai-agents.md#moving-to-a-new-version)). Scripts can quit without
the "agents are running" confirmation with `cmds quit`.
