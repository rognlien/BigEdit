#!/bin/sh
# Cross-checks BigEdit's handling of a Windows-1252 file against iconv: the
# decoded rows, a literal search for a non-ASCII word, a regular expression
# over non-ASCII letters, and the character count.
#
# Usage: scripts/verify-encodings.sh
set -e
BIGEDIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="${BINARY:-$BIGEDIT_DIR/.build/debug/BigEdit}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILURES=0
ok()   { echo "  ok:   $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

UTF8="$WORK/utf8.txt"
LEGACY="$WORK/legacy.txt"
awk 'BEGIN { srand(3); for (i = 0; i < 20000; i++) {
    line = i " ";
    n = int(rand() * 5);
    for (j = 0; j < n; j++) line = line (rand() < 0.3 ? "blåbærgrød" : (rand() < 0.5 ? "café" : "über")) " ";
    if (i % 250 == 0) line = line "€ 1,50";
    print line } }' > "$UTF8"
iconv -f UTF-8 -t WINDOWS-1252 "$UTF8" > "$LEGACY"

"$BINARY" --stats "$LEGACY" | grep -q "encoding: Windows-1252" \
    && ok "detected as Windows-1252" || fail "not detected as Windows-1252"

"$BINARY" --dump "$LEGACY" 500 > "$WORK/mine.txt"
head -n 500 "$UTF8" > "$WORK/theirs.txt"
diff -q "$WORK/mine.txt" "$WORK/theirs.txt" > /dev/null \
    && ok "first 500 rows decode exactly as iconv does" || fail "decoded rows differ from iconv"

mine=$("$BINARY" --search "blåbærgrød" "$LEGACY" | awk '/^matches:/ {print $2}')
theirs=$(grep -o "blåbærgrød" "$UTF8" | wc -l | tr -d ' ')
[ "$mine" = "$theirs" ] && ok "literal search for blåbærgrød → $mine" \
    || fail "literal search: BigEdit $mine, grep $theirs"

mine=$("$BINARY" --search-regex "[åæøü]+" "$LEGACY" | awk '/^matches:/ {print $2}')
theirs=$(grep -oE "[åæøü]+" "$UTF8" | wc -l | tr -d ' ')
[ "$mine" = "$theirs" ] && ok "regex [åæøü]+ → $mine" \
    || fail "regex: BigEdit $mine, grep -oE $theirs"

mine=$("$BINARY" --stats "$LEGACY" | awk '/^chars:/ {print $2}')
theirs=$(wc -m < "$UTF8" | tr -d ' ')
[ "$mine" = "$theirs" ] && ok "character count → $mine (= wc -m of the UTF-8 text)" \
    || fail "characters: BigEdit $mine, wc -m $theirs"

if [ "$FAILURES" -eq 0 ]; then echo "All encoding checks match iconv."; else echo "$FAILURES check(s) failed." >&2; exit 1; fi
