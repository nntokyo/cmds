#!/bin/bash
# Build GhosttyKit.xcframework from the Ghostty submodule with cmds' libghostty patches.
#
#   scripts/build-ghostty.sh
#
# 1. Applies vendor/ghostty-patches/*.patch to vendor/ghostty in name order (a patch that is already applied is left
#    as it is).
# 2. Runs Ghostty's zig build there (Zig 0.17.0, README "Requirements"): vendor/ghostty/macos/GhosttyKit.xcframework,
#    and vendor/ghostty/zig-out/share (terminfo, shell integration), which the app bundles.
# 3. Reverts the patches it applied, also when the build fails, so the submodule stays at its pinned upstream revision.
# 4. (Re)creates the symlink vendor/GhosttyKit.xcframework.
#
# GHOSTTY_DIR=<dir> builds another checkout's Ghostty submodule instead, e.g. the main checkout's from a git worktree
# whose submodule is not initialized; the worktree's vendor/GhosttyKit.xcframework and vendor/ghostty/zig-out/share
# then point there. Patches go through patch(1): the submodule's git state is never touched. One build per Ghostty
# directory at a time. The zig build is heavy (several GB of memory, minutes): run it alone.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="${GHOSTTY_DIR:-$ROOT/vendor/ghostty}"
PATCHES="$ROOT/vendor/ghostty-patches"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -f "$GHOSTTY/build.zig" ] || die "no Ghostty source in $GHOSTTY (git submodule update --init)"
GHOSTTY="$(cd "$GHOSTTY" && pwd)"
command -v zig > /dev/null || die "zig not found (README, Requirements: Zig 0.17.0)"

LOCK="${TMPDIR:-/tmp}/cmds-build-ghostty.$(printf '%s' "$GHOSTTY" | shasum | cut -c1-16).lock"
mkdir "$LOCK" 2> /dev/null || die "another build of $GHOSTTY is running (else remove $LOCK)"

# patch(1): -N never reverses a patch on its own; -F0 no fuzz; -V none no .orig files; no answers to its questions.
run_patch() { # patch file, extra options
    local file="$1"
    shift
    patch -p1 -N -s -F0 -V none -d "$GHOSTTY" -i "$file" "$@" < /dev/null
}

APPLIED="" # patches this run applied, newest first, one per line
revert() {
    local file
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        if run_patch "$file" -R > /dev/null; then
            log "reverted $(basename "$file")"
        else
            warn "could not revert $(basename "$file") in $GHOSTTY: revert it by hand"
        fi
    done <<< "$APPLIED"
    APPLIED=""
}
finish() {
    revert
    rmdir "$LOCK" 2> /dev/null || true
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for file in "$PATCHES"/*.patch; do
    [ -e "$file" ] || continue
    name="$(basename "$file")"
    if run_patch "$file" -R --dry-run > /dev/null 2>&1; then
        log "$name: already applied, left as it is"
    elif run_patch "$file" --dry-run > /dev/null 2>&1; then
        run_patch "$file" > /dev/null || die "$name: could not be applied"
        APPLIED="$file"$'\n'"$APPLIED"
        log "$name: applied"
    else
        die "$name does not apply to $GHOSTTY (other revision, or local changes there): update the patch"
    fi
done

log "zig build in $GHOSTTY"
(cd "$GHOSTTY" && zig build -Demit-xcframework=true -Dxcframework-target=native -Demit-macos-app=false \
    -Doptimize=ReleaseFast)

revert

XCFRAMEWORK="$GHOSTTY/macos/GhosttyKit.xcframework"
[ -d "$XCFRAMEWORK" ] || die "the build did not produce $XCFRAMEWORK"
link() { # target, link
    if [ -e "$2" ] && [ ! -L "$2" ]; then
        warn "$2 is not a symlink (a copy?): left as it is; replace it with a link to $1"
        return
    fi
    mkdir -p "$(dirname "$2")"
    ln -sfn "$1" "$2"
    log "${2#"$ROOT"/} -> $1"
}
link "$XCFRAMEWORK" "$ROOT/vendor/GhosttyKit.xcframework"
if [ "$GHOSTTY" != "$ROOT/vendor/ghostty" ]; then
    link "$GHOSTTY/zig-out/share" "$ROOT/vendor/ghostty/zig-out/share"
fi
