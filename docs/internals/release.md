# Versioning, signing and release builds

> How versions are numbered, how the apps are signed (hardened runtime, entitlements), and how to cut a release:
> signed and notarized DMG, website, GitHub release; iOS distribution is not set up yet.

## Versions

| What | Where | Current |
|---|---|---|
| App version (`CFBundleShortVersionString`) | `MARKETING_VERSION` in `project.yml`, shared by the Mac app and the companion | 0.2.0 (Mac); the iOS app is 0.1.3 |
| Build number (`CFBundleVersion`) | `CURRENT_PROJECT_VERSION` in `project.yml` | 5 |
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

> Without a `cmds-notary` profile (0.1.0 was cut this way), notarize through the Xcode account instead:
> `xcodebuild archive -scheme CmdsApp -configuration Release -archivePath build/release/cmds.xcarchive`, then
> `xcodebuild -exportArchive` with ExportOptions `method=developer-id`, `destination=upload`, `teamID=LY354RVYHA`,
> then repeat `xcodebuild -exportNotarizedApp -archivePath … -exportPath build/release/notarized` until it succeeds
> (stapled app). Build the DMG from that app as `build-dmg.sh` does and sign it with the Developer ID SHA-1 that does
> not prompt for keychain access; the app inside is notarized and stapled, the DMG itself is signed only.

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
   Check terminal, browser, preview, sync with a phone, notifications, Install Command Line Tool…, and that
   cmds › Check for Updates… is enabled.
