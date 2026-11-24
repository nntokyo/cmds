#!/bin/bash
# Upgrade rehearsal: restores a COPY of the running cmds' session with this checkout's Debug build, in an isolated
# instance, and shows what each workspace and pane comes back as (kind and login profile) next to the running app.
# The running cmds and its files are only read. Agent sessions are never resumed in the copy (CMDS_AGENT_RESUME=never),
# sync is off, and only session.json, schedules.json, claude-accounts.json and browser-profiles.json are copied (no
# keys, no sync identity). docs/internals/testing.md "Upgrade rehearsal".
#
#   scripts/upgrade-rehearsal.sh [--app path/to/cmds.app] [--keep]
#
# Build first: xcodebuild -scheme CmdsApp -derivedDataPath build/dd build
set -euo pipefail

app="build/dd/Build/Products/Debug/cmds.app"
keep=false
while [ $# -gt 0 ]; do
  case "$1" in
    --app) app="$2"; shift 2 ;;
    --keep) keep=true; shift ;;
    *) echo "usage: $0 [--app path/to/cmds.app] [--keep]" >&2; exit 2 ;;
  esac
done

live="$HOME/Library/Application Support/cmds"
[ -f "$live/session.json" ] || { echo "no session at $live" >&2; exit 1; }
[ -x "$app/Contents/MacOS/cmds" ] || { echo "no app at $app (build it first)" >&2; exit 1; }
cli="$app/Contents/Resources/bin/cmds"

# A short path: the instance's Unix socket lives in it.
base="${TMPDIR:-/tmp}"
base="${base%/}"
dir=$(mktemp -d "$base/cmds-rehearsal.XXXXXX")
for file in session.json schedules.json claude-accounts.json browser-profiles.json; do
  [ -f "$live/$file" ] && cp "$live/$file" "$dir/"
done
chmod 600 "$dir"/*.json

unset CMDS_PANE_ID CMDS_WORKSPACE_ID CMDS_SOCKET_PATH
CMDS_AGENT_RESUME=never CMDS_SUPPORT_DIR="$dir" CMDS_SYNC_DISABLED=1 "$app/Contents/MacOS/cmds" >/dev/null 2>&1 &
pid=$!
disown "$pid"
cleanup() {
  kill "$pid" 2>/dev/null || true
  if ! $keep && [ -n "$dir" ] && [ "${dir#"$base"/cmds-rehearsal.}" != "$dir" ]; then rm -rf "$dir"; fi
}
trap cleanup EXIT

for _ in $(seq 1 30); do "$cli" --socket "$dir/cmds.sock" ping >/dev/null 2>&1 && break; sleep 1; done
"$cli" --socket "$dir/cmds.sock" ping >/dev/null || { echo "the rehearsal instance did not start" >&2; exit 1; }
sleep 2

summary() {
  python3 -c '
import json, sys
data = json.load(sys.stdin)
for w in data:
    panes = ", ".join(p["kind"] + ("[" + p["profile"] + "]" if p.get("profile") else "") for p in w["panes"])
    print("  %-24s %s" % ((w.get("title") or "")[:24], panes))
print("  %d workspaces, %d panes" % (len(data), sum(len(w["panes"]) for w in data)))'
}

echo "Running cmds (read only):"
# The running app's own socket (this build's CLI would default to the Debug app's).
if "$cli" --socket "$live/cmds.sock" ls --json >/dev/null 2>&1; then "$cli" --socket "$live/cmds.sock" ls --json | summary
else echo "  (not reachable)"; fi
echo "This build, restoring a copy of its session ($dir):"
"$cli" --socket "$dir/cmds.sock" ls --json | summary
echo "Schedules in the copy:"
"$cli" --socket "$dir/cmds.sock" schedule list | sed 's/^/  /'
if $keep; then echo "Kept: $dir (the instance stops now)"; fi
