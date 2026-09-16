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
  "$FT" --cwd "$REPO" --diff "hi" >"$WORK/o2" 2>/dev/null || true
grep -q "new.txt" "$WORK/o2" && ok "diff shows worktree change (plain mode)" || bad "diff missing: $(cat "$WORK/o2")"
# real checkout untouched
[ ! -e "$REPO/new.txt" ] && ok "real checkout untouched" || bad "real checkout was written"

# M4: --answer-only wins over --diff -- prints only the answer, no diff (spec precedence)
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="onlyme" FAKE_FREEBUFF_WRITE="new2.txt:::hello" \
  "$FT" --cwd "$REPO" --diff --answer-only "hi" >"$WORK/o2b" 2>/dev/null || true
[ "$(cat "$WORK/o2b")" = "onlyme" ] && ! grep -q "new2.txt" "$WORK/o2b" \
  && ok "--answer-only wins over --diff (answer only, no diff)" \
  || bad "--answer-only did not win over --diff: $(cat "$WORK/o2b")"

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
msgs7="$(dirname "$found7")/chat-messages.json"
[ -n "$found7" ] && grep -q "Sending message with sdk run config" "$found7" \
  && grep -q "line one" "$msgs7" && grep -q "line two" "$msgs7" \
  && ok "multi-line prompt delivered as one atomic message (both lines present)" \
  || bad "multi-line prompt not delivered atomically: $(cat "$msgs7" 2>/dev/null)"

# preamble is prepended to the prompt in the same atomic message (I1)
touch "$WORK/marker15"
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="preamble-ok" \
  run_to 30 "$FT" --cwd "$REPO" --answer-only "distinctprompttext15" >"$WORK/o15" 2>/dev/null || true
found15="$(find "$FREEBUFF_CONFIG_DIR/projects" -name chat-messages.json -newer "$WORK/marker15" | tail -1)"
[ -n "$found15" ] && grep -q "nobody watching this run" "$found15" && grep -q "distinctprompttext15" "$found15" \
  && ok "standing preamble is sent with the prompt" \
  || bad "preamble not sent: $(cat "$found15" 2>/dev/null)"

# ask_user scenario -> exit 3 with the question as the answer
set +e
FAKE_FREEBUFF_SCENARIO=ask_user run_to 30 "$FT" --cwd "$REPO" --answer-only "go" >"$WORK/o8" 2>/dev/null
rc=$?; set -e
[ "$rc" -eq 3 ] && grep -qi "database" "$WORK/o8" && ok "ask_user -> exit 3" || bad "ask_user rc=$rc out=$(cat "$WORK/o8")"
# interrupted scenario is not treated as complete: an AI message exists but
# never completes, so this is a genuine timeout (124), not an empty turn
set +e; FAKE_FREEBUFF_SCENARIO=interrupted run_to 12 "$FT" --cwd "$REPO" --timeout 5 --answer-only "go" >"$WORK/o8b" 2>/dev/null; rc=$?; set -e
[ "$rc" -eq 124 ] && ok "interrupted times out (124)" || bad "interrupted rc=$rc"

# empty turn: send lands but no AI message ever appears -> exit 9, not 124.
# Runs with no settings.json in place, so this also exercises I4's "skip
# select_model / don't eat the run deadline when settings.json is absent".
set +e; FAKE_FREEBUFF_SCENARIO=empty run_to 20 "$FT" --cwd "$REPO" --timeout 8 --answer-only "go" >"$WORK/o8c" 2>/dev/null; rc=$?; set -e
[ "$rc" -eq 9 ] && ok "empty turn -> exit 9" || bad "empty turn rc=$rc: $(cat "$WORK/o8c")"

# I4: with no settings.json yet, select_model is skipped entirely (no /model driven)
[ -f "$FREEBUFF_CONFIG_DIR/settings.json" ] && rm -f "$FREEBUFF_CONFIG_DIR/settings.json"
touch "$WORK/marker17"
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="noselect" \
  run_to 30 "$FT" --cwd "$REPO" --answer-only "go" >"$WORK/o17" 2>/dev/null || true
found17="$(find "$FREEBUFF_CONFIG_DIR/projects" -name chat-meta.json -newer "$WORK/marker17" | tail -1)"
[ -n "$found17" ] && ! grep -q '"model"' "$found17" \
  && ok "no settings.json -> /model skipped" \
  || bad "select_model ran without settings.json: $(cat "$found17" 2>/dev/null)"

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

# Task 14: --until / --progress loop with conversation resume
# --until that succeeds on the first check ends immediately with 0
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="loop" \
  run_to 40 "$FT" --cwd "$REPO" --until "true" --json "go" >"$WORK/o14" 2>/dev/null || true
python3 -c "import json; d=json.load(open('$WORK/o14')); assert d['exit_code']==0 and d['passes']>=1, d" && ok "--until success" || bad "--until: $(cat "$WORK/o14")"
# --until that never succeeds hits max-passes -> exit 5
set +e; FAKE_FREEBUFF_SCENARIO=answer run_to 60 "$FT" --cwd "$REPO" --until "false" --max-passes 2 "go" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 5 ] && ok "--until exhausted -> 5" || bad "exhausted rc=$rc"

# M1: the pass that seeds last_prog is not itself a stall (seed, stall, stall -> 3 passes)
FAKE_FREEBUFF_SCENARIO=answer run_to 60 "$FT" --cwd "$REPO" \
  --until "false" --progress "echo 7" --max-stalls 2 --json "go" >"$WORK/o19" 2>/dev/null || true
python3 -c "import json; d=json.load(open('$WORK/o19')); assert d['passes']==3, d" \
  && ok "--progress: seeding pass is not a stall" || bad "--progress off-by-one: $(cat "$WORK/o19")"