7. `scripts/release/make-appcast.sh build/release/cmds-X.Y.Z.dmg [notes.html]` writes and signs
   `site/public/download/appcast.xml` ([Automatic updates](#automatic-updates)); commit it.
8. Tag the commit `vX.Y.Z` and push the tag.
9. GitHub release for the tag with the CHANGELOG section and the DMG attached (`gh release create vX.Y.Z
   build/release/cmds-X.Y.Z.dmg --notes-file <section>`). It must exist before the appcast is deployed: the
   appcast downloads the DMG from it.
10. Website: point the download button, version, size, SHA-256 (from `latest.json`), date and GitHub links in
   `site/public/index.html`, `site/public/en/index.html` and the guide pages at the new release, then deploy
   (below). Every installed release from 0.2.0 on picks the update up within a day.

### Automatic updates

The Mac app updates itself with [Sparkle](https://sparkle-project.org) 2 (`App/Sources/App/Updater.swift`; the
Info.plist keys are in `project.yml`).

- **Feed**: `https://cmds.n-n.tokyo/download/appcast.xml`, committed as `site/public/download/appcast.xml` and cached
  for 5 minutes. One item, the latest release; its enclosure is the notarized DMG of the GitHub release. Sparkle
  compares `CFBundleVersion`, so every Mac release needs a higher `CURRENT_PROJECT_VERSION`.
- **Keys**: EdDSA. The private key is in the login keychain (Sparkle's `generate_keys --account cmds`) and exported to
  `~/.keys/cmds-sparkle-ed25519` (mode 600). Keep a backup outside this Mac: without the key no update can reach the
  installed apps again. The public half is `SUPublicEDKey`.
- **Verification**: the DMG and the feed are both signed (`SURequireSignedFeed`), and updates are verified before they
  are extracted (`SUVerifyUpdateBeforeExtraction`); macOS also checks that the new app is signed by the same team.
  Never edit `appcast.xml` by hand: `make-appcast.sh` writes and signs it.
- **Behaviour**: a check once a day without asking first (`SUEnableAutomaticChecks`, `SUScheduledCheckInterval`),
  automatic download and install when cmds quits (`SUAutomaticallyUpdate`); cmds › Check for Updates… installs
  right away (cmds asks first if agents are running). Users change both in Settings › Updates.
- **Where it runs**: only in builds signed with the Developer ID (releases). Debug and local Release builds and
  isolated instances (`CMDS_SUPPORT_DIR`) never update themselves; `CMDS_UPDATE_FEED_URL` points an isolated instance
  at a test feed and makes it check at launch.
- **Tools**: `generate_keys`, `sign_update`, `generate_appcast` are in
  `build/<derived data>/SourcePackages/artifacts/sparkle/Sparkle/bin/` after any build.
- **End-to-end test** (before a release that changes the updater): export the release candidate (Developer ID) and a
  copy built with a higher version and build number (`xcodebuild archive … MARKETING_VERSION=X CURRENT_PROJECT_VERSION=N`
  and `-exportArchive` with `destination=export`); zip the newer one (`ditto -c -k --keepParent`), write a test feed
  with `APPCAST_OUT` and `APPCAST_DOWNLOAD_URL` and serve both over HTTPS (a Firebase preview channel); copy the
  candidate to a temporary folder and start it isolated with `CMDS_SUPPORT_DIR`, `CMDS_SYNC_DISABLED=1` and
  `CMDS_UPDATE_FEED_URL`; after the download, quit it with its own CLI (`env -u CMDS_SOCKET_PATH
  CMDS_SUPPORT_DIR=… …/cmds.app/Contents/Resources/bin/cmds quit`; never the app in use) and check that the copy now
  has the newer version and a valid signature. Sparkle keeps its state in the `tokyo.n-n.cmds` defaults domain even
  for isolated instances: delete only the `SU*` keys the test added.

### Website (cmds.n-n.tokyo)

Static files in `site/public` (no build step), Firebase Hosting in project `startup-project-4f8f8`, hosting target
`cmds` → site `cmds-n-n-tokyo` (`site/firebase.json`, `site/.firebaserc`), custom domain `cmds.n-n.tokyo`.

- Preview: `python3 -m http.server 8765 -d site/public` (or `firebase emulators:start --only hosting` in `site/`).
- Deploy: `cd site && firebase deploy --only hosting:cmds`. One-time, before the first deploy:
  `firebase hosting:sites:create cmds-n-n-tokyo --project startup-project-4f8f8`, then add the custom domain in the
  Firebase console and its DNS records.
- `firebase.json` sets the security headers (CSP allowing only `/assets/*.js` and the Google Analytics endpoints, HSTS, nosniff, Referrer-Policy,
  Permissions-Policy) and caching: HTML revalidates; `/assets/**` and `/img/**` are cached for a year as immutable,
  so **give a changed file a new name** (`site-2.css`, new image name) instead of overwriting it. DMGs are versioned
  and immutable; `latest.json` / `SHA256SUMS` are cached 5 minutes.
- The DMG, `SHA256SUMS` and `latest.json` in `site/public/download/` are not committed (`.gitignore`). Deploying from
  another checkout or worktree removes them from the site unless you copy them in first.
- Firebase Hosting on the Spark plan refuses executable files such as `.dmg` ("Executable files are forbidden"), so
  the DMG is served from the GitHub release (`https://github.com/nntokyo/cmds/releases/download/vX.Y.Z/cmds-X.Y.Z.dmg`)
  and the site links there; remove the DMG from `site/public/download/` before deploying.
- Screenshots come from an isolated demo instance (`CMDS_SUPPORT_DIR`, sync off, a fake home with demo repos,
  synthetic agent reports through `cmds hook claude-status` / `cmds hook claude`) and the companion with `-mock` in
  the simulator, converted to WebP (1600/800 px). Never use screenshots of a real working instance.
- Measurement (privacy policy section 6 discloses it):
  - Google Analytics 4: account N.N, property `cmds.n-n.tokyo` (561703084), stream measurement ID `G-6JN971XLBV`,
    loaded by `assets/analytics-N.js` (give it a new number on every change; assets are cached as immutable).
    Besides page views it sends `download_mac` (DMG link), `app_store_click` and `github_click`; see Reports ›
    Engagement › Events, or Realtime. It is not loaded on the privacy pages, which hold the visitor opt-out;
    cookies are host-only with the prefix `cmds` (sibling n-n.tokyo sites keep their own `_ga`); consent mode
    denies analytics cookies in the EEA, the UK and Switzerland; Google signals and ad features are off. Keep
    privacy policy section 6 in step with any change here.
  - Search Console: URL-prefix property `https://cmds.n-n.tokyo/`, verified by the `google-site-verification` meta
    tag in `index.html` (keep it), sitemap submitted.
  - Actual DMG downloads (including direct links from GitHub): `gh api repos/nntokyo/cmds/releases --jq
    '.[] | .tag_name as $t | .assets[] | "\($t) \(.download_count)"'`.
  - iOS installs and App Store page views: App Store Connect › Analytics.

### iOS/iPadOS companion

On the App Store since 0.1.0 (2026-10-31, "cmds Companion", id6828885265). Store releases need the App Store
Connect app record for `tokyo.n-n.cmds.companion`, an App Store distribution profile, the app's privacy details (no data
collected) and review notes (pairing needs a Mac: the reviewer can use **Try with demo data**). Then: archive the
`CmdsCompanion` scheme (Release) for "Any iOS Device", upload with Xcode Organizer or `xcrun altool`/Transporter,
test through TestFlight, submit. For development, build it to a device with Xcode or `xcrun devicectl device install app`
([testing.md](testing.md#testing-sync-on-a-device)).

### Local builds for your own Macs

`xcodebuild -scheme CmdsApp -configuration Release -derivedDataPath build/dd-release build` gives a Release app
signed with Apple Development (hardened runtime on), without a keychain prompt. Copy it to the same place as before
(keeps the firewall allowance), quit the old instance and start the new one; export the workspaces first to keep
the agent sessions ([guide/ai-agents.md](../guide/ai-agents.md#moving-to-a-new-version)). Scripts can quit without
the "agents are running" confirmation with `cmds quit`.
