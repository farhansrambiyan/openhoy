#!/usr/bin/env bash
# Builds OpenHoy.app into ./build. Works with just the Xcode Command Line Tools.
#   scripts/build-app.sh            # release build
#   scripts/build-app.sh --install  # …and copy to ~/Applications, then launch
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/OpenHoy.app"
IDENTITY="${SIGN_IDENTITY:--}"

echo "› swift build ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/OpenHoy"

echo "› assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OpenHoy"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns ]]; then
  echo "› rendering icon"
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  swift scripts/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "› signing ($IDENTITY)"
codesign --force --sign "$IDENTITY" --identifier app.openhoy.OpenHoy "$APP"

echo "✓ built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x OpenHoy 2>/dev/null || true
  rm -rf "$HOME/Applications/OpenHoy.app"
  cp -R "$APP" "$HOME/Applications/OpenHoy.app"
  open "$HOME/Applications/OpenHoy.app"
  echo "✓ installed to ~/Applications/OpenHoy.app"
fi
