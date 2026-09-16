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

exit $fail
