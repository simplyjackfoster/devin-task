#!/usr/bin/env bash
# check.sh: what is still missing from the append-only output file.
#
#   ./check.sh --missing   (default) print the ids that are in scope but not
#                          yet in the output file, one per line
#   ./check.sh --count     print how many DISTINCT in-scope ids are done
#
# Scope is every id in $BATCH_INPUT, narrowed to the ids listed in $BATCH_ONLY
# when that is set (run.sh sets it to the current chunk). --count is the
# --progress command: distinct, so a duplicate row appended after a retry
# cannot fake forward progress. Both modes always exit 0 — devin-task's
# --until wraps this in `test -z`, and its --progress reads the number.
#
# A half-written final line (a pass killed mid-append) is skipped, not fatal.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BATCH_INPUT="${BATCH_INPUT:-$HERE/input.jsonl}"
BATCH_OUTPUT="${BATCH_OUTPUT:-$HERE/output.jsonl}"
BATCH_ONLY="${BATCH_ONLY:-}"

MODE="missing"
case "${1:-}" in
  ""|--missing) ;;
  --count)      MODE="count" ;;
  -h|--help)    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
  *)            echo "check.sh: unknown argument $1" >&2; exit 2 ;;
esac

python3 - "$BATCH_INPUT" "$BATCH_OUTPUT" "$BATCH_ONLY" "$MODE" <<'PY'
import json, os, sys
inp, out, only, mode = sys.argv[1:5]

def ids(path):
    got = []
    if not os.path.isfile(path):
        return got
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue          # half-written last line from a killed pass
            if isinstance(d, dict) and "id" in d:
                got.append(str(d["id"]))
    return got

scope = ids(inp)
if only:
    wanted = set()
    if os.path.isfile(only):
        with open(only) as f:
            wanted = {l.strip() for l in f if l.strip()}
    scope = [i for i in scope if i in wanted]

done = set(ids(out))
if mode == "count":
    print(len([i for i in scope if i in done]))
else:
    for i in scope:
        if i not in done:
            print(i)
PY
