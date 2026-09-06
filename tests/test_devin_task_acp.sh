#!/usr/bin/env bash
# Tests for devin-task-acp. Uses a stub `devin` on PATH that speaks just enough ACP.
# No live calls here: the spike's one live check is run by hand (see README).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/devin-task-acp"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; }

# --- stub devin: initialize / session/new, then one permission round trip -----
mkdir -p "$TMP/bin"
cat > "$TMP/bin/devin" <<'STUB'
#!/usr/bin/env python3
import json, os, sys, time

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()

def readmsg():
    while True:
        line = sys.stdin.readline()
        if not line:
            return None
        if line.strip():
            return json.loads(line)

mode = os.environ.get("STUB_MODE", "ok")
sys.stderr.write("INFO stub devin acp: %s\n" % " ".join(sys.argv[1:]))
with open(os.environ["STUB_ARGV"], "w") as f:
    f.write("\n".join(sys.argv[1:]) + "\n")

while True:
    msg = readmsg()
    if msg is None:
        break
    method = msg.get("method")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": msg["id"],
              "result": {"protocolVersion": 1, "agentCapabilities": {}}})
    elif method == "session/new":
        with open(os.environ["STUB_CWD"], "w") as f:
            f.write(msg["params"]["cwd"] + "\n")
        if mode == "crash":
            sys.exit(1)                # die mid-request: the client sees EOF
        if mode == "error":
            send({"jsonrpc": "2.0", "id": msg["id"],
                  "error": {"code": -32000, "message": "stub refused the session"}})
            continue
        send({"jsonrpc": "2.0", "id": msg["id"], "result": {"sessionId": "stub-sess"}})
    elif method == "session/prompt":
        cmd = msg["params"]["prompt"][0]["text"].strip()
        if mode == "hang":
            while True:
                time.sleep(1)          # never answer session/prompt
        send({"jsonrpc": "2.0", "id": 9001, "method": "session/request_permission",
              "params": {"sessionId": "stub-sess",
                         "toolCall": {"toolCallId": "t1", "title": "Shell: " + cmd,
                                      "kind": "execute",
                                      "_meta": {"cognition.ai/editableCommand": cmd}},
                         "options": [{"optionId": "allow_once", "kind": "allow_once"},
                                     {"optionId": "reject_once", "kind": "reject_once"}]}})
        reply = readmsg() or {}
        allowed = ((reply.get("result") or {}).get("outcome") or {}).get("outcome") == "selected"
        send({"jsonrpc": "2.0", "method": "session/update",
              "params": {"sessionId": "stub-sess",
                         "update": {"sessionUpdate": "tool_call", "toolCallId": "t1",
                                    "title": "Shell: " + cmd}}})
        if mode != "empty":
            text = ("ALLOWED and ran %s" % cmd) if allowed else ("REJECTED the command %s" % cmd)
            send({"jsonrpc": "2.0", "method": "session/update",
                  "params": {"sessionId": "stub-sess",
                             "update": {"sessionUpdate": "agent_message_chunk",
                                        "content": {"type": "text", "text": text}}}})
        send({"jsonrpc": "2.0", "method": "_cognition.ai/agent_stopped",
              "params": {"stats": {"toolCalls": 1, "commandsRun": 1 if allowed else 0,
                                   "modelLabel": "stub"}}})
        send({"jsonrpc": "2.0", "id": msg["id"],
              "result": {"stopReason": "end_turn",
                         "usage": {"totalTokens": 12, "inputTokens": 9, "outputTokens": 3}}})
STUB
chmod +x "$TMP/bin/devin"
export PATH="$TMP/bin:$PATH" STUB_ARGV="$TMP/argv" STUB_CWD="$TMP/cwd" STUB_MODE=ok
reset() { rm -f "$STUB_ARGV" "$STUB_CWD"; STUB_MODE=ok; }

# decide() called directly, as the pure function it is
decide() {
  PYTHONDONTWRITEBYTECODE=1 python3 -c '
import importlib.util, sys
from importlib.machinery import SourceFileLoader
spec = importlib.util.spec_from_loader("acp", SourceFileLoader("acp", sys.argv[1]))
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
sys.exit(0 if mod.decide(sys.argv[2], sys.argv[3]) else 1)' "$SCRIPT" "$1" "$2"
}

