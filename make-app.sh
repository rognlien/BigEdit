#!/bin/sh
# Builds BigEdit.app — a standalone macOS app bundle that runs independently
# of any terminal (unlike `swift run`, whose process dies with its shell).
set -e
cd "$(dirname "$0")"

swift build -c release

APP="BigEdit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BigEdit "$APP/Contents/MacOS/BigEdit"

# --- App icon -----------------------------------------------------------------
# Renders Resources/AppIcon.svg into a full multi-resolution .icns via
# rsvg-convert + iconutil. Skipped (without failing) if rsvg-convert is missing.
ICON_SVG="Resources/AppIcon.svg"
ICON_KEY=""
if [ -f "$ICON_SVG" ] && command -v rsvg-convert >/dev/null; then
    PNGS=$(mktemp -d)
    ICONSET="$PNGS/AppIcon.iconset"
    mkdir -p "$ICONSET"

    for size in 16 32 64 128 256 512 1024; do
        rsvg-convert -w "$size" -h "$size" "$ICON_SVG" -o "$PNGS/$size.png"
    done

    cp "$PNGS/16.png"   "$ICONSET/icon_16x16.png"
    cp "$PNGS/32.png"   "$ICONSET/icon_16x16@2x.png"
    cp "$PNGS/32.png"   "$ICONSET/icon_32x32.png"
    cp "$PNGS/64.png"   "$ICONSET/icon_32x32@2x.png"
    cp "$PNGS/128.png"  "$ICONSET/icon_128x128.png"
    cp "$PNGS/256.png"  "$ICONSET/icon_128x128@2x.png"
    cp "$PNGS/256.png"  "$ICONSET/icon_256x256.png"
    cp "$PNGS/512.png"  "$ICONSET/icon_256x256@2x.png"
    cp "$PNGS/512.png"  "$ICONSET/icon_512x512.png"
    cp "$PNGS/1024.png" "$ICONSET/icon_512x512@2x.png"

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
    <key>CFBundleIdentifier</key><string>dev.bigedit.BigEdit</string>
    <key>CFBundleName</key><string>BigEdit</string>
    <key>CFBundleDisplayName</key><string>BigEdit</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>0.7</string>
    <key>CFBundleVersion</key><string>7</string>
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

echo "Built $APP — launch with: open $APP"
