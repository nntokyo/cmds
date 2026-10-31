#!/bin/sh
# Writes the Sparkle appcast for a Mac release (docs/internals/release.md#automatic-updates):
#
#   scripts/release/make-appcast.sh build/release/cmds-X.Y.Z.dmg [notes.html]
#
# Checks the app inside the DMG (valid signature, notarized), reads its version, build number and minimum macOS,
# signs the DMG with the EdDSA key ($SPARKLE_KEY_FILE, default ~/.keys/cmds-sparkle-ed25519; the same key is in the
# login keychain under the account "cmds") and writes site/public/download/appcast.xml with one item that downloads
# the DMG from the GitHub release vX.Y.Z. The build number must be higher than the one already in the feed: Sparkle
# compares build numbers, so a release without a new one would never reach anyone. The feed itself is signed last
# (the app sets SURequireSignedFeed), so edit it only through this script. notes.html (an HTML fragment) is shown in
# the update dialog; without it the CHANGELOG section is used.
# APPCAST_OUT and APPCAST_DOWNLOAD_URL override the output file and the download URL, and a .zip of cmds.app works in
# place of the DMG without the notarization check (end-to-end tests of the updater: Firebase Hosting refuses a DMG).
set -eu

abs() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$PWD" "$1" ;; esac; }
archive=$(abs "${1:?usage: make-appcast.sh <dmg|zip> [notes.html]}")
notes=${2:+$(abs "$2")}
key=$(abs "${SPARKLE_KEY_FILE:-$HOME/.keys/cmds-sparkle-ed25519}")
out=${APPCAST_OUT:+$(abs "$APPCAST_OUT")}
cd "$(dirname "$0")/../.."
out=${out:-$PWD/site/public/download/appcast.xml}

bin=$(find build -path '*SourcePackages/artifacts/sparkle/Sparkle/bin' -type d 2>/dev/null | head -1)
[ -n "$bin" ] || { echo "Sparkle tools not found: build the app once (xcodebuild -scheme CmdsApp ...)" >&2; exit 1; }
[ -r "$key" ] || { echo "no signing key at $key (generate_keys --account cmds -x <file> exports it)" >&2; exit 1; }

mnt=$(mktemp -d)
mounted=0
cleanup() {
  [ "$mounted" = 1 ] && hdiutil detach "$mnt" >/dev/null 2>&1
  rm -rf "$mnt" "$out.tmp" "$out.tmp.xml"
}
trap cleanup EXIT
case "$archive" in
  *.zip) ditto -x -k "$archive" "$mnt" ;;
  *) hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$archive" >/dev/null; mounted=1 ;;
esac
app="$mnt/cmds.app"
codesign --verify --deep --strict "$app" || { echo "$app: invalid signature" >&2; exit 1; }
case "$archive" in
  *.zip) ;;
  *) spctl -a -t exec -vv "$app" 2>&1 | grep -q 'source=Notarized Developer ID' \
       || { echo "$app is not notarized: publish only the notarized DMG" >&2; exit 1; } ;;
esac
plist="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")

if [ -f "$out" ]; then
  previous=$(sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' "$out" | head -1)
  if [ -n "$previous" ] && [ "$build" -le "$previous" ]; then
    echo "build $build is not higher than build $previous in $out: bump CURRENT_PROJECT_VERSION" >&2
    exit 1
  fi
fi

signature=$("$bin/sign_update" --ed-key-file "$key" -p "$archive")
length=$(stat -f %z "$archive")
url=${APPCAST_DOWNLOAD_URL:-https://github.com/nntokyo/cmds/releases/download/v$version/$(basename "$archive")}

VERSION=$version BUILD=$build MINIMUM=$minimum SIGNATURE=$signature LENGTH=$length URL=$url NOTES=$notes OUT=$out.tmp \
python3 -I - <<'EOF'
import email.utils, html, os, re

e = os.environ
version = e["VERSION"]
if e["NOTES"]:
    notes = open(e["NOTES"], encoding="utf-8").read().strip()
else:
    # The CHANGELOG section of this version as simple HTML: ### headings and "- " bullets (wrapped lines joined).
    text = open("CHANGELOG.md", encoding="utf-8").read()
    m = re.search(r"^## \[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=^## \[|^\[[^\]\n]+\]: |\Z)", text, re.S | re.M)
    if not m:
        raise SystemExit(f"no CHANGELOG section for {version}")
    out, items = [], []
    def flush():
        if items:
            out.append("<ul>" + "".join(f"<li>{i}</li>" for i in items) + "</ul>")
            items.clear()
    def inline(s):
        return re.sub(r"`([^`]+)`", r"<code>\1</code>", html.escape(s, quote=False))
    for line in m.group(1).splitlines():
        if line.startswith("### "):
            flush(); out.append(f"<h3>{inline(line[4:])}</h3>")
        elif line.startswith("- "):
            items.append(inline(line[2:].strip()))
        elif line.startswith("  ") and items:
            items[-1] += " " + inline(line.strip())
        elif line.strip():
            flush(); out.append(f"<p>{inline(line.strip())}</p>")
    flush()
    notes = "\n".join(out)
notes = notes.replace("]]>", "]]]]><![CDATA[>")  # cannot end the CDATA section early

feed = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>cmds</title>
    <link>https://cmds.n-n.tokyo/</link>
    <description>Updates of cmds for macOS</description>
    <language>en</language>
    <item>
      <title>cmds {html.escape(version)}</title>
      <link>https://github.com/nntokyo/cmds/releases/tag/v{html.escape(version)}</link>
      <sparkle:version>{html.escape(e["BUILD"])}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(e["MINIMUM"])}</sparkle:minimumSystemVersion>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <description><![CDATA[
{notes}
      ]]></description>
      <enclosure url="{html.escape(e["URL"])}" length="{e["LENGTH"]}" type="application/octet-stream" sparkle:edSignature="{html.escape(e["SIGNATURE"])}" />
    </item>
  </channel>
</rss>
"""
with open(e["OUT"], "w", encoding="utf-8") as f:
    f.write(feed)
EOF

# The feed's own signature goes into the file (sign_update recognises the .xml extension).
mv "$out.tmp" "$out.tmp.xml"
"$bin/sign_update" --ed-key-file "$key" "$out.tmp.xml" >/dev/null
grep -q 'sparkle-signatures:' "$out.tmp.xml" || { rm -f "$out.tmp.xml"; echo "the feed was not signed" >&2; exit 1; }
mv "$out.tmp.xml" "$out"
echo "$out: cmds $version ($build), $length bytes, $url"
