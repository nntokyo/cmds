#!/bin/bash
# Build, sign, notarize and package the cmds Mac app as a DMG for distribution.
#
#   scripts/release/build-dmg.sh [--dry-run] [--skip-build] [--skip-notarize] [--identity <SHA-1|name>]
#
# Steps: Release build (scheme CmdsApp, hardened runtime) → re-sign the embedded CLI and the app with the
# Developer ID certificate, hardened runtime, secure timestamp and App/cmds.entitlements → verify → DMG with an
# Applications link → sign the DMG → notarize (notarytool, keychain profile "cmds-notary") → staple → SHA-256 →
# site/public/download/ (the DMG, SHA256SUMS, latest.json). Nothing is uploaded or published.
#
# --dry-run        print every command instead of running it (no build, no signing, no notarization)
# --skip-build     reuse build/dd-release/Build/Products/Release/cmds.app
# --skip-notarize  stop after the signed DMG (the result is NOT fit for distribution; site/public/download/ is not written)
# --identity X     signing identity (SHA-1 hash or full name); default: the only/first valid
#                  "Developer ID Application: N.N. LLC. (LY354RVYHA)". Use the hash when the keychain holds the
#                  certificate twice: codesign refuses an ambiguous name.
#
# Notarization credentials are never handled here: they live in the login keychain under the profile
# "cmds-notary", which the maintainer creates once (the script prints the command when it is missing).
# Procedure and entitlements: docs/internals/release.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

TEAM_ID="LY354RVYHA"
IDENTITY_NAME="Developer ID Application: N.N. LLC. ($TEAM_ID)"
NOTARY_PROFILE="cmds-notary"
ENTITLEMENTS="$ROOT/App/cmds.entitlements"
DERIVED="$ROOT/build/dd-release"
BUILT_APP="$DERIVED/Build/Products/Release/cmds.app"
OUT="$ROOT/build/release"
SITE_DOWNLOAD="$ROOT/site/public/download"

DRY_RUN=0
SKIP_BUILD=0
SKIP_NOTARIZE=0
IDENTITY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --identity) shift; IDENTITY="${1:?--identity needs a value}" ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '[dry-run]'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

# --- Preconditions -------------------------------------------------------------------------------------------

[ -f "$ENTITLEMENTS" ] || die "missing $ENTITLEMENTS"
need() { # A missing build input stops a real run; a dry run only warns.
  if [ "$DRY_RUN" = 1 ]; then echo "warning: $*" >&2; else die "$*"; fi
}
[ -e "$ROOT/vendor/GhosttyKit.xcframework" ] || need "vendor/GhosttyKit.xcframework is missing (README, Build from source)"
# The app's build phase silently skips Ghostty's terminfo/shell integration when this is missing.
[ -d "$ROOT/vendor/ghostty/zig-out/share/terminfo" ] || need "vendor/ghostty/zig-out/share is missing: build GhosttyKit first"

VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml | head -1)"
BUILD_NUMBER="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml | head -1)"
[ -n "$VERSION" ] || die "MARKETING_VERSION not found in project.yml"
DMG_NAME="cmds-$VERSION.dmg"
DMG="$OUT/$DMG_NAME"
echo "cmds $VERSION (build $BUILD_NUMBER)"

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "warning: the working tree has uncommitted changes; a release should be built from a clean, tagged commit" >&2
fi

if [ -z "$IDENTITY" ]; then
  # First valid identity with the exact Developer ID name, as its SHA-1 hash (unambiguous for codesign).
  IDENTITY="$(security find-identity -v -p codesigning | awk -v n="\"$IDENTITY_NAME\"" 'index($0, n) {print $2; exit}')"
  [ -n "$IDENTITY" ] || die "no valid \"$IDENTITY_NAME\" signing identity in the keychain"
fi
echo "signing identity: $IDENTITY"

if [ "$SKIP_NOTARIZE" = 0 ]; then
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    cat >&2 <<EOF

The notarization keychain profile "$NOTARY_PROFILE" does not exist (or its credentials are rejected).
Create it once yourself, in Terminal (it asks for an app-specific password from https://account.apple.com,
Sign-In and Security › App-Specific Passwords, and stores it in the login keychain; this script never sees it):

  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <your Apple ID e-mail> --team-id $TEAM_ID

Then run this script again. Use --skip-notarize to stop after signing instead.
EOF
    [ "$DRY_RUN" = 1 ] || exit 1
    echo "(dry run: continuing as if the profile existed)" >&2
  fi
fi

# --- Build ---------------------------------------------------------------------------------------------------

if [ "$SKIP_BUILD" = 0 ]; then
  log "Release build"
  run xcodegen generate
  run xcodebuild -scheme CmdsApp -configuration Release -derivedDataPath "$DERIVED" build
fi
[ "$DRY_RUN" = 1 ] || [ -d "$BUILT_APP" ] || die "no build at $BUILT_APP"

# --- Sign ----------------------------------------------------------------------------------------------------

STAGE="$OUT/stage"
APP="$STAGE/cmds.app"
log "Copy and re-sign with Developer ID"
run rm -rf "$STAGE" "$DMG"
run mkdir -p "$STAGE"
run ditto "$BUILT_APP" "$APP"

