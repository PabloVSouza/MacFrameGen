#!/bin/zsh
# Builds MacFrameGen.app (Apple Silicon, macOS 26+). Needs only the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/MacFrameGen.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos26.0 \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/MacFrameGen"

cp Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# A fixed designated requirement keeps the app's identity stable across rebuilds, so macOS
# remembers the Camera/Microphone permission instead of treating each build as a new app.
codesign --force --sign - -r='designated => identifier "local.macframegen"' "$APP"
echo "Built $PWD/$APP"
