#!/bin/sh
# Deploys cmds.n-n.tokyo from this Mac, as .github/workflows/deploy-site.yml does (docs/internals/ci.md): use it
# when GitHub Actions is unavailable or has no deploy identity. Needs `firebase login` with access to the project.
#
#   scripts/ci/deploy-site.sh             # check, deploy, check the live site
#   scripts/ci/deploy-site.sh --dry-run   # check and write latest.json / SHA256SUMS only
#
# Deploys only a clean checkout of origin/master, so the site always matches what is merged.
set -eu
cd "$(dirname "$0")/../.."
dry=
[ "${1:-}" = --dry-run ] && dry=1

git fetch -q origin master
[ -z "$(git status --porcelain -- site scripts/ci)" ] || { echo "site/ or scripts/ci/ has uncommitted changes" >&2; exit 1; }
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/master)" ] || { echo "HEAD is not origin/master: check out and pull master first" >&2; exit 1; }

python3 -I scripts/ci/site_check.py --release --write-download-files site/public/download
rm -f site/public/download/*.dmg
[ -n "$dry" ] && { echo "dry run: not deployed"; exit 0; }
(cd site && firebase deploy --only hosting:cmds --project startup-project-4f8f8 --non-interactive)
scripts/ci/check-live.sh