if [ "$DRY_RUN" = 0 ]; then
  BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  [ "$BUILT_VERSION" = "$VERSION" ] || die "built app is $BUILT_VERSION, project.yml says $VERSION (rebuild without --skip-build)"
  [ -d "$APP/Contents/Resources/terminfo" ] && [ -d "$APP/Contents/Resources/ghostty/shell-integration" ] \
    || die "Ghostty's terminfo / shell integration are not in the app (vendor/ghostty/zig-out/share was missing at build time)"
fi

# Inside-out: nested code first (the bundled CLI), then the app. No --deep: it would apply the app's entitlements
# to the CLI. Every Mach-O must carry the hardened runtime and a secure timestamp, or notarization fails.
run codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP/Contents/Resources/bin/cmds"
run codesign --force --sign "$IDENTITY" --options runtime --timestamp --entitlements "$ENTITLEMENTS" "$APP"

log "Verify signature"
run codesign --verify --deep --strict --verbose=2 "$APP"
if [ "$DRY_RUN" = 0 ]; then
  # (Outputs are captured first: with pipefail, `codesign … | grep -q` can fail on SIGPIPE.)
  ENTS="$(codesign -d --entitlements - "$APP" 2>/dev/null)" || die "could not read the app's entitlements"
  case "$ENTS" in *get-task-allow*) die "get-task-allow is set: notarization would reject the app" ;; esac
  INFO="$(codesign -dvv "$APP" 2>&1)"
  case "$INFO" in *flags=*runtime*) ;; *) die "hardened runtime flag missing" ;; esac
  # Any Mach-O left without our signature (e.g. a new helper) would fail notarization.
  while IFS= read -r -d '' f; do
    case "$(file -b "$f")" in
      *Mach-O*)
        codesign --verify --strict "$f" 2>/dev/null || die "unsigned or invalid code: $f"
        INFO="$(codesign -dvv "$f" 2>&1)"
        case "$INFO" in *"TeamIdentifier=$TEAM_ID"*) ;; *) die "not signed by $TEAM_ID: $f" ;; esac
        case "$INFO" in *flags=*runtime*) ;; *) die "hardened runtime missing: $f" ;; esac
        ;;
    esac
  done < <(find "$APP" -type f -perm -u+x -print0)
fi

# --- DMG -----------------------------------------------------------------------------------------------------

log "Create $DMG_NAME"
DMG_ROOT="$OUT/dmg-root"
run rm -rf "$DMG_ROOT"
run mkdir -p "$DMG_ROOT"
run ditto "$APP" "$DMG_ROOT/cmds.app"
run ln -s /Applications "$DMG_ROOT/Applications"
run hdiutil create -volname "cmds $VERSION" -srcfolder "$DMG_ROOT" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
run codesign --force --sign "$IDENTITY" --timestamp "$DMG"
run codesign --verify --strict --verbose=2 "$DMG"

if [ "$SKIP_NOTARIZE" = 1 ]; then
  log "Skipping notarization: $DMG is signed but NOT notarized (do not publish it)"
  exit 0
fi

# --- Notarize ------------------------------------------------------------------------------------------------

log "Notarize (this uploads the DMG to Apple and waits)"
run xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 2h
# notarytool exits 0 even for an "Invalid" result in some versions: confirm Gatekeeper accepts the stapled DMG.
run xcrun stapler staple "$DMG"
run xcrun stapler validate "$DMG"
run spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

# --- Checksums and site/public/download/ ------------------------------------------------------------------

log "Checksums"
if [ "$DRY_RUN" = 1 ]; then
  run shasum -a 256 "$DMG"
  run cp "$DMG" "$SITE_DOWNLOAD/$DMG_NAME"
  echo "[dry-run] write $SITE_DOWNLOAD/SHA256SUMS and $SITE_DOWNLOAD/latest.json"
  exit 0
fi
SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
SIZE="$(stat -f %z "$DMG")"
mkdir -p "$SITE_DOWNLOAD"
cp "$DMG" "$SITE_DOWNLOAD/$DMG_NAME"
printf '%s  %s\n' "$SHA256" "$DMG_NAME" > "$SITE_DOWNLOAD/SHA256SUMS"
cat > "$SITE_DOWNLOAD/latest.json" <<EOF
{
  "version": "$VERSION",
  "build": "$BUILD_NUMBER",
  "file": "/download/$DMG_NAME",
  "size": $SIZE,
  "sha256": "$SHA256",
  "minimumSystemVersion": "14.0",
  "architectures": ["arm64"],
  "notarized": true,
  "date": "$(date -u +%Y-%m-%d)"
}
EOF

cat <<EOF

Done: $DMG
  version  $VERSION (build $BUILD_NUMBER)
  size     $SIZE bytes
  sha256   $SHA256
site/public/download/ now holds $DMG_NAME, SHA256SUMS and latest.json.
Next (by hand): put the version, size and SHA-256 into site/public/index.html and site/public/en/index.html (TODO(release) markers),
deploy the site, attach the DMG to the GitHub release (docs/internals/release.md).
EOF
