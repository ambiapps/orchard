#!/bin/bash
# Builds Orchard.app and packages it as build/Orchard-<version>-<build>.dmg with an Applications shortcut.
# Prints the DMG path on the last line. SIGN_IDENTITY (see build-app.sh) also signs the DMG when it isn't ad-hoc.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DMG="build/Orchard-$VERSION-$BUILD_NUMBER.dmg"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"

BUILD_NUMBER="$BUILD_NUMBER" SIGN_IDENTITY="$SIGN_IDENTITY" ./scripts/build-app.sh

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R build/Orchard.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "Orchard" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
echo "$DMG"
