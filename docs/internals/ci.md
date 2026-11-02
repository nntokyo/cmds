# CI and website deploys

> What GitHub Actions checks on every pull request, how the website is deployed from master, and how to run the
> same checks and the deploy on a Mac when Actions is unavailable or out of minutes.

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

## Website deploy (`.github/workflows/deploy-site.yml`)

A push to `master` that changes `site/`, `scripts/ci/` or the workflow (or Run workflow by hand):

1. runs `site_check.py --release --write-download-files site/public/download`, which also writes `latest.json` and
   `SHA256SUMS` for the appcast's release: they are not committed, and a deploy without them would remove them from
   the site;
2. deploys hosting target `cmds` of project `startup-project-4f8f8` with `firebase-tools`;
3. checks the live site with `scripts/ci/check-live.sh`: the appcast and the four main pages are byte for byte the
   checkout's, and `latest.json` / `SHA256SUMS` name the same release.

Deploys run one at a time (`concurrency: deploy-site`) in the GitHub environment `website`.

### Deploy identity (one-time setup)

The workflow signs in to Google Cloud with Workload Identity Federation: no key is stored in GitHub. It deploys only
when the repository variables `GCP_WORKLOAD_IDENTITY_PROVIDER` and `GCP_DEPLOY_SERVICE_ACCOUNT` are set; until then
it checks the site, warns "not deployed", and the site is deployed with `scripts/ci/deploy-site.sh`.

Setup by a project owner (Google Cloud IAM; review before running, it grants deploy rights to this repository's
`website` environment only):

```sh
P=startup-project-4f8f8
N=$(gcloud projects describe $P --format='value(projectNumber)')
gcloud iam service-accounts create cmds-site-deploy --project $P --display-name "cmds website deploy (GitHub Actions)"
SA=cmds-site-deploy@$P.iam.gserviceaccount.com
gcloud projects add-iam-policy-binding $P --member "serviceAccount:$SA" --role roles/firebasehosting.admin
gcloud projects add-iam-policy-binding $P --member "serviceAccount:$SA" --role roles/serviceusage.serviceUsageConsumer
gcloud iam workload-identity-pools create github --project $P --location global --display-name GitHub
gcloud iam workload-identity-pools providers create-oidc cmds --project $P --location global \
  --workload-identity-pool github --issuer-uri https://token.actions.githubusercontent.com \
  --attribute-mapping 'google.subject=assertion.sub,attribute.repository=assertion.repository' \
  --attribute-condition "assertion.repository=='nntokyo/cmds' && assertion.sub=='repo:nntokyo/cmds:environment:website'"
gcloud iam service-accounts add-iam-policy-binding $SA --project $P --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/$N/locations/global/workloadIdentityPools/github/attribute.repository/nntokyo/cmds"
gh variable set GCP_WORKLOAD_IDENTITY_PROVIDER --body "projects/$N/locations/global/workloadIdentityPools/github/providers/cmds"
gh variable set GCP_DEPLOY_SERVICE_ACCOUNT --body "$SA"
```

Then Settings › Environments › `website`: allow only the `master` branch.

## When GitHub Actions is unavailable

When Actions is out of minutes, disabled or down, or a run hangs in the queue:

- **Checks**: `scripts/ci/run-local.sh` runs the same jobs on this Mac (`site`, `links`, `strings`, `core`, `ssh`;
  name some to run only those, `--release` adds the release DMG check). The Swift jobs run one after another, only
  while memory pressure is normal and fewer than two other Swift/Xcode builds run; they wait up to 10 minutes
  otherwise ([testing.md](testing.md#machine-load)). Logs and `summary.md` go to `build/ci/`. `--post N` puts the
  summary on pull request N, which then stands in for the Actions result:

  ```sh
  git switch <branch> && scripts/ci/run-local.sh --release --post 69
  ```

- **Deploy**: after merging, `git switch master && git pull --ff-only && scripts/ci/deploy-site.sh`. It refuses
  anything but a clean `origin/master`, runs the site check with `--release`, writes `latest.json` / `SHA256SUMS`,
  deploys with your `firebase login` and checks the live site. `--dry-run` stops before deploying.
- `scripts/ci/check-live.sh` on its own compares the live site with the checkout (`CMDS_SITE_URL` for another
  host, e.g. a preview channel).

Public repositories get standard GitHub-hosted runners without a minutes quota, but jobs can still queue, hit
concurrency limits or fail when Actions is degraded; check <https://www.githubstatus.com>.
