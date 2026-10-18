#!/bin/bash
# Builds Orchard.app and packages it as build/Orchard-<version>-<build>.dmg with an Applications shortcut.
# Prints the DMG path on the last line.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DMG="build/Orchard-$VERSION-$BUILD_NUMBER.dmg"

BUILD_NUMBER="$BUILD_NUMBER" ./scripts/build-app.sh

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R build/Orchard.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "Orchard" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
echo "$DMG"
