#!/bin/sh
# Cross-checks BigEdit's CSV field splitting against Python's csv module — the
# same shape of check as verify-editing.sh, and as --search against grep.
#
# Generates a file full of the awkward cases (quoted delimiters, doubled
# quotes, stray quotes, empty fields, non-ASCII), runs `--csv`, and compares
# the aligned rows against an independent replay that reads the file with
# csv.reader and pads it with the same column widths.
#
# Usage: scripts/verify-csv.sh
set -e

BIGEDIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="${BINARY:-$BIGEDIT_DIR/.build/debug/BigEdit}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

INPUT="$WORK/awkward.csv"
cat > "$INPUT" <<'CSV'
id,name,city,note
1,"Smith, John",Oslo,plain
2,"say ""hi""",London,doubled quotes
3,ab"cd,Paris,stray quote
4,"",Tokyo,empty quoted
5,,Berlin,empty bare
6,Karen Spärck Jones,Kraków,non-ascii
7,"multi word value",Reykjavík,quoted no delimiter
CSV

ROWS=$(wc -l < "$INPUT" | tr -d ' ')
"$BINARY" --csv "$INPUT" "$ROWS" | tail -n "$ROWS" > "$WORK/bigedit.txt"

python3 - "$INPUT" "$ROWS" > "$WORK/python.txt" <<'PY'
import csv, sys

path, rows = sys.argv[1], int(sys.argv[2])
with open(path, newline="", encoding="utf-8") as handle:
    records = [row for row in csv.reader(handle)][:rows]

MAX_WIDTH = 40
widths = []
for record in records:
    for column, field in enumerate(record):
        width = min(len(field), MAX_WIDTH)
        if column < len(widths):
            widths[column] = max(widths[column], width)
        else:
            widths.append(width)

for record in records:
    parts = []
    for column, field in enumerate(record):
        width = widths[column] if column < len(widths) else len(field)
        if len(field) > width:
            field = field[:width - 1] + "…" if width > 1 else field[:width]
        else:
            field = field + " " * (width - len(field))
        parts.append(field)
    print("  ".join(parts))
PY

if diff -u "$WORK/python.txt" "$WORK/bigedit.txt" > "$WORK/diff.txt"; then
    echo "CSV alignment matches Python's csv module for all $ROWS rows."
else
    echo "MISMATCH between BigEdit and Python:" >&2
    cat "$WORK/diff.txt" >&2
    exit 1
fi