# I5: SIGINT during a run cleans up the freebuff child and exits 143, not 130
FAKE_FREEBUFF_DELAY=30 FAKE_FREEBUFF_SCENARIO=answer \
  "$FT" --cwd "$REPO" --timeout 60 "hi" >"$WORK/o18" 2>"$WORK/e18" &
pid=$!
sleep 4
kill -INT "$pid" 2>/dev/null || true
set +e
( sleep 20; kill -9 "$pid" 2>/dev/null ) & watchdog=$!
wait "$pid"; rc=$?
kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
set -e
[ "$rc" -eq 143 ] && ok "SIGINT exits 143, not 130" || bad "SIGINT rc=$rc: $(cat "$WORK/e18" 2>/dev/null)"
sleep 0.3
if pgrep -f -- "--cwd $REPO" >/dev/null 2>&1; then bad "freebuff child survived SIGINT"; else ok "freebuff child cleaned up after SIGINT"; fi

# M8: not-ready failure path still emits a minimal, machine-readable --json object
set +e; FAKE_FREEBUFF_SCENARIO=nochatdir run_to 15 "$FT" --cwd "$REPO" --timeout 3 --json "hi" >"$WORK/o20" 2>/dev/null; rc=$?; set -e
python3 -c "import json; d=json.load(open('$WORK/o20')); assert d['exit_code']==1, d" \
  && ok "--json on not-ready failure still emits a reason" || bad "--json not-ready: $(cat "$WORK/o20")"

# M2: --summary and FREEBUFF_TASK_SUMMARY print one line to stderr at exit
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="summed" \
  run_to 30 "$FT" --cwd "$REPO" --summary --answer-only "go" >"$WORK/o21" 2>"$WORK/e21" || true
grep -q "^freebuff-task: summary:" "$WORK/e21" && grep -q "exit 0" "$WORK/e21" \
  && ok "--summary prints one line to stderr" || bad "--summary: $(cat "$WORK/e21")"
FAKE_FREEBUFF_SCENARIO=answer \
  FREEBUFF_TASK_SUMMARY=1 run_to 30 "$FT" --cwd "$REPO" --answer-only "go" >/dev/null 2>"$WORK/e22" || true
grep -q "^freebuff-task: summary:" "$WORK/e22" \
  && ok "FREEBUFF_TASK_SUMMARY=1 enables the summary line" || bad "env summary: $(cat "$WORK/e22")"

# --no-worktree runs directly in the real tree, no isolation
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="nowt" FAKE_FREEBUFF_WRITE="noworktree.txt:::direct" \
  run_to 30 "$FT" --cwd "$REPO" --no-worktree --answer-only "hi" >/dev/null 2>&1 || true
[ -f "$REPO/noworktree.txt" ] && grep -q direct "$REPO/noworktree.txt" \
  && ok "--no-worktree runs directly in the real tree" || bad "--no-worktree did not run in place"

# worktree pruning keeps at most --keep-worktrees + 1 dirs around
for i in 1 2 3 4; do
  FAKE_FREEBUFF_SCENARIO=answer run_to 30 "$FT" --cwd "$REPO" --keep-worktrees 1 --answer-only "hi$i" >/dev/null 2>&1 || true
done
n="$(find "$TMPDIR/freebuff-task" -maxdepth 1 -name 'wt-*' -type d | wc -l | tr -d ' ')"
[ "$n" -le 2 ] && ok "worktree pruning keeps at most keep+1 dirs ($n left)" || bad "worktree pruning left $n dirs"

# --apply refuses a diff that does not apply cleanly, and never touches the real tree
echo "orig" > "$REPO/conflict.txt"; ( cd "$REPO" && git add conflict.txt && git commit -q -m "add conflict.txt" )
echo "real-tree-edit" > "$REPO/conflict.txt"   # uncommitted edit that the worktree's diff won't apply over
set +e
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="conflict" FAKE_FREEBUFF_WRITE="conflict.txt:::worktree-edit" \
  run_to 30 "$FT" --cwd "$REPO" --apply --diff "hi" >"$WORK/o23" 2>"$WORK/e23"; rc=$?
set -e
[ "$rc" -eq 1 ] && grep -q "real-tree-edit" "$REPO/conflict.txt" \
  && ok "--apply refuses a conflicting diff (rc 1), real tree left untouched" \
  || bad "--apply refusal: rc=$rc content=$(cat "$REPO/conflict.txt" 2>/dev/null) err=$(cat "$WORK/e23")"

# A worktree run reuses the real repo's project identity: freebuff's project dir
# is keyed on basename(cwd), so the worktree leaf is named after the repo. This
# shares the already-admitted project instead of minting a fresh per-worktree one
# (which never cleared free-session admission under an automated pty run). The
# transcript must land under projects/<repo-basename>/, and no projects/wt-* dir
# may be created.
rm -rf "$FREEBUFF_CONFIG_DIR/projects"
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="proj" \
  run_to 60 "$FT" --cwd "$REPO" --answer-only "hi" >/dev/null 2>&1 || true
if [ -d "$FREEBUFF_CONFIG_DIR/projects/$(basename "$REPO")/chats" ] \
   && [ -z "$(find "$FREEBUFF_CONFIG_DIR/projects" -maxdepth 1 -type d -name 'wt-*' 2>/dev/null)" ]; then
  ok "worktree run reuses the real repo's project dir"
else
  bad "worktree project dir wrong: $(ls "$FREEBUFF_CONFIG_DIR/projects" 2>/dev/null | tr '\n' ' ')"
fi

exit $fail
