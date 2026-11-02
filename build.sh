#!/bin/zsh
# Builds "V.app" (universal arm64 + x86_64) into ./build.noindex.
set -euo pipefail
cd "${0:A:h}"

APP="build.noindex/V.app"

rm -rf "$APP" build.noindex/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build.noindex/obj

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
    -o "build.noindex/obj/viewer-$arch" Sources/*.swift
done
lipo -create build.noindex/obj/viewer-* -output "$APP/Contents/MacOS/V"

cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Icon Composer icon: light and dark backgrounds that follow the system theme on macOS 26,
# plus a V.icns fallback for older systems.
xcrun actool Resources/V.icon --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 13.0 --app-icon V \
  --output-partial-info-plist build.noindex/obj/icon-info.plist >/dev/null

codesign --force --sign - "$APP"
echo "Built $APP"
