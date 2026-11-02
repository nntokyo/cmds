#!/bin/sh
# Deploys cmds.n-n.tokyo from this Mac (docs/internals/ci.md). The site is always deployed from here, never from
# GitHub Actions, so a deploy works while GitHub is unavailable. Needs `firebase login` with access to the project.
#
#   scripts/ci/deploy-site.sh                    # check, deploy, check the live site
#   scripts/ci/deploy-site.sh --dry-run          # check and write latest.json / SHA256SUMS only
#   scripts/ci/deploy-site.sh --offline          # without GitHub: no fetch, the release DMG from build/release
#   scripts/ci/deploy-site.sh --offline --dmg F  # ... or from F
#
# Normally deploys only a clean checkout of origin/master, and checks the release DMG downloaded from GitHub.
# --offline skips GitHub: the checkout must be a clean `master` (its last known origin/master or later local
# commits), and the DMG must be a local copy of the release (its length, Sparkle signature and SHA-256 are checked
# against the appcast and the pages, so a wrong file is refused).
set -eu
cd "$(dirname "$0")/../.."
dry=
offline=
dmg=
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --offline) offline=1 ;;
    --dmg) dmg=${2:?--dmg needs a file}; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -z "$dmg" ] || [ -n "$offline" ] || { echo "--dmg needs --offline" >&2; exit 2; }

[ -z "$(git status --porcelain -- site scripts/ci)" ] || { echo "site/ or scripts/ci/ has uncommitted changes" >&2; exit 1; }
if [ -n "$offline" ]; then
  [ "$(git branch --show-current)" = master ] || { echo "--offline deploys only the master branch" >&2; exit 1; }
  git merge-base --is-ancestor origin/master HEAD ||
    { echo "master is behind or apart from the last known origin/master" >&2; exit 1; }
  version=$(sed -n 's:.*<sparkle\:shortVersionString>\([^<]*\)<.*:\1:p' site/public/download/appcast.xml | head -1)
  dmg=${dmg:-build/release/cmds-$version.dmg}
  [ -f "$dmg" ] || { echo "$dmg not found: pass the release DMG with --dmg" >&2; exit 1; }
  python3 -I scripts/ci/site_check.py --dmg "$dmg" --write-download-files site/public/download
else
  git fetch -q origin master ||
    { echo "cannot reach GitHub: use --offline (and --dmg if build/release has no copy of the release DMG)" >&2; exit 1; }
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/master)" ] ||
    { echo "HEAD is not origin/master: check out and pull master first" >&2; exit 1; }
  python3 -I scripts/ci/site_check.py --release --write-download-files site/public/download
fi
rm -f site/public/download/*.dmg
[ -n "$dry" ] && { echo "dry run: not deployed"; exit 0; }
(cd site && firebase deploy --only hosting:cmds --project startup-project-4f8f8 --non-interactive)
scripts/ci/check-live.sh
