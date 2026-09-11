#!/bin/sh
# Cross-checks --search-regex against grep -oE, the same way --search is
# checked against grep -oa. Both count non-overlapping, non-empty matches within
# lines, so the counts must agree exactly.
#
# Usage: scripts/verify-search-regex.sh [file]   (a 300k-line file is generated if none is given)
set -e
BIGEDIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="${BINARY:-$BIGEDIT_DIR/.build/debug/BigEdit}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FILE="${1:-}"
if [ -z "$FILE" ]; then
    FILE="$WORK/sample.txt"
    awk 'BEGIN { srand(7); for (i = 0; i < 200000; i++) {
        n = int(rand() * 6);
        line = i;
        for (j = 0; j < n; j++) line = line " " (rand() < 0.5 ? "error" : "ok") "-" int(rand() * 1000);
        if (i % 977 == 0) line = line " Käse ñandú";
        print line } }' > "$FILE"
fi

FAILURES=0
for pattern in '[0-9]+' '^[0-9]+ error' 'error-[0-9]{2}$' 'ok-(1|2)[0-9]*' 'ñandú|Käse' 'zzz-never'; do
    report=$("$BINARY" --search-regex "$pattern" "$FILE" | awk '/^matches:/ {print $2, $3}')
    mine=${report%% *}
    theirs=$(LC_ALL=en_US.UTF-8 grep -oE -- "$pattern" "$FILE" | wc -l | tr -d ' ')
    if [ "$mine" = "$theirs" ]; then
        echo "  ok:   $pattern → $mine"
    elif [ "$report" != "$mine" ] && [ "$theirs" -ge "$mine" ]; then
        # BigEdit stops collecting at its display cap; grep does not.
        echo "  ok:   $pattern → capped at $mine (grep -oE $theirs)"
    else
        echo "  FAIL: $pattern → BigEdit $mine, grep -oE $theirs" >&2
        FAILURES=$((FAILURES + 1))
    fi
done
if [ "$FAILURES" -eq 0 ]; then
    echo "All regular-expression counts match grep -oE."
else
    echo "$FAILURES pattern(s) disagree." >&2
    exit 1
fi
