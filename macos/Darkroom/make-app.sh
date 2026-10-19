#!/bin/bash
# Assemble a development Darkroom.app around the SwiftPM build, so macOS treats it as a
# real application (menu bar, window server session, Liquid Glass). The engine and its
# dylibs are still found through the install prefix baked into the binary's rpath.
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-debug}"
swift build -c "$CONFIG"
BIN=".build/$CONFIG/Darkroom"
APP=".build/Darkroom.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Darkroom"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.stavo.darkroom</string>
  <key>CFBundleName</key><string>Darkroom</string>
  <key>CFBundleDisplayName</key><string>Darkroom</string>
  <key>CFBundleExecutable</key><string>Darkroom</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSEnvironment</key>
  <dict><key>MallocLargeCache</key><string>0</string></dict>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>Raw image</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSItemContentTypes</key><array><string>public.camera-raw-image</string><string>public.image</string></array>
  </dict></array>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "$APP"
