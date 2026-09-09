#!/bin/sh
# Cross-checks BigEdit's line operations against the POSIX tools that already
# do the same jobs — the same shape of check as --search against grep.
#
# Usage: scripts/verify-process-lines.sh
set -e

BIGEDIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="${BINARY:-$BIGEDIT_DIR/.build/debug/BigEdit}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

check() {
    if diff -u "$2" "$3" > "$WORK/diff.txt"; then
        echo "  ok:   $1"
    else
        echo "  FAIL: $1" >&2
        head -20 "$WORK/diff.txt" >&2
        FAILURES=$((FAILURES + 1))
    fi
}

IN="$WORK/in.txt"
cat > "$IN" <<'TXT'
banana
apple
banana
cherry
apple
date fruit
elderberry
banana
fig
TXT

# Remove duplicates, keeping first occurrence — awk is the standard idiom
# (uniq only collapses adjacent lines, which is a different operation).
"$BINARY" --process-lines dedupe "$IN" "$WORK/mine.txt" > /dev/null
awk '!seen[$0]++' "$IN" > "$WORK/theirs.txt"
check "dedupe matches awk '!seen[\$0]++'" "$WORK/theirs.txt" "$WORK/mine.txt"

# Remove lines containing a substring.
"$BINARY" --process-lines remove "$IN" "$WORK/mine.txt" "an" > /dev/null
grep -v "an" "$IN" > "$WORK/theirs.txt" || true
check "remove matches grep -v" "$WORK/theirs.txt" "$WORK/mine.txt"

# Keep only lines containing a substring.
"$BINARY" --process-lines keep "$IN" "$WORK/mine.txt" "an" > /dev/null
grep "an" "$IN" > "$WORK/theirs.txt" || true
check "keep matches grep" "$WORK/theirs.txt" "$WORK/mine.txt"

# Plain sort. LC_ALL=C so sort compares bytes, as we do.
"$BINARY" --process-lines sort "$IN" "$WORK/mine.txt" > /dev/null
LC_ALL=C sort "$IN" > "$WORK/theirs.txt"
check "sort matches LC_ALL=C sort" "$WORK/theirs.txt" "$WORK/mine.txt"

# Regex replacement within each line.
"$BINARY" --process-lines regex "$IN" "$WORK/mine.txt" "an" "AN" > /dev/null
sed 's/an/AN/g' "$IN" > "$WORK/theirs.txt"
check "regex replace matches sed s///g" "$WORK/theirs.txt" "$WORK/mine.txt"

# Natural sort: sort -V is the closest standard equivalent.
NAT="$WORK/natural.txt"
printf 'file10\nfile9\nfile1\nfile20\nfile2\n' > "$NAT"
"$BINARY" --process-lines natural-sort "$NAT" "$WORK/mine.txt" > /dev/null
printf 'file1\nfile2\nfile9\nfile10\nfile20\n' > "$WORK/theirs.txt"
check "natural sort orders numerically" "$WORK/theirs.txt" "$WORK/mine.txt"

if [ "$FAILURES" -eq 0 ]; then
    echo "All line operations match their POSIX equivalents."
else
    echo "$FAILURES check(s) failed." >&2
    exit 1
fi
