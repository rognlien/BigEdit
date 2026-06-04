#!/bin/sh
# Packages BigEdit.app into a compressed DMG with a drag-to-install
# /Applications shortcut. Run ./make-app.sh first to produce the bundle.
#
# Usage: scripts/make-dmg.sh [output.dmg]
# When SIGN_IDENTITY is set, the resulting DMG is signed with that identity
# (notarization is handled separately, in the release workflow).
set -e
cd "$(dirname "$0")/.."

APP="BigEdit.app"
DMG="${1:-BigEdit.dmg}"
VOLUME_NAME="BigEdit"

if [ ! -d "$APP" ]; then
    echo "error: $APP not found — run ./make-app.sh first" >&2
    exit 1
fi

STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG"

rm -rf "$STAGING"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    echo "Signed $DMG with: $SIGN_IDENTITY"
fi

echo "Built $DMG"
