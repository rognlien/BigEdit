#!/bin/sh
# Builds BigEdit.app — a standalone macOS app bundle that runs independently
# of any terminal (unlike `swift run`, whose process dies with its shell).
set -e
cd "$(dirname "$0")"

# Bundle metadata. CI overrides MARKETING_VERSION / BUILD_NUMBER from the git
# tag and run number; locally they fall back to the defaults below.
BUNDLE_ID="${BUNDLE_ID:-io.maendeleo.BigEdit}"
MARKETING_VERSION="${MARKETING_VERSION:-0.7}"
BUILD_NUMBER="${BUILD_NUMBER:-7}"
COPYRIGHT="${COPYRIGHT:-© 2026 Bendik Johansen}"

swift build -c release

APP="BigEdit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BigEdit "$APP/Contents/MacOS/BigEdit"

# --- App icon -----------------------------------------------------------------
# Slices the 1024² master Resources/AppIcon.png into a full multi-resolution
# .icns via sips + iconutil (both ship with macOS — no extra dependency).
# Regenerate the master from new artwork with tools/make-icon.swift.
ICON_PNG="Resources/AppIcon.png"
ICON_KEY=""
if [ -f "$ICON_PNG" ]; then
    PNGS=$(mktemp -d)
    ICONSET="$PNGS/AppIcon.iconset"
    mkdir -p "$ICONSET"

    for spec in \
        "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
        "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
        "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
        px="${spec%%:*}"
        name="${spec##*:}"
        sips -z "$px" "$px" "$ICON_PNG" --out "$ICONSET/$name.png" >/dev/null
    done

    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$PNGS"
    ICON_KEY='    <key>CFBundleIconFile</key><string>AppIcon</string>'
fi

# --- Info.plist ---------------------------------------------------------------
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>BigEdit</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>BigEdit</string>
    <key>CFBundleDisplayName</key><string>BigEdit</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>NSHumanReadableCopyright</key><string>${COPYRIGHT}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Text Document</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.plain-text</string>
                <string>public.text</string>
                <string>public.source-code</string>
                <string>public.xml</string>
                <string>public.json</string>
                <string>public.html</string>
            </array>
        </dict>
    </array>
$ICON_KEY
</dict>
</plist>
PLIST

# --- Code signing (optional) --------------------------------------------------
# When SIGN_IDENTITY is set (e.g. in CI, or locally for a release build), sign
# the bundle with the hardened runtime so it can be notarized. Plain local
# builds leave SIGN_IDENTITY unset and ship unsigned.
if [ -n "${SIGN_IDENTITY:-}" ]; then
    ENTITLEMENTS="${ENTITLEMENTS:-BigEdit.entitlements}"
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/BigEdit"
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    echo "Signed $APP with: $SIGN_IDENTITY"
fi

echo "Built $APP — launch with: open $APP"