echo "allow path"
reset; out="$("$SCRIPT" --approve all "head -3 README.md" 2>"$TMP/err")"; rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q "ALLOWED and ran head -3 README.md" && ok "--approve all allows, answer on stdout, exit 0" || fail "allow path" "rc=$rc out=$out err=$(cat "$TMP/err")"
! grep -q "^denied:" "$TMP/err" && ok "nothing denied under --approve all" || fail "spurious denial" "$(cat "$TMP/err")"
grep -qx -- "--model" "$STUB_ARGV" && grep -qx "swe-1-7-medium" "$STUB_ARGV" && ok "defaults to free swe-1-7-medium" || fail "default model" "$(cat "$STUB_ARGV")"
grep -qx "acp" "$STUB_ARGV" && ok "runs devin acp" || fail "acp subcommand" "$(cat "$STUB_ARGV")"
reset; mkdir -p "$TMP/work"; "$SCRIPT" --approve all --cwd "$TMP/work" "ls" >/dev/null 2>&1
[ "$(cat "$STUB_CWD")" = "$(cd "$TMP/work" && pwd)" ] && ok "--cwd is the session cwd" || fail "--cwd" "$(cat "$STUB_CWD" 2>&1)"
out="$("$SCRIPT" --cwd "$TMP/nope" "ls" 2>&1)"; rc=$?
[ $rc -eq 2 ] && ok "--cwd missing dir -> exit 2" || fail "--cwd missing" "rc=$rc $out"

echo "deny path"
reset; out="$("$SCRIPT" --approve none "head -3 README.md" 2>"$TMP/err")"; rc=$?
[ $rc -eq 0 ] && ok "denial with a non-empty answer still exits 0" || fail "deny exit" "rc=$rc $(cat "$TMP/err")"
grep -qx "denied: head -3 README.md" "$TMP/err" && ok "denial printed to stderr as 'denied: <command>'" || fail "denied line" "$(cat "$TMP/err")"
echo "$out" | grep -q "REJECTED the command" && ok "run continues after a denial; answer says rejected" || fail "deny answer" "$out"
reset; STUB_MODE=empty; out="$("$SCRIPT" --approve none "touch f" 2>/dev/null)"; rc=$?
[ $rc -eq 3 ] && [ -z "$out" ] && ok "denied with an empty answer -> exit 3" || fail "exit 3" "rc=$rc out=$out"

echo "read policy (pure decide)"
decide "head x" read && ok "read allows head" || fail "head denied"
! decide "touch x" read && ok "read denies touch" || fail "touch allowed"
decide "git status" read && ok "read allows git status" || fail "git status denied"
! decide "git push" read && ok "read denies git push" || fail "git push allowed"
! decide "head x" none && ! decide "git status" none && ok "none denies everything" || fail "none too permissive"
decide "touch x" all && decide "rm -rf /" all && ok "all allows everything" || fail "all too strict"
! decide "" read && ok "empty command denied under read" || fail "empty command allowed"
decide "cat README.md | head -3" read && ok "read allows a pipe of read-only commands" || fail "read pipe denied"
! decide "cat README.md | head -3 && touch /tmp/x" read && ok "read denies a chain ending in touch (live-observed bypass)" || fail "chain allowed"
! decide "cd sub && cat f" read && ok "read denies cd chains (cd is not on the list)" || fail "cd chain allowed"
! decide 'cat README.md & touch /tmp/x' read && ok "read denies background chaining with bare &" || fail "bare & allowed"
! decide 'cat $(touch /tmp/x) README.md' read && ok "read denies command substitution \$(...)" || fail "\$() allowed"
! decide 'cat `touch /tmp/x`' read && ok "read denies backtick substitution" || fail "backtick allowed"
! decide 'cat <(touch /tmp/x)' read && ok "read denies process substitution <(...)" || fail "<() allowed"
! decide 'tee >(touch /tmp/x)' read && ok "read denies process substitution >(...)" || fail ">() allowed"
! decide 'cat x > /tmp/y' read && ok "read denies output redirection" || fail "redirection allowed"
! decide 'cat x >> /tmp/y' read && ok "read denies appending redirection" || fail "append allowed"
! decide 'cat x &> /tmp/y' read && ok "read denies &> redirection" || fail "&> allowed"
decide 'cat a 2>&1 | head' read && ok "read allows 2>&1 (a descriptor dup, not a write)" || fail "2>&1 denied"
decide "sed -n 1p f" read && ok "read allows sed -n" || fail "sed -n denied"
! decide "sed -i s/a/b/ f" read && ok "read denies sed -i" || fail "sed -i allowed"
! decide "sed -i.bak s/a/b/ f" read && ok "read denies sed -i.bak" || fail "sed -i.bak allowed"
! decide "sed --in-place=.bak s/a/b/ f" read && ok "read denies sed --in-place" || fail "sed --in-place allowed"
decide "git log --oneline" read && ok "read allows git log --oneline" || fail "git log --oneline denied"
! decide "git diff --output=x" read && ok "read denies git diff --output" || fail "git --output allowed"
! decide "git log --output FILE" read && ok "read denies git log --output" || fail "git log --output allowed"

