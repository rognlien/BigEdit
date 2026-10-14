#!/bin/sh
# Cross-checks --replace-regex against perl -pe 's/pattern/template/g', which
# shares ICU's $1 template syntax. The streaming replace reads the file in
# windows cut at line boundaries, so this is where a window boundary that
# dropped or doubled a line would show.
#
# Usage: scripts/verify-replace-regex.sh [file]   (a 200k-line file is generated if none is given)
set -e
BIGEDIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="${BINARY:-$BIGEDIT_DIR/.build/debug/BigEdit}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FILE="${1:-}"
if [ -z "$FILE" ]; then
    FILE="$WORK/sample.txt"
    awk 'BEGIN { srand(11); for (i = 0; i < 200000; i++) {
        n = int(rand() * 6);
        line = "row " i;
        for (j = 0; j < n; j++) line = line " " (rand() < 0.5 ? "error" : "ok") "=" int(rand() * 1000);
        if (i % 977 == 0) line = line " Käse ñandú";
        print line } }' > "$FILE"
fi

FAILURES=0
check() {
    pattern="$1"
    template="$2"
    "$BINARY" --replace-regex "$pattern" "$template" "$FILE" "$WORK/mine.txt" > /dev/null
    LC_ALL=en_US.UTF-8 perl -CSD -Mutf8 -pe "s/$pattern/$template/g" "$FILE" > "$WORK/theirs.txt"
    if cmp -s "$WORK/mine.txt" "$WORK/theirs.txt"; then
        echo "  ok:   s/$pattern/$template/g"
    else
        echo "  FAIL: s/$pattern/$template/g" >&2
        diff "$WORK/theirs.txt" "$WORK/mine.txt" | head -10 >&2
        FAILURES=$((FAILURES + 1))
    fi
}

check '(error|ok)=([0-9]+)' '$2:$1'
check '^row ([0-9]+)' 'line $1'
check 'ñandú' 'rhea'
check 'zzz-never' 'x'
check '([0-9])([0-9])$' '$2$1'

if [ "$FAILURES" -eq 0 ]; then
    echo "All regular-expression replacements match perl -pe."
else
    echo "$FAILURES replacement(s) disagree." >&2
    exit 1
fi
