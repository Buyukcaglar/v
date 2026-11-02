#!/bin/zsh
# Installs the viewer into /Applications and makes it the default app for all image types.
set -euo pipefail
cd "${0:A:h}"

SRC="build.noindex/V.app"
DEST="/Applications/V.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[[ -d "$SRC" ]] || ./build.sh
rm -rf "$DEST"
ditto "$SRC" "$DEST"
# Remove the build copy so Launchpad/Apps and "Open With" only list the installed app.
"$LSREGISTER" -u "$SRC" 2>/dev/null || true
rm -rf "$SRC"
"$LSREGISTER" -f "$DEST"
"$DEST/Contents/MacOS/V" --make-default
