#!/bin/bash
# Builds the noVNC Bar menu bar app and (re)installs it to /Applications.
# Usage: ./build.sh [--launch]
set -euo pipefail
cd "$(dirname "$0")"

NAME="NoVNCBar"
APP="/Applications/$NAME.app"
BINARY="$APP/Contents/MacOS/$NAME"

echo "• Compiling…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# -swift-version 5 keeps concurrency checking lenient for this small tool.
swiftc -O -swift-version 5 -o "$BINARY" App.swift

echo "• Writing Info.plist…"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>NoVNCBar</string>
    <key>CFBundleIdentifier</key><string>io.github.minons1.novncbar</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>noVNC Bar</string>
    <key>CFBundleDisplayName</key><string>noVNC Bar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so Gatekeeper/LaunchServices treat the bundle as a proper app.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "• Installed to $APP"

if [[ "${1:-}" == "--launch" ]]; then
    pkill -x "$NAME" 2>/dev/null || true
    sleep 0.5
    open -a "$APP"
    echo "• Launched — look for the eye icon in the menu bar"
fi
