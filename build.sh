#!/bin/bash
# Builds MiddleTap.app. Requires Xcode Command Line Tools:  xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

APP="build/MiddleTap.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

clang -fobjc-arc -O2 -Wall -arch arm64 -mmacosx-version-min=13.0 \
  -framework Cocoa -framework ApplicationServices -framework ServiceManagement \
  main.m -o "$APP/Contents/MacOS/MiddleTap"

cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"   # ad-hoc signature (needed on Apple silicon)

echo "Built $APP"
if [[ "${1:-}" == "--install" ]]; then
  pkill -x MiddleTap 2>/dev/null || true
  rm -rf /Applications/MiddleTap.app
  cp -R "$APP" /Applications/
  touch /Applications/MiddleTap.app   # nudge Finder to refresh the icon
  echo "Installed to /Applications/MiddleTap.app"
  open /Applications/MiddleTap.app
fi
