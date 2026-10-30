#!/bin/sh
# Adds new strings from the last build to the String Catalogs and marks removed ones stale
# (docs/ARCHITECTURE.md "Localization"). Xcode does the same when you build in the IDE; this is for xcodebuild.
#
#   xcodebuild ... -scheme CmdsApp -derivedDataPath build/dd build            # then:
#   xcodebuild ... -scheme CmdsCompanion -derivedDataPath build/dd-ios build  # then:
#   scripts/l10n-sync.sh
#
# Then add the Japanese for new keys (Xcode's catalog editor, or edit the JSON) and commit the .xcstrings.
set -eu
cd "$(dirname "$0")/.."

sync() { # catalog, intermediates dir of the target
    files=$(find "$2" -path '*/arm64/*' -name '*.stringsdata' ! -name 'ExtractedAppShortcutsMetadata*' 2>/dev/null | sort)
    if [ -z "$files" ]; then
        echo "skip $1: no .stringsdata under $2 (build first)"
        return
    fi
    set --  "$1" $(printf -- '--stringsdata %s ' $files)
    xcrun xcstringstool sync "$@"
    echo "synced $1"
}

sync App/Resources/Localizable.xcstrings build/dd/Build/Intermediates.noindex/cmds.build/Debug/cmds.build
sync iOS/Resources/Localizable.xcstrings build/dd-ios/Build/Intermediates.noindex/cmds.build/Debug-iphonesimulator/CmdsCompanion.build
