#!/bin/sh
# Runs the CI jobs of .github/workflows/ci.yml on this Mac (docs/internals/ci.md), for when GitHub Actions is
# unavailable or out of minutes, or to check a change before pushing it.
#
#   scripts/ci/run-local.sh                  # every job: site, links, strings, core, ssh
#   scripts/ci/run-local.sh site strings     # only these jobs
#   scripts/ci/run-local.sh --release site   # site job with the release DMG check (network)
#   scripts/ci/run-local.sh --post 69        # every job, then the summary as a comment on PR 69
#
# Heavy jobs (core, ssh: Swift builds and tests) run one after another and only while memory pressure is normal
# (kern.memorystatus_vm_pressure_level 1) and fewer than two other Swift/Xcode builds are running; otherwise the
# script waits up to 10 minutes, then stops. The summary is in build/ci/summary.md, each job's log in build/ci/.
set -u
cd "$(dirname "$0")/../.."
root=$PWD
out=$root/build/ci
mkdir -p "$out"

release=
post=
jobs=
while [ $# -gt 0 ]; do
  case "$1" in
    --release) release=--release ;;
    --post) post=${2:?--post needs a PR number}; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    site|links|strings|core|ssh) jobs="$jobs $1" ;;
    *) echo "unknown job or option: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$jobs" ] || jobs="site links strings core ssh"

wait_for_room() { # heavy jobs: memory pressure normal and at most one other Swift/Xcode build
  waited=0
  while :; do
    level=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo 1)
    others=$(pgrep -f 'swift-build|swift-test|xcodebuild' 2>/dev/null | wc -l | tr -d ' ')
    [ "$level" -le 1 ] && [ "$others" -le 1 ] && return 0
    [ "$waited" -ge 600 ] && { echo "memory pressure $level, $others builds running: gave up after 10 minutes" >&2; return 1; }
    echo "waiting: memory pressure $level, $others other builds running" >&2
    sleep 30; waited=$((waited + 30))
  done
}

run_job() {
  name=$1
  log=$out/$name.log
  start=$(date +%s)
  case "$name" in
    site) python3 -I scripts/ci/site_check.py $release ;;
    links) python3 -I scripts/check-links.py ;;
    strings)
      tmp=$(mktemp -d)
      status=0
      for catalog in $(git ls-files '*.xcstrings'); do
        echo "compile $catalog"
        xcrun xcstringstool compile "$catalog" --output-directory "$tmp" || status=1
      done
      rm -rf "$tmp"
      [ "$status" = 0 ]
      ;;
    core) wait_for_room && (cd Packages/CmdsCore && swift test) ;;
    ssh) wait_for_room && (cd Packages/CmdsSSH && swift test) ;;
  esac > "$log" 2>&1
  status=$?
  secs=$(( $(date +%s) - start ))
  if [ "$status" = 0 ]; then result=pass; else result=FAIL; fi
  # Swift jobs: one "Executed N tests, ..." per test bundle; others: the last line.
  last=$(grep -A1 "\.xctest' \(passed\|failed\)" "$log" | grep -o 'Executed .*failures' | paste -sd ';' -)
  [ -n "$last" ] || last=$(tail -1 "$log")
  printf '| %s | %s | %ss | %s |\n' "$name" "$result" "$secs" "$(echo "$last" | tr '|' '/' | cut -c1-160)" >> "$out/summary.md.tmp"
  echo "$name: $result (${secs}s, log $log)"
  return "$status"
}

{
  echo "Local CI ($(git rev-parse --short HEAD), $(sw_vers -productVersion), $(xcodebuild -version 2>/dev/null | head -1)), \`scripts/ci/run-local.sh$release${jobs:+ }$(echo $jobs)\`"
  [ -z "$(git status --porcelain)" ] || echo "Uncommitted changes in the checkout."
  echo
  echo "| Job | Result | Time | Last line |"
  echo "|---|---|---|---|"
} > "$out/summary.md.tmp"

failed=0
for job in $jobs; do
  run_job "$job" || failed=1
done
mv "$out/summary.md.tmp" "$out/summary.md"
echo
cat "$out/summary.md"

if [ -n "$post" ]; then
  gh pr comment "$post" --body-file "$out/summary.md"
fi
exit "$failed"
