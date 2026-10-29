#!/bin/sh
# Regenerate the macOS and iOS app icons from design/icon/master-1024.png (full-bleed artwork).
#   macOS: composite into the Apple macOS grid (design/icon/macos-1024.png), then all mac sizes via sips.
#   iOS:   the master itself, flattened to RGB (no alpha, no rounded corners; iOS applies the mask).
# Usage: sh design/icon/tools/build_icons.sh   (requires python3 with Pillow, sips)
# See design/icon/README.md.
set -eu

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
ICON="$ROOT/design/icon"
MASTER="$ICON/master-1024.png"
MAC_SET="$ROOT/App/Resources/Assets.xcassets/AppIcon.appiconset"
IOS_SET="$ROOT/iOS/Resources/Assets.xcassets/AppIcon.appiconset"

python3 -I "$ICON/tools/compose_macos.py" "$MASTER" "$ICON/macos-1024.png"
python3 -I -c 'import sys; from PIL import Image
Image.open(sys.argv[1]).convert("RGB").resize((1024, 1024), Image.LANCZOS).save(sys.argv[2], "PNG")' \
  "$MASTER" "$IOS_SET/AppIcon-1024.png"

for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$ICON/macos-1024.png" --out "$MAC_SET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" "$ICON/macos-1024.png" --out "$MAC_SET/icon_${s}x${s}@2x.png" >/dev/null
done
echo "icons written to $MAC_SET and $IOS_SET"
