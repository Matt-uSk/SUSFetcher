#!/bin/bash
# Construit "SUS Fetcher.app" (Apple Silicon) dans ./build
set -euo pipefail
cd "$(dirname "$0")"

# Version : argument, sinon variable VERSION, sinon 1.0.0 (ex. ./build-app.sh 1.2.0)
VERSION="${1:-${VERSION:-1.0.0}}"
VERSION="${VERSION#v}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/SUSFetcher"

APP="build/SUS Fetcher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SUSFetcher"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>SUS Fetcher</string>
    <key>CFBundleDisplayName</key><string>SUS Fetcher</string>
    <key>CFBundleIdentifier</key><string>local.susfetcher</string>
    <key>CFBundleExecutable</key><string>SUSFetcher</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Signature ad-hoc (suffisant en local ; remplacer "-" par ton Developer ID pour distribuer)
codesign --force --deep --sign - "$APP"

# Force le Finder / Dock à relire l'icône si l'app existait déjà
touch "$APP"

echo "OK → $APP (v$VERSION)"
