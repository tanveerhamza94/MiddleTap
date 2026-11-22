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

# Sign with a stable certificate so macOS keeps the Accessibility permission across
# rebuilds. Falls back to ad-hoc signing (permission must be re-granted each build).
IDENTITY="MiddleTap Self-Signed"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" --identifier com.hamza.middletap "$APP"
else
  echo "⚠️  No \"$IDENTITY\" certificate found. Run ./make-signing-cert.sh once so"
  echo "   rebuilds keep their Accessibility permission. Using ad-hoc signing for now."
  codesign --force --sign - "$APP"
fi

echo "Built $APP"
if [[ "${1:-}" == "--install" ]]; then
  pkill -x MiddleTap 2>/dev/null || true
  rm -rf /Applications/MiddleTap.app
  cp -R "$APP" /Applications/
  touch /Applications/MiddleTap.app   # nudge Finder to refresh the icon
  echo "Installed to /Applications/MiddleTap.app"
  open /Applications/MiddleTap.app
fi
