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
# Must match the team in SMAuthorizedClients inside the helper's embedded
# Info.plist (Sources/BigEditHelper/Info.plist); SMJobBless checks both
# directions and fails flatly if they disagree.
TEAM_ID="${TEAM_ID:-PDZ5N3HH4K}"
HELPER_ID="io.maendeleo.BigEdit.helper"
SU_FEED_URL="${SU_FEED_URL:-https://maendeleo.io/bigedit/appcast.xml}"
SU_PUBLIC_ED_KEY="${SU_PUBLIC_ED_KEY:-cBwIeAvJj5h55dQEnOqFvfm9wE8ZkFb5VFI/wgiKTSs=}"

swift build -c release

APP="BigEdit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/BigEdit "$APP/Contents/MacOS/BigEdit"
# The command line tool ships under its real name in SharedSupport/bin —
# NOT in MacOS/, where the case-insensitive filesystem would make
# `bigedit` and `BigEdit` the same file. BigEdit symlinks this onto the
# user's PATH.
mkdir -p "$APP/Contents/SharedSupport/bin"
cp .build/release/BigEditTool "$APP/Contents/SharedSupport/bin/bigedit"

# The privileged helper. SMJobBless looks for it by bundle identifier in
# Contents/Library/LaunchServices, so the filename is the identifier.
mkdir -p "$APP/Contents/Library/LaunchServices"
cp .build/release/BigEditHelper "$APP/Contents/Library/LaunchServices/$HELPER_ID"

# --- Embed Sparkle.framework --------------------------------------------------
# SwiftPM builds against Sparkle but doesn't bundle it; copy it in and add the
# rpath so the embedded copy is found at runtime.
ditto .build/release/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks \
    "$APP/Contents/MacOS/BigEdit" 2>/dev/null || true

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
    <key>SUFeedURL</key><string>${SU_FEED_URL}</string>
    <key>SUPublicEDKey</key><string>${SU_PUBLIC_ED_KEY}</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
    <key>SMPrivilegedExecutables</key>
    <dict>
        <key>${HELPER_ID}</key>
        <string>identifier "${HELPER_ID}" and anchor apple generic and certificate leaf[subject.OU] = "${TEAM_ID}"</string>
    </dict>
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
        <dict>
            <!-- BigEdit opens anything: huge logs and dumps routinely have no
                 extension, or one macOS maps to public.data. Without this the
                 Dock refuses the drop before the app is ever asked. Ranked
                 Alternate so it appears under "Open With" without claiming to
                 be the default for every file on the disk. public.data covers
                 files but not folders, which BigEdit cannot open anyway. -->
            <key>CFBundleTypeName</key>
            <string>Any File</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.data</string>
            </array>
        </dict>
        <dict>
            <!-- The wildcard extension is the older mechanism, and the only one
                 Launch Services honours for arbitrary extensions: declaring
                 public.data above covers files with no extension, but a .dat or
                 .bin is still refused without this. Kept in its own entry
                 because LSItemContentTypes takes precedence over
                 CFBundleTypeExtensions when both appear together. -->
            <key>CFBundleTypeName</key>
            <string>Any Extension</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>*</string>
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

    # Sign Sparkle inside-out (no --deep): XPC services, helper tools, then the
    # framework — all with the hardened runtime so the bundle can be notarized.
    FW="$APP/Contents/Frameworks/Sparkle.framework"
    SPARKLE_V="$FW/Versions/Current"
    for xpc in "$SPARKLE_V"/XPCServices/*.xpc; do
        [ -e "$xpc" ] || continue
        codesign --force --options runtime --timestamp \
            --preserve-metadata=entitlements --sign "$SIGN_IDENTITY" "$xpc"
    done
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$SPARKLE_V/Updater.app"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$SPARKLE_V/Autoupdate"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$FW"

    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$APP/Contents/SharedSupport/bin/bigedit"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$APP/Contents/Library/LaunchServices/$HELPER_ID"
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
