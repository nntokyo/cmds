# CI and website deploys

> What GitHub Actions checks on every pull request, how to run the same checks on a Mac when Actions is unavailable,
> and how the website is deployed from a Mac (also while GitHub is down).

## Checks (`.github/workflows/ci.yml`)

Run on every pull request, on pushes to `master` and by hand (Actions › CI › Run workflow).

| Job | Runner | What it checks |
|---|---|---|
| Website and update feed | ubuntu-latest | `scripts/ci/site_check.py --release`: every page in `site/public` is well-formed HTML; `appcast.xml` has a valid feed signature for `SUPublicEDKey` (so a hand-edited feed fails), one item, and an enclosure on the GitHub release `vX.Y.Z`; every download and release link and the byte count on the pages name the appcast's version; the release DMG has the enclosure's length and Sparkle signature, and its SHA-256 is the one on the pages. Then `scripts/check-links.py` (Markdown links, `docs/…` mentions) |
| Swift packages and String Catalogs | macos-latest | every `.xcstrings` compiles (`xcstringstool`); `Packages/CmdsCore`: `swift test` (the library, the CLI and their tests); `Packages/CmdsSSH`: `swift test` (its end-to-end part needs a throwaway sshd and is skipped) |

Not covered by Actions: the Mac app and the iOS companion (they need GhosttyKit built with Zig,
[release.md](release.md#one-time-setup-maintainer)), signing, notarization and UI tests. Build them locally
([testing.md](testing.md)) when a change touches the apps.

The Ed25519 check is plain Python (`scripts/ci/ed25519.py`), so neither the runner nor a Mac needs Sparkle's tools
or extra packages. It only verifies; the private key never leaves the maintainer's Mac.

Merge a pull request when its checks pass. When they cannot run, run them locally (below) and put the summary on
the pull request.

## Website deploy (from a Mac)

The website is deployed from the maintainer's Mac, never from GitHub Actions, so a deploy does not depend on GitHub
(the CI job above only checks the site). After merging:

```sh
git switch master && git pull --ff-only && scripts/ci/deploy-site.sh
```

`scripts/ci/deploy-site.sh`:

1. refuses anything but a clean checkout of `origin/master`;
2. runs `site_check.py --release --write-download-files site/public/download`, which also writes `latest.json` and
   `SHA256SUMS` for the appcast's release: they are not committed, and a deploy without them would remove them from
   the site;
3. deploys hosting target `cmds` of project `startup-project-4f8f8` with your `firebase login`;
4. checks the live site with `scripts/ci/check-live.sh`: the appcast and the four main pages are byte for byte the
   checkout's, and `latest.json` / `SHA256SUMS` name the same release.

`--dry-run` stops before deploying. `scripts/ci/check-live.sh` on its own compares the live site with the checkout
(`CMDS_SITE_URL` for another host, e.g. a preview channel).

### When GitHub is unavailable

`scripts/ci/deploy-site.sh --offline` needs no GitHub: it does not fetch, deploys a clean `master` that contains the
last known `origin/master` (local commits on top are allowed), and checks the release DMG from
`build/release/cmds-X.Y.Z.dmg` (or `--dmg FILE`) instead of downloading it: its length, Sparkle signature and SHA-256
must match the appcast and the pages, so a wrong file is refused. `latest.json` keeps the date of the existing one
for the same version (else today). Push the local commits once GitHub is back.

The DMG itself is downloaded from the GitHub release (Firebase Hosting refuses DMGs,
[release.md](release.md#website-cmdsn-ntokyo)): while GitHub is down, new installs and Sparkle updates wait for it.

## Checks when GitHub Actions is unavailable

When Actions is out of minutes, disabled or down, or a run hangs in the queue:

- **Checks**: `scripts/ci/run-local.sh` runs the same jobs on this Mac (`site`, `links`, `strings`, `core`, `ssh`;
  name some to run only those, `--release` adds the release DMG check). The Swift jobs run one after another, only
  while memory pressure is normal and fewer than two other Swift/Xcode builds run; they wait up to 10 minutes
  otherwise ([testing.md](testing.md#machine-load)). Logs and `summary.md` go to `build/ci/`. `--post N` puts the
  summary on pull request N, which then stands in for the Actions result:

  ```sh
  git switch <branch> && scripts/ci/run-local.sh --release --post 69
  ```

- **Merge** when the local run passes (or, with GitHub down, wait: nothing can be merged).

Public repositories get standard GitHub-hosted runners without a minutes quota, but jobs can still queue, hit
concurrency limits or fail when Actions is degraded; check <https://www.githubstatus.com>.
