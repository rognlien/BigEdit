#!/bin/sh
# Checks the SMJobBless preconditions in a built BigEdit.app.
#
# SMJobBless fails with a single unhelpful boolean, and almost always because
# two strings that must agree do not: the helper's bundle identifier, its
# launchd label, its Mach service name, its filename, and the requirement
# strings in the app's SMPrivilegedExecutables and the helper's
# SMAuthorizedClients. This checks all of them before a release does.
#
# Usage: scripts/verify-helper.sh [path/to/BigEdit.app]
set -e

APP="${1:-$(cd "$(dirname "$0")/.." && pwd)/BigEdit.app}"
HELPER_ID="io.maendeleo.BigEdit.helper"
HELPER="$APP/Contents/Library/LaunchServices/$HELPER_ID"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "  ok:   $1"; }

echo "Checking $APP"

[ -f "$HELPER" ] || { echo "  FAIL: no helper at $HELPER" >&2; exit 1; }
pass "helper present at Contents/Library/LaunchServices/$HELPER_ID"

# Pull the two embedded plists back out of the binary. otool prints the section
# as little-endian 4-byte words, so each group of eight hex digits has to be
# byte-reversed before it reads as text.
extract_section() {
    otool -X -s __TEXT "$1" "$HELPER" 2>/dev/null | python3 -c '
import sys
data = bytearray()
for line in sys.stdin:
    for word in line.split()[1:]:
        # Words are little-endian; the last one may be short.
        if len(word) % 2 == 0 and all(c in "0123456789abcdefABCDEF" for c in word):
            data.extend(bytes.fromhex(word)[::-1])
text = data.decode("utf-8", "ignore")
end = text.find("</plist>")
sys.stdout.write(text[:end + len("</plist>")] if end != -1 else "")
'
}

for section in info_plist launchd_plist; do
    extract_section "__$section" > "$WORK/$section.plist" 2>/dev/null || true
    if [ -s "$WORK/$section.plist" ]; then
        pass "__TEXT,__$section is embedded"
    else
        fail "__TEXT,__$section is missing — SMJobBless will refuse the helper"
    fi
done

read_plist() { /usr/libexec/PlistBuddy -c "Print $2" "$1" 2>/dev/null || echo ""; }

HELPER_BUNDLE_ID=$(read_plist "$WORK/info_plist.plist" ":CFBundleIdentifier")
LABEL=$(read_plist "$WORK/launchd_plist.plist" ":Label")
MACH=$(/usr/libexec/PlistBuddy -c "Print :MachServices" "$WORK/launchd_plist.plist" 2>/dev/null \
    | sed -n '2p' | sed 's/ *=.*//' | tr -d ' ')
AUTHORIZED=$(read_plist "$WORK/info_plist.plist" ":SMAuthorizedClients:0")
PRIVILEGED=$(read_plist "$APP/Contents/Info.plist" ":SMPrivilegedExecutables:$HELPER_ID")
APP_ID=$(read_plist "$APP/Contents/Info.plist" ":CFBundleIdentifier")

[ "$HELPER_BUNDLE_ID" = "$HELPER_ID" ] \
    && pass "helper CFBundleIdentifier matches its filename" \
    || fail "helper CFBundleIdentifier '$HELPER_BUNDLE_ID' != filename '$HELPER_ID'"

[ "$LABEL" = "$HELPER_ID" ] \
    && pass "launchd Label matches" \
    || fail "launchd Label '$LABEL' != '$HELPER_ID'"

[ "$MACH" = "$HELPER_ID" ] \
    && pass "MachServices name matches" \
    || fail "MachServices name '$MACH' != '$HELPER_ID'"

[ -n "$PRIVILEGED" ] \
    && pass "app declares SMPrivilegedExecutables[$HELPER_ID]" \
    || fail "app has no SMPrivilegedExecutables entry for $HELPER_ID"

[ -n "$AUTHORIZED" ] \
    && pass "helper declares SMAuthorizedClients" \
    || fail "helper has no SMAuthorizedClients"

# The requirements must name each other's identifier, and the same team.
echo "$PRIVILEGED" | grep -q "identifier \"$HELPER_ID\"" \
    && pass "app's requirement names the helper" \
    || fail "app's requirement does not name $HELPER_ID: $PRIVILEGED"

echo "$AUTHORIZED" | grep -q "identifier \"$APP_ID\"" \
    && pass "helper's requirement names the app" \
    || fail "helper's requirement does not name $APP_ID: $AUTHORIZED"

team_of() { echo "$1" | sed -n 's/.*subject.OU\] *= *"\{0,1\}\([A-Z0-9]*\)"\{0,1\}.*/\1/p'; }
APP_TEAM=$(team_of "$PRIVILEGED")
HELPER_TEAM=$(team_of "$AUTHORIZED")
if [ -n "$APP_TEAM" ] && [ "$APP_TEAM" = "$HELPER_TEAM" ]; then
    pass "both requirements name team $APP_TEAM"
else
    fail "team mismatch: app '$APP_TEAM' vs helper '$HELPER_TEAM'"
fi

# Signing: only meaningful once an identity has been used.
if codesign -dv "$HELPER" 2>&1 | grep -q "TeamIdentifier=$APP_TEAM"; then
    pass "helper is signed by team $APP_TEAM"
else
    echo "  note: helper is not signed by $APP_TEAM (expected for a local build;"
    echo "        SMJobBless only works from a signed, notarized build)"
fi

if [ "$FAILURES" -eq 0 ]; then
    echo "All SMJobBless preconditions hold."
else
    echo "$FAILURES precondition(s) failed." >&2
    exit 1
fi
