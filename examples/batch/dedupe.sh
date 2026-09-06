#!/usr/bin/env bash
# dedupe.sh: collapse duplicate ids in the append-only output file, keeping the
# LAST occurrence of each, into a NEW file.
#
#   ./dedupe.sh [IN] [OUT]     defaults: $BATCH_OUTPUT -> $BATCH_OUTPUT.dedup
#
# Duplicates are the expected cost of append-only output: a pass killed at the
# --timeout, or retried after a capacity failure, redoes rows it had already
# appended. The last copy is the one written by the pass that got furthest, so
# that is the one kept. The input file is never modified — rewriting it is
# exactly what the checkpointing rule forbids.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
IN="${1:-${BATCH_OUTPUT:-$HERE/output.jsonl}}"
OUT="${2:-$IN.dedup}"
[ -r "$IN" ] || { echo "dedupe.sh: cannot read $IN" >&2; exit 2; }
[ "$IN" = "$OUT" ] && { echo "dedupe.sh: refusing to write over $IN" >&2; exit 2; }

python3 - "$IN" "$OUT" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
keep, order = {}, []          # id -> last line seen, in first-seen order
for line in open(src):
    line = line.rstrip("\n")
    if not line.strip():
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if not isinstance(d, dict) or "id" not in d:
        continue
    i = str(d["id"])
    if i not in keep:
        order.append(i)
    keep[i] = line
with open(dst, "w") as f:
    for i in order:
        f.write(keep[i] + "\n")
print(f"dedupe.sh: {len(order)} unique ids -> {dst}")
PY
