#!/bin/bash
# End-to-end smoke test of the editing stack on a large file.
#
#   scripts/verify-editing.sh [size-in-MB]     (default 512)
#
# Generates a text file, lets BigEdit apply a deterministic edit sequence
# through the piece table (including a full undo/redo walk) and save it,
# replays the same sequence in Python, and compares the two byte-for-byte.
# Also reports BigEdit's peak resident memory. Note that the number includes
# the memory-mapped file pages the index/save passes touched (clean,
# evictable cache); the editing structures themselves stay tiny.
set -euo pipefail

SIZE_MB="${1:-512}"
WORKDIR="$(mktemp -d /tmp/bigedit-verify.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

INPUT="$WORKDIR/input.txt"
OUTPUT="$WORKDIR/output.txt"
EXPECTED="$WORKDIR/expected.txt"
TIMELOG="$WORKDIR/time.log"

echo "Generating ${SIZE_MB} MB test file…"
python3 - "$INPUT" "$SIZE_MB" <<'PY'
import sys
path, size_mb = sys.argv[1], int(sys.argv[2])
target = size_mb * 1024 * 1024
with open(path, "w") as handle:
    written = 0
    line_number = 0
    while written < target:
        line = f"line {line_number} with deterministic filler content 0123456789\n"
        handle.write(line)
        written += len(line)
        line_number += 1
PY

echo "Building (release)…"
swift build -c release >/dev/null

echo "Running BigEdit --edit-smoke…"
/usr/bin/time -l .build/release/BigEdit --edit-smoke "$INPUT" "$OUTPUT" 2> "$TIMELOG"

echo "Computing expected output independently…"
python3 - "$INPUT" "$EXPECTED" <<'PY'
import sys
input_path, expected_path = sys.argv[1], sys.argv[2]
data = bytearray(open(input_path, "rb").read())
step = len(data) // 17
for marker in range(16, 0, -1):
    offset = marker * step
    data[offset:offset] = f"<<EDIT {marker}>>\n".encode()
if len(data) >= 10:
    del data[0:10]
data += b"<<END>>\n"
open(expected_path, "wb").write(data)
PY

if cmp -s "$OUTPUT" "$EXPECTED"; then
    echo "OK: saved output is byte-identical to the expected file."
else
    echo "FAIL: saved output differs from the expected file." >&2
    exit 1
fi

PEAK_BYTES="$(awk '/maximum resident set size/ {print $1}' "$TIMELOG")"
echo "Peak memory: $((PEAK_BYTES / 1024 / 1024)) MB for a ${SIZE_MB} MB file."
