#!/bin/sh
# After a deploy: checks that cmds.n-n.tokyo serves this checkout's appcast and pages, and a latest.json /
# SHA256SUMS for the same release (docs/internals/ci.md). Retries for a minute while the CDN catches up.
set -u
cd "$(dirname "$0")/../.."
base=${CMDS_SITE_URL:-https://cmds.n-n.tokyo}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

check() {
  ok=0
  curl -fsS "$base/download/appcast.xml" -o "$tmp/appcast.xml" || return 1
  cmp -s "$tmp/appcast.xml" site/public/download/appcast.xml || { echo "live appcast.xml differs from the checkout"; ok=1; }
  for page in "" en/ guide/ en/guide/; do
    curl -fsS "$base/$page" -o "$tmp/page.html" || return 1
    cmp -s "$tmp/page.html" "site/public/${page}index.html" || { echo "live /$page differs from the checkout"; ok=1; }
  done
  version=$(sed -n 's:.*<sparkle\:shortVersionString>\([^<]*\)<.*:\1:p' site/public/download/appcast.xml | head -1)
  curl -fsS "$base/download/latest.json" -o "$tmp/latest.json" || return 1
  grep -q "\"version\": \"$version\"" "$tmp/latest.json" || { echo "live latest.json is not $version"; ok=1; }
  curl -fsS "$base/download/SHA256SUMS" -o "$tmp/SHA256SUMS" || return 1
  grep -q " cmds-$version.dmg\$" "$tmp/SHA256SUMS" || { echo "live SHA256SUMS is not for $version"; ok=1; }
  sha=$(sed -n 's/.*"sha256": "\([0-9a-f]*\)".*/\1/p' "$tmp/latest.json")
  grep -q "^$sha " "$tmp/SHA256SUMS" || { echo "live latest.json and SHA256SUMS disagree"; ok=1; }
  return $ok
}

for attempt in 1 2 3 4 5 6; do
  if check; then echo "live site OK ($base)"; exit 0; fi
  [ "$attempt" = 6 ] || sleep 10
done
echo "live site check failed ($base)" >&2
exit 1
