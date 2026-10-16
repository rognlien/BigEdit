#!/bin/sh
# Checks the SMAppService daemon layout in a built BigEdit.app.
#
# SMAppService.daemon(plistName:) reports little more than .notFound when the
# layout is wrong, and almost always because strings that must agree do not:
# the plist's file name, its launchd Label, its Mach service name, the path in
# BundleProgram, and the app's bundle identifier in AssociatedBundleIdentifiers.
# This checks all of them before a release does.
#
# Usage: scripts/verify-helper.sh [path/to/BigEdit.app]
set -e

APP="${1:-$(cd "$(dirname "$0")/.." && pwd)/BigEdit.app}"
HELPER_ID="io.maendeleo.BigEdit.daemon"
PLIST="$APP/Contents/Library/LaunchDaemons/$HELPER_ID.plist"
FAILURES=0

fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "  ok:   $1"; }

echo "Checking $APP"

[ -f "$PLIST" ] || { echo "  FAIL: no launchd plist at $PLIST" >&2; exit 1; }
pass "launchd plist present at Contents/Library/LaunchDaemons/$HELPER_ID.plist"

plutil -lint -s "$PLIST" \
    && pass "launchd plist is well formed" \
    || fail "launchd plist does not parse"

read_plist() { /usr/libexec/PlistBuddy -c "Print $2" "$1" 2>/dev/null || echo ""; }

LABEL=$(read_plist "$PLIST" ":Label")
MACH=$(read_plist "$PLIST" ":MachServices:$HELPER_ID")
PROGRAM=$(read_plist "$PLIST" ":BundleProgram")
ABSOLUTE_PROGRAM=$(read_plist "$PLIST" ":Program")
ASSOCIATED=$(read_plist "$PLIST" ":AssociatedBundleIdentifiers:0")
APP_ID=$(read_plist "$APP/Contents/Info.plist" ":CFBundleIdentifier")
HELPER="$APP/$PROGRAM"

[ "$LABEL" = "$HELPER_ID" ] \
    && pass "launchd Label matches the plist's file name" \
    || fail "launchd Label '$LABEL' != '$HELPER_ID'"

[ "$MACH" = "true" ] \
    && pass "MachServices advertises $HELPER_ID" \
    || fail "MachServices has no '$HELPER_ID' entry set to true"

[ -z "$ABSOLUTE_PROGRAM" ] \
    && pass "no absolute Program key" \
    || fail "Program '$ABSOLUTE_PROGRAM' is set; SMAppService needs BundleProgram only"

case "$PROGRAM" in
    Contents/*) pass "BundleProgram is relative to the bundle: $PROGRAM" ;;
    *) fail "BundleProgram '$PROGRAM' is not a path inside the bundle" ;;
esac

[ -n "$PROGRAM" ] && [ -f "$HELPER" ] && [ -x "$HELPER" ] \
    && pass "helper executable present at $PROGRAM" \
    || fail "no executable helper at '$PROGRAM'"

[ -n "$APP_ID" ] && [ "$ASSOCIATED" = "$APP_ID" ] \
    && pass "AssociatedBundleIdentifiers names the app ($APP_ID)" \
    || fail "AssociatedBundleIdentifiers '$ASSOCIATED' != app '$APP_ID'"

[ -z "$(read_plist "$APP/Contents/Info.plist" ":SMPrivilegedExecutables")" ] \
    && pass "app no longer declares SMPrivilegedExecutables" \
    || fail "app still declares SMPrivilegedExecutables, an SMJobBless leftover"

[ ! -e "$APP/Contents/Library/LaunchServices" ] \
    && pass "no SMJobBless Contents/Library/LaunchServices directory" \
    || fail "Contents/Library/LaunchServices exists, an SMJobBless leftover"

# Signing: only meaningful once an identity has been used.
APP_TEAM=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
HELPER_SIGNATURE=$(codesign -dv "$HELPER" 2>&1 || true)
if [ -n "$APP_TEAM" ] && [ "$APP_TEAM" != "not set" ]; then
    echo "$HELPER_SIGNATURE" | grep -q "TeamIdentifier=$APP_TEAM" \
        && pass "helper is signed by the app's team $APP_TEAM" \
        || fail "helper is not signed by the app's team $APP_TEAM"
    echo "$HELPER_SIGNATURE" | grep -q "^Identifier=$HELPER_ID$" \
        && pass "helper's signing identifier is $HELPER_ID" \
        || fail "helper's signing identifier is not $HELPER_ID"
    echo "$HELPER_SIGNATURE" | grep -q "flags=.*runtime" \
        && pass "helper uses the hardened runtime" \
        || fail "helper is not signed with the hardened runtime"
else
    echo "  note: the app is not signed by a team (expected for a local build;"
    echo "        SMAppService only registers the daemon from a signed build)"
fi

if [ "$FAILURES" -eq 0 ]; then
    echo "The SMAppService daemon layout is correct."
else
    echo "$FAILURES check(s) failed." >&2
    exit 1
fi
