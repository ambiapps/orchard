#!/bin/bash
# Builds Orchard.app into ./build. Pass --install to copy it to ~/Applications and open it.
# The version comes from ./VERSION; set BUILD_NUMBER to stamp CFBundleVersion (CI uses the run number).
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Orchard.app"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Orchard"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Orchard"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Orchard</string>
    <key>CFBundleDisplayName</key><string>Orchard</string>
    <key>CFBundleIdentifier</key><string>se.ambi.Orchard</string>
    <key>CFBundleExecutable</key><string>Orchard</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP ($VERSION, build $BUILD_NUMBER)"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    pkill -x Orchard 2>/dev/null || true
    rm -rf ~/Applications/Orchard.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/Orchard.app
    echo "Installed to ~/Applications/Orchard.app"
fi
