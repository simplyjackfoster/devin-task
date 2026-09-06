#!/usr/bin/env bash
# Tests for examples/batch. run.sh drives the real wrapper against a stub
# `devin` that appends a few of the still-missing rows per call (and sometimes
# re-appends one, the way a retried or timed-out pass does), then check.sh and
# dedupe.sh must agree that every id landed exactly once. No live calls.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
EX="$HERE/../examples/batch"
WRAPPER="$HERE/../scripts/devin-task"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; }

# --- stub devin: an annotator that checkpoints append-only, as the prompt asks ---
mkdir -p "$TMP/bin"
cat > "$TMP/bin/devin" <<'STUB'
#!/usr/bin/env bash
echo call >> "$STUB_CALLS"; n=$(wc -l < "$STUB_CALLS" | tr -d ' ')
EXPORT=""
while [ $# -gt 0 ]; do
  case "$1" in --export) EXPORT="$2"; shift 2 ;; *) shift ;; esac
done
# devin-task --cwd'd us into examples/batch, and run.sh exported BATCH_ONLY, so
# ./check.sh --missing is exactly this chunk's outstanding ids.
for id in $(./check.sh --missing | head -"${STUB_ROWS:-3}"); do
  printf '{"id": "%s", "label": "stub"}\n' "$id" >> "$BATCH_OUTPUT"
done
# every second call, re-append the row just written: what a pass killed at the
# --timeout, or retried after a capacity failure, leaves behind. dedupe.sh
# exists for exactly this.
[ $((n % 2)) -eq 0 ] && [ -s "$BATCH_OUTPUT" ] && tail -1 "$BATCH_OUTPUT" >> "$BATCH_OUTPUT"
echo "STUB-OK"
if [ -n "$EXPORT" ]; then
  # cumulative across a resumed session, so a later --until pass never looks
  # like an empty turn to the wrapper
  steps="{\"source\":\"user\",\"message\":\"x\"}"
  i=1; while [ "$i" -le "$n" ]; do steps="$steps,{\"source\":\"agent\",\"message\":\"appended rows\"}"; i=$((i+1)); done
  printf '%s' "{\"session_id\":\"stub-sess\",\"steps\":[$steps],\"final_metrics\":{}}" > "$EXPORT"
fi
STUB
chmod +x "$TMP/bin/devin"

export PATH="$TMP/bin:$PATH" STUB_CALLS="$TMP/calls" DEVIN_TASK="$WRAPPER" \
       DEVIN_TASK_SLOT_DIR="$TMP/slots" DEVIN_TASK_USER_CONFIG="$TMP/noconfig.json" \
       BATCH_INPUT="$EX/input.jsonl" BATCH_OUTPUT="$TMP/output.jsonl" BATCH_CHUNK=4
TOTAL="$(wc -l < "$BATCH_INPUT" | tr -d ' ')"

echo "check.sh on an empty output"
: > "$BATCH_OUTPUT"
[ "$(BATCH_ONLY="" "$EX/check.sh" --missing | wc -l | tr -d ' ')" = "$TOTAL" ] && ok "--missing lists every id when nothing is done" || fail "--missing on empty output"
[ "$(BATCH_ONLY="" "$EX/check.sh" --count)" = "0" ] && ok "--count is 0 when nothing is done" || fail "--count on empty output"
out="$("$EX/check.sh" --nonsense 2>&1)"; rc=$?
[ $rc -eq 2 ] && ok "check.sh rejects an unknown argument with exit 2" || fail "check.sh bad arg" "rc=$rc $out"

