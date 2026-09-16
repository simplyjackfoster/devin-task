#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; export FREEBUFF_CONFIG_DIR="$WORK/config"; mkdir -p "$FREEBUFF_CONFIG_DIR"
export PATH="$ROOT/tests:$PATH"           # fake-freebuff shadows the real one
REPO="$WORK/repo"; mkdir -p "$REPO"; ( cd "$REPO" && git init -q && git commit -q --allow-empty -m init )
fail=0; ok(){ echo "ok - $1"; }; bad(){ echo "NOT ok - $1"; fail=1; }
run_to(){ local s="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }

# fake writes a transcript the driver can find
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="pong" \
  "$ROOT/tests/fake-freebuff" --cwd "$REPO" <<<"" >/dev/null 2>&1 || true
found="$(find "$FREEBUFF_CONFIG_DIR/projects" -name chat-messages.json | head -1)"
[ -n "$found" ] && grep -q pong "$found" && ok "fake writes transcript" || bad "fake writes transcript"

FT="$ROOT/scripts/freebuff-task"
# usage error when no prompt
set +e; printf '' | "$FT" --cwd "$REPO" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 2 ] && ok "empty prompt is usage error 2" || bad "empty prompt rc=$rc"

# worktree is created under $TMPDIR/freebuff-task and a diff is captured
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="ok" FAKE_FREEBUFF_WRITE="new.txt:::hello" \
  "$FT" --cwd "$REPO" --diff --answer-only "hi" >"$WORK/o2" 2>/dev/null || true
grep -q "new.txt" "$WORK/o2" && ok "diff shows worktree change" || bad "diff missing: $(cat "$WORK/o2")"
# real checkout untouched
[ ! -e "$REPO/new.txt" ] && ok "real checkout untouched" || bad "real checkout was written"

# a held lock makes a second run give up with exit 6 under a short slot timeout
python3 - "$WORK" <<'PY' &
import fcntl, os, sys, time, tempfile
lk = os.path.join(tempfile.gettempdir(), "freebuff-task.lock")
f = open(lk, "w"); fcntl.flock(f, fcntl.LOCK_EX); time.sleep(3)
PY
sleep 0.5
set +e; FAKE_FREEBUFF_SCENARIO=answer "$FT" --cwd "$REPO" --slot-timeout 1 "hi" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 6 ] && ok "lock contention exits 6" || bad "lock rc=$rc"
wait

# driver detects the fake's new chat dir (ready) and does not hang
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="ready-ok" \
  run_to 30 "$FT" --cwd "$REPO" --answer-only "hi" >"$WORK/o6" 2>/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "pty run completes" || bad "pty run rc=$rc: $(cat "$WORK/o6")"

# multi-line prompt is delivered as one message (send-landed log line appears)
printf 'line one\nline two\n' > "$WORK/multi.txt"
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="multi-ok" \
  run_to 30 "$FT" --cwd "$REPO" --prompt-file "$WORK/multi.txt" >"$WORK/o7" 2>/dev/null || true
found7="$(find "$FREEBUFF_CONFIG_DIR/projects" -name log.jsonl -newer "$WORK/multi.txt" | tail -1)"
[ -n "$found7" ] && grep -q "Sending message with sdk run config" "$found7" \
  && ok "multi-line prompt delivered as one message" || bad "multi-line prompt not delivered"

# ask_user scenario -> exit 3 with the question as the answer
set +e
FAKE_FREEBUFF_SCENARIO=ask_user run_to 30 "$FT" --cwd "$REPO" --answer-only "go" >"$WORK/o8" 2>/dev/null
rc=$?; set -e
[ "$rc" -eq 3 ] && grep -qi "database" "$WORK/o8" && ok "ask_user -> exit 3" || bad "ask_user rc=$rc out=$(cat "$WORK/o8")"
# interrupted scenario is not treated as complete (times out, never a clean 0 answer)
set +e; FAKE_FREEBUFF_SCENARIO=interrupted run_to 12 "$FT" --cwd "$REPO" --timeout 5 --answer-only "go" >"$WORK/o8b" 2>/dev/null; rc=$?; set -e
[ "$rc" -ne 0 ] && ok "interrupted is not a clean success" || bad "interrupted returned 0"

# deferred from Task 3: --answer-only prints the answer
echo "hi there" > "$WORK/p.txt"
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="pong" \
  run_to 30 "$FT" --cwd "$REPO" --prompt-file "$WORK/p.txt" --answer-only >"$WORK/o1" 2>/dev/null || true
grep -q pong "$WORK/o1" && ok "answer-only prints answer" || bad "answer-only: $(cat "$WORK/o1")"

# --json shape: answer, exit_code, worktree key
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="pong" \
  run_to 30 "$FT" --cwd "$REPO" --json "hi" >"$WORK/o9" 2>/dev/null || true
python3 -c "import json; d=json.load(open('$WORK/o9')); assert d['answer']=='pong'; assert d['exit_code']==0; assert 'worktree' in d" \
  && ok "--json shape" || bad "--json: $(cat "$WORK/o9")"

FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="applied" FAKE_FREEBUFF_WRITE="applied.txt:::yes" \
  run_to 30 "$FT" --cwd "$REPO" --apply --answer-only "go" >/dev/null 2>&1 || true
[ -f "$REPO/applied.txt" ] && grep -q yes "$REPO/applied.txt" && ok "--apply writes to real tree" || bad "--apply did not apply"

set +e; FAKE_FREEBUFF_SCENARIO=notsignedin run_to 15 "$FT" --cwd "$REPO" "hi" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 8 ] && ok "not-signed-in -> exit 8" || bad "notsignedin rc=$rc"
set +e; FAKE_FREEBUFF_SCENARIO=ratelimited run_to 15 "$FT" --cwd "$REPO" "hi" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 6 ] && ok "rate-limited -> exit 6" || bad "ratelimited rc=$rc"

# Task 12: tool_calls counted in --json, --trace prints tool call lines
FAKE_FREEBUFF_SCENARIO=toolcalls FAKE_FREEBUFF_ANSWER="traced" \
  run_to 30 "$FT" --cwd "$REPO" --json "go" >"$WORK/o12" 2>"$WORK/e12" || true
python3 -c "import json; d=json.load(open('$WORK/o12')); assert d['tool_calls']>=2, d" \
  && ok "tool_calls counted" || bad "tool_calls: $(cat "$WORK/o12")"
FAKE_FREEBUFF_SCENARIO=toolcalls run_to 30 "$FT" --cwd "$REPO" --trace "go" 2>"$WORK/e12b" >/dev/null || true
grep -q "read_files" "$WORK/e12b" && ok "--trace prints tool calls" || bad "no trace line"

# Task 13: model selection via /model when it differs from settings.json
echo '{"freebuffModel":"z-ai/glm-5.2"}' > "$FREEBUFF_CONFIG_DIR/settings.json"
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="m" \
  run_to 30 "$FT" --cwd "$REPO" --model glm-5.3-flash --answer-only "go" >/dev/null 2>&1 || true
found13="$(find "$FREEBUFF_CONFIG_DIR/projects" -name chat-meta.json | sort | tail -1)"
[ -n "$found13" ] && grep -q "glm-5.3-flash" "$found13" && ok "/model selection sent" || bad "model not selected: $(cat "$found13" 2>/dev/null)"

exit $fail
