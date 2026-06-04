#!/bin/sh
# Packages BigEdit.app into a DMG. With `appdmg` installed (npm install -g
# appdmg) it builds the styled installer window — app icon on the left, an
# arrow, and the Applications folder on the right, so the user just drags across
# to install. Without appdmg it falls back to a plain DMG with an /Applications
# shortcut. Run ./make-app.sh first to produce the bundle.
#
# Usage: scripts/make-dmg.sh [output.dmg]
# When SIGN_IDENTITY is set, the resulting DMG is signed with that identity
# (notarization is handled separately, in the release workflow).
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

APP="BigEdit.app"
DMG="${1:-BigEdit.dmg}"
VOLUME_NAME="BigEdit"

if [ ! -d "$APP" ]; then
    echo "error: $APP not found — run ./make-app.sh first" >&2
    exit 1
fi

rm -f "$DMG"

if command -v appdmg >/dev/null 2>&1; then
    SPECDIR="$(mktemp -d)"
    SPEC="$SPECDIR/spec.json"          # appdmg requires a .json spec
    cat > "$SPEC" <<JSON
{
  "title": "$VOLUME_NAME",
  "icon": "$ROOT/$APP/Contents/Resources/AppIcon.icns",
  "background": "$ROOT/Resources/dmg-background.png",
  "icon-size": 128,
  "window": { "size": { "width": 600, "height": 400 } },
  "contents": [
    { "x": 150, "y": 190, "type": "file", "path": "$ROOT/$APP" },
    { "x": 450, "y": 190, "type": "link", "path": "/Applications" }
  ]
}
JSON
    appdmg "$SPEC" "$DMG"
    rm -rf "$SPECDIR"
else
    echo "note: appdmg not found — building a plain DMG." >&2
    echo "      Run 'npm install -g appdmg' for the styled installer window." >&2
    STAGING="$(mktemp -d)"
    cp -R "$APP" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
    rm -rf "$STAGING"
fi

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    echo "Signed $DMG with: $SIGN_IDENTITY"
fi

echo "Built $DMG"