echo "trace"
reset; "$SCRIPT" --trace --approve all "head f" 2>"$TMP/err" >/dev/null
grep -q "tool: Shell: head f" "$TMP/err" && ok "--trace prints tool call titles" || fail "trace tool" "$(cat "$TMP/err")"
grep -q "allow: head f" "$TMP/err" && ok "--trace prints permission decisions" || fail "trace decision" "$(cat "$TMP/err")"
reset; "$SCRIPT" --approve all "head f" 2>"$TMP/err" >/dev/null
grep -q "stop=end_turn" "$TMP/err" && grep -q "toolCalls=1" "$TMP/err" && ok "stats and usage line on stderr after the run" || fail "stats line" "$(cat "$TMP/err")"
reset; out="$("$SCRIPT" --answer-only --approve all "head f" 2>"$TMP/err")"
[ "$out" = "ALLOWED and ran head f" ] && ! grep -q "stop=" "$TMP/err" && ok "--answer-only drops the stats line" || fail "--answer-only" "out=$out err=$(cat "$TMP/err")"

echo "--json"
reset; out="$("$SCRIPT" --json --approve none "head f" 2>/dev/null)"; rc=$?
echo "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in ("answer", "session_id", "stop_reason", "usage", "stats", "denied", "exit_code"):
    assert k in d, k
assert d["session_id"] == "stub-sess", d["session_id"]
assert d["stop_reason"] == "end_turn", d["stop_reason"]
assert d["denied"] == ["head f"], d["denied"]
assert d["exit_code"] == 0, d["exit_code"]
assert d["usage"]["totalTokens"] == 12 and d["stats"]["toolCalls"] == 1' \
  && ok "--json has answer, session_id, stop_reason, usage, stats, denied, exit_code" || fail "--json" "rc=$rc $out"
reset; out="$("$SCRIPT" --json --approve all "head f" 2>/dev/null)"
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["answer"]=="ALLOWED and ran head f", d' \
  && ok "--json: stdout is only JSON, no streamed chunk" || fail "--json stdout" "$out"

echo "prompt handling"
reset; out="$(printf 'head from stdin' | "$SCRIPT" --approve all 2>/dev/null)"
echo "$out" | grep -q "head from stdin" && ok "reads the prompt from stdin" || fail "stdin prompt" "$out"
reset; printf 'head from file' > "$TMP/p.md"; out="$("$SCRIPT" --approve all --prompt-file "$TMP/p.md" 2>/dev/null)"
echo "$out" | grep -q "head from file" && ok "--prompt-file delivers the prompt" || fail "--prompt-file" "$out"
out="$("$SCRIPT" --approve all 2>&1 </dev/null)"; rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -qi "prompt" && ok "no prompt -> exit 2" || fail "empty prompt" "rc=$rc $out"
out="$("$SCRIPT" --approve bogus "x" 2>&1)"; rc=$?
[ $rc -eq 2 ] && ok "bad --approve value -> exit 2" || fail "bad approve" "rc=$rc $out"

echo "transport failures"
reset; STUB_MODE=error; out="$("$SCRIPT" "head f" 2>&1)"; rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "stub refused the session" && ok "JSON-RPC error -> exit 1, message on stderr" || fail "rpc error" "rc=$rc $out"
reset; STUB_MODE=crash; start=$(date +%s)
out="$("$SCRIPT" --timeout 30 "head f" 2>&1)"; rc=$?
[ $rc -eq 1 ] && [ $(( $(date +%s) - start )) -le 5 ] && ok "devin exiting mid-request -> exit 1 at once, not at the timeout" || fail "eof handling" "rc=$rc $out"
reset; out="$("$SCRIPT" --prompt-file "$TMP/missing.md" 2>&1)"; rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q "cannot read --prompt-file" && ok "unreadable --prompt-file -> exit 2" || fail "prompt-file missing" "rc=$rc $out"

echo "timeout and signals"
reset; STUB_MODE=hang; start=$(date +%s)
out="$("$SCRIPT" --timeout 2 "head f" 2>&1)"; rc=$?
elapsed=$(( $(date +%s) - start ))
[ $rc -eq 124 ] && echo "$out" | grep -qi "timed out" && ok "--timeout kills the child and exits 124" || fail "timeout" "rc=$rc out=$out"
[ "$elapsed" -le 5 ] && ok "timeout fires promptly (${elapsed}s)" || fail "slow timeout" "${elapsed}s"
! pgrep -f "$TMP/bin/devin" >/dev/null && ok "no stub left running after a timeout" || { fail "stub survived timeout"; pkill -f "$TMP/bin/devin"; }
reset; STUB_MODE=hang; "$SCRIPT" --timeout 30 "head f" >/dev/null 2>&1 &
wpid=$!; sleep 2; kill -TERM "$wpid"; wait "$wpid"; rc=$?
[ $rc -eq 143 ] && ok "SIGTERM -> exit 143" || fail "SIGTERM exit" "rc=$rc"
sleep 0.5
if pgrep -f "$TMP/bin/devin" >/dev/null; then fail "SIGTERM kills the devin acp child"; pkill -f "$TMP/bin/devin"; else ok "SIGTERM kills the devin acp child"; fi

echo; echo "passed=$PASS failed=$FAIL"
[ $FAIL -eq 0 ]