echo "the run.sh loop"
rm -f "$STUB_CALLS"
out="$("$EX/run.sh" 2>&1)"; rc=$?
calls="$(wc -l < "$STUB_CALLS" 2>/dev/null | tr -d ' ')"
[ $rc -eq 0 ] && ok "run.sh exits 0" || fail "run.sh exit" "rc=$rc $out"
[ -z "$(BATCH_ONLY="" "$EX/check.sh" --missing)" ] && ok "every id is present in the output when the loop ends" || fail "ids missing" "$(BATCH_ONLY="" "$EX/check.sh" --missing)"
[ "$(BATCH_ONLY="" "$EX/check.sh" --count)" = "$TOTAL" ] && ok "--count reaches the row total ($TOTAL)" || fail "--count total" "$(BATCH_ONLY="" "$EX/check.sh" --count)"
[ "${calls:-0}" -ge 3 ] && ok "the chunked loop needed several devin calls ($calls)" || fail "too few devin calls" "calls=$calls"
[ ! -d "$TMP/slots/slot-1" ] && ok "--max-concurrent 5 left no slot behind" || fail "slot leaked" "$(ls "$TMP/slots" 2>&1)"

echo "dedupe.sh"
raw="$(wc -l < "$BATCH_OUTPUT" | tr -d ' ')"
[ "$raw" -gt "$TOTAL" ] && ok "the append-only output really does carry retry duplicates ($raw lines for $TOTAL ids)" || fail "no duplicates to collapse" "raw=$raw"
printf '{"id": "r01", "label": "second"}\n' >> "$BATCH_OUTPUT"
out="$("$EX/dedupe.sh" "$BATCH_OUTPUT" "$TMP/dedup.jsonl" 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ "$(wc -l < "$TMP/dedup.jsonl" | tr -d ' ')" = "$TOTAL" ] && ok "dedupe.sh writes exactly one line per id" || fail "dedupe line count" "rc=$rc $(wc -l < "$TMP/dedup.jsonl" 2>&1) $out"
python3 - "$TMP/dedup.jsonl" "$BATCH_INPUT" <<'PY' && ok "the deduped file has every input id exactly once" || fail "dedupe id set"
import json, sys
got = [json.loads(l)["id"] for l in open(sys.argv[1]) if l.strip()]
want = [json.loads(l)["id"] for l in open(sys.argv[2]) if l.strip()]
assert len(got) == len(set(got)), "duplicate ids survived"
assert set(got) == set(want), (set(want) - set(got), set(got) - set(want))
PY
python3 -c 'import json,sys
d = {json.loads(l)["id"]: json.loads(l)["label"] for l in open(sys.argv[1]) if l.strip()}
sys.exit(0 if d["r01"] == "second" else 1)' "$TMP/dedup.jsonl" && ok "dedupe.sh keeps the LAST occurrence of a duplicated id" || fail "dedupe kept the wrong copy"
[ "$(wc -l < "$BATCH_OUTPUT" | tr -d ' ')" -gt "$TOTAL" ] && ok "dedupe.sh leaves the append-only input untouched" || fail "dedupe rewrote its input"
out="$("$EX/dedupe.sh" "$BATCH_OUTPUT" "$BATCH_OUTPUT" 2>&1)"; rc=$?
[ $rc -eq 2 ] && ok "dedupe.sh refuses to write over its input" || fail "dedupe in-place" "rc=$rc $out"

echo "check.sh tolerates a torn last line"
printf '{"id": "r99", "lab' >> "$BATCH_OUTPUT"
[ "$(BATCH_ONLY="" "$EX/check.sh" --count)" = "$TOTAL" ] && ok "a half-written final line is skipped, not fatal" || fail "torn line" "$(BATCH_ONLY="" "$EX/check.sh" --count 2>&1)"
: > "$TMP/only"; printf 'r01\nr02\n' > "$TMP/only"
[ "$(BATCH_ONLY="$TMP/only" "$EX/check.sh" --count)" = "2" ] && ok "BATCH_ONLY scopes --count to the current chunk" || fail "BATCH_ONLY scoping" "$(BATCH_ONLY="$TMP/only" "$EX/check.sh" --count)"

echo; echo "passed=$PASS failed=$FAIL"
[ $FAIL -eq 0 ]
