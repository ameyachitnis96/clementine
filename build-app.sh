#!/bin/zsh
# Builds Clementine.app (menu-bar only, ad-hoc signed) into ./dist.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release -q --arch arm64 --arch x86_64
APP=dist/Clementine.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ICONS=$(mktemp -d)
swift Scripts/make-icon.swift "$ICONS"
iconutil -c icns "$ICONS/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONS"
cp "$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Clementine" "$APP/Contents/MacOS/Clementine"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.clementine.app</string>
  <key>CFBundleName</key><string>Clementine</string>
  <key>CFBundleDisplayName</key><string>Clementine</string>
  <key>CFBundleExecutable</key><string>Clementine</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Ameya Chitnis. MIT License.</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "$PWD/$APP"
