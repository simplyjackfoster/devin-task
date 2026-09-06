#!/usr/bin/env bash
# Tests for devin-task wrapper. Uses a stub `devin` on PATH; last test is live.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WRAPPER="$HERE/../scripts/devin-task"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; }

# --- stub devin: records argv/cwd/config/prompt, writes a fake ATIF export ---
mkdir -p "$TMP/bin"
cat > "$TMP/bin/devin" <<'STUB'
#!/usr/bin/env bash
echo call >> "$STUB_CALLS"; n=$(wc -l < "$STUB_CALLS" | tr -d ' ')
printf '%s\n' "$@" > "$STUB_ARGV"; cp "$STUB_ARGV" "$STUB_ARGV.$n"
pwd > "$STUB_CWD"
EXPORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prompt-file) cp "$2" "$STUB_PROMPT"; cp "$2" "$STUB_PROMPT.$n"; shift 2 ;;
    --config)      cp "$2" "$STUB_CONFIG"; shift 2 ;;
    --export)      EXPORT="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "${STUB_MODE:-ok}" in
  ok)
    echo "narrative line"; echo "STUB-OK"
    if [ -n "$EXPORT" ]; then
      # cumulative like a real resumed-session export: on call n the first two
      # steps stay fixed and n copies of the final-message step are appended,
      # so a multi-call --until run genuinely grows the export each pass.
      final="{\"source\":\"agent\",\"message\":\"${STUB_ANSWER:-FINAL}\"}"
      steps="{\"source\":\"user\",\"message\":\"x\"},{\"source\":\"agent\",\"message\":\"\",\"tool_calls\":[{\"function_name\":\"exec\",\"arguments\":{\"command\":\"wc -l f.txt\"}}]}"
      i=1; while [ "$i" -le "$n" ]; do steps="$steps,$final"; i=$((i+1)); done
      printf '%s' "{\"session_id\":\"stub-sess\",\"steps\":[$steps],\"final_metrics\":{\"total_steps\":$((2+n))}}" > "$EXPORT"
    fi
    ;;
  reject) echo "warning: rejected a tool call that requires confirmation. Running in non-interactive mode. Use --permission-mode dangerous to auto-approve all tools." >&2; exit 0 ;;
  hang)   sleep 30; echo "never" ;;
  capacity)  echo "Error: the servers are currently overloaded, please try again later" >&2; exit 1 ;;
  internal)  echo "Error: internal error occurred (trace ID: abcd1234)" >&2; exit 1 ;;
  auth)      echo "Error: request unauthorized: invalid api key" >&2; exit 1 ;;
  ratelimit) echo "Error: too many requests, rate limit exceeded" >&2; exit 1 ;;
  slow3)
    # records wall-clock start/end so a concurrency test can assert two runs
    # never overlapped. $$ keeps the two concurrent stubs apart; STUB_CALLS'
    # line count would not (both can read the same value).
    echo "$$ start $(date +%s)" >> "${STUB_TIMES:-/dev/null}"
    sleep 3
    echo "$$ end $(date +%s)" >> "${STUB_TIMES:-/dev/null}"
    echo "narrative line"; echo "STUB-OK"
    [ -n "$EXPORT" ] && printf '%s' "{\"session_id\":\"stub-sess\",\"steps\":[{\"source\":\"agent\",\"message\":\"${STUB_ANSWER:-FINAL}\"}],\"final_metrics\":{}}" > "$EXPORT"
    ;;
  connection) echo "Connection error, send a message to continue retrying" >&2; exit 1 ;;
  connection_then_ok)
    if [ "$n" -lt 2 ]; then
      echo "Connection error, send a message to continue retrying" >&2; exit 1
    else
      echo "narrative line"; echo "STUB-OK"
      [ -n "$EXPORT" ] && printf '%s' "{\"session_id\":\"stub-sess\",\"steps\":[{\"source\":\"agent\",\"message\":\"${STUB_ANSWER:-FINAL}\"}],\"final_metrics\":{}}" > "$EXPORT"
    fi
    ;;
  internal_in_auth) echo "Error: unauthorized - internal error occurred (trace ID: zz99)" >&2; exit 1 ;;
  capacity_then_ok)
    if [ "$n" -lt 3 ]; then
      echo "Error: currently overloaded, try again later" >&2; exit 1
    else
      echo "narrative line"; echo "STUB-OK"
      [ -n "$EXPORT" ] && printf '%s' "{\"session_id\":\"stub-sess\",\"steps\":[{\"source\":\"agent\",\"message\":\"${STUB_ANSWER:-FINAL}\"}],\"final_metrics\":{}}" > "$EXPORT"
    fi
    ;;
  empty)
    echo "narrative line"
    if [ -n "$EXPORT" ]; then
      if [ "$n" -lt 2 ]; then
        printf '%s' "{\"session_id\":\"stub-sess\",\"steps\":[{\"source\":\"agent\",\"message\":\"\"}],\"final_metrics\":{}}" > "$EXPORT"
      else
        printf '%s' "{\"session_id\":\"stub-sess\",\"steps\":[{\"source\":\"agent\",\"message\":\"\"},{\"source\":\"agent\",\"message\":\"\"}],\"final_metrics\":{}}" > "$EXPORT"
      fi
    fi
    ;;
  empty_then_ok)
    if [ "$n" -lt 2 ]; then
      echo "narrative line"
      [ -n "$EXPORT" ] && printf '%s' "{\"session_id\":\"stub-sess\",\"steps\":[{\"source\":\"agent\",\"message\":\"\"}],\"final_metrics\":{}}" > "$EXPORT"
    else
      echo "narrative line"; echo "STUB-OK"
      [ -n "$EXPORT" ] && printf '%s' "{\"session_id\":\"stub-sess\",\"steps\":[{\"source\":\"agent\",\"message\":\"\"},{\"source\":\"agent\",\"message\":\"${STUB_ANSWER:-FINAL}\"}],\"final_metrics\":{}}" > "$EXPORT"
    fi
    ;;
  until_empty_pass2)
    # cumulative export across a 3-call --until run: call 1 is a normal
    # pass with a real message; call 2 (the --until resume) appends only an
    # empty step (no message, no tool_calls) on top of call 1's content;
    # call 3 (the nudge resume) appends a real final message.
    if [ "$n" -eq 1 ]; then
      echo "narrative line"; echo "STUB-OK"
      [ -n "$EXPORT" ] && printf '%s' "{\"session_id\":\"stub-sess\",\"steps\":[{\"source\":\"agent\",\"message\":\"working on it\"}],\"final_metrics\":{}}" > "$EXPORT"
    elif [ "$n" -eq 2 ]; then
      echo "narrative line"
      [ -n "$EXPORT" ] && printf '%s' "{\"session_id\":\"stub-sess\",\"steps\":[{\"source\":\"agent\",\"message\":\"working on it\"},{\"source\":\"agent\",\"message\":\"\"}],\"final_metrics\":{}}" > "$EXPORT"
    else
      echo "narrative line"; echo "STUB-OK"
      [ -n "$EXPORT" ] && printf '%s' "{\"session_id\":\"stub-sess\",\"steps\":[{\"source\":\"agent\",\"message\":\"working on it\"},{\"source\":\"agent\",\"message\":\"\"},{\"source\":\"agent\",\"message\":\"${STUB_ANSWER:-FINAL}\"}],\"final_metrics\":{}}" > "$EXPORT"
    fi
    ;;
  list_export)
    # a syntactically valid export that is not an object (a top-level JSON
    # list): must not crash is_empty_turn/step_count with a traceback.
    echo "narrative line"; echo "STUB-OK"
    [ -n "$EXPORT" ] && printf '%s' '[1,2,3]' > "$EXPORT"
    ;;
  empty_then_capacity_then_ok)
    # call 1 is empty (triggers the nudge); call 2 (the nudge's first
    # attempt) fails with capacity text; call 3 (the nudge's retry, via
    # --retries) succeeds. Proves a transient failure during the nudge is
    # retried the same way a transient failure in the main pass is.
    if [ "$n" -eq 1 ]; then
      echo "narrative line"
      [ -n "$EXPORT" ] && printf '%s' "{\"session_id\":\"stub-sess\",\"steps\":[{\"source\":\"agent\",\"message\":\"\"}],\"final_metrics\":{}}" > "$EXPORT"
    elif [ "$n" -eq 2 ]; then
      echo "Error: currently overloaded, try again later" >&2; exit 1
    else
      echo "narrative line"; echo "STUB-OK"
      [ -n "$EXPORT" ] && printf '%s' "{\"session_id\":\"stub-sess\",\"steps\":[{\"source\":\"agent\",\"message\":\"\"},{\"source\":\"agent\",\"message\":\"${STUB_ANSWER:-FINAL}\"}],\"final_metrics\":{}}" > "$EXPORT"
    fi
    ;;
esac
STUB
chmod +x "$TMP/bin/devin"
printf '%s' '{"agent":{"model":"swe-1-7-medium"},"permissions":{"allow":["Fetch(domain:*)"]}}' > "$TMP/userconfig.json"
export PATH="$TMP/bin:$PATH" STUB_ARGV="$TMP/argv" STUB_PROMPT="$TMP/prompt" STUB_CWD="$TMP/cwd" \
       STUB_CONFIG="$TMP/config" STUB_CALLS="$TMP/calls" DEVIN_TASK_USER_CONFIG="$TMP/userconfig.json" \
       DEVIN_TASK_SLOT_DIR="$TMP/slots"
reset() { rm -f "$STUB_ARGV"* "$STUB_PROMPT"* "$STUB_CONFIG" "$STUB_CALLS"; rm -rf "$TMP/slots"; unset DEVIN_TASK_PREAMBLE; }
argv_pair() { paste -sd' ' "$STUB_ARGV" | grep -qF -- "$1"; }
has_arg()   { grep -qxF -- "$1" "$STUB_ARGV"; }
allow_has() { python3 -c 'import json,sys; sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1]))["permissions"]["allow"] else 1)' "$STUB_CONFIG" "$1"; }

echo "default invocation"
reset; out="$("$WRAPPER" "say hi" 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ "$out" = $'narrative line\nSTUB-OK' ] && ok "exit 0, streams stdout through" || fail "exit 0 / stdout" "rc=$rc out=$out"
argv_pair "--model swe-1-7-medium" && ok "defaults to free swe-1-7-medium" || fail "default model"
argv_pair "--respect-workspace-trust false" && ok "skips workspace trust prompt" || fail "workspace trust"
has_arg "-p" && ok "print mode" || fail "print mode"
argv_pair "--permission-mode auto" && ok "read-only (auto) permission by default" || fail "default perm"
[ "$(cat "$STUB_PROMPT")" = "say hi" ] && ok "prompt delivered via --prompt-file" || fail "prompt file"
has_arg "--export" && ok "always exports the conversation" || fail "export flag" "$(cat "$STUB_ARGV")"

echo "read-only shell allowlist"
[ -f "$STUB_CONFIG" ] && ok "passes a generated --config" || fail "no --config passed"
allow_has "Exec(sed -n)" && allow_has "Exec(head)" && allow_has "Exec(grep)" && ok "allowlist has sed -n, head, grep" || fail "allowlist contents" "$(cat "$STUB_CONFIG" 2>&1)"
! allow_has "Exec(sed)" && ! allow_has "Exec(python3)" && ok "allowlist excludes bare sed and python3" || fail "allowlist too broad"
allow_has "Fetch(domain:*)" && ok "user's existing allow rules preserved" || fail "user rules lost"
python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["agent"]["model"]=="swe-1-7-medium" else 1)' "$STUB_CONFIG" && ok "rest of user config preserved" || fail "user config clobbered"
reset; "$WRAPPER" --edit "x" >/dev/null 2>&1
[ -f "$STUB_CONFIG" ] && allow_has "Exec(head)" && ok "--edit also gets the allowlist" || fail "edit allowlist"
reset; "$WRAPPER" --smart "x" >/dev/null 2>&1
[ -f "$STUB_CONFIG" ] && allow_has "Exec(head)" && ok "--smart also gets the allowlist" || fail "smart allowlist"
reset; "$WRAPPER" --yolo "x" >/dev/null 2>&1
[ ! -f "$STUB_CONFIG" ] && ok "--yolo passes no --config" || fail "yolo config"
reset; "$WRAPPER" --allow 'Exec(python3 -c)' --allow 'Exec(make test)' "x" >/dev/null 2>&1
allow_has "Exec(python3 -c)" && allow_has "Exec(make test)" && ok "--allow (repeatable) extends the allowlist" || fail "--allow" "$(cat "$STUB_CONFIG" 2>&1)"

echo "flags"
reset; "$WRAPPER" --edit "x" >/dev/null 2>&1
argv_pair "--permission-mode accept-edits" && ok "--edit -> accept-edits" || fail "--edit"
reset; "$WRAPPER" --smart "x" >/dev/null 2>&1
argv_pair "--permission-mode smart" && [ -f "$STUB_CONFIG" ] && ok "--smart -> permission-mode smart, with a --config" || fail "--smart"
reset; "$WRAPPER" --yolo "x" >/dev/null 2>&1
argv_pair "--permission-mode dangerous" && ok "--yolo -> dangerous" || fail "--yolo"
reset; "$WRAPPER" --model swe-1-7 "x" >/dev/null 2>&1
argv_pair "--model swe-1-7" && ! argv_pair "swe-1-7-medium" && ok "--model overrides" || fail "--model"
reset; mkdir -p "$TMP/work"; "$WRAPPER" --cwd "$TMP/work" "x" >/dev/null 2>&1
[ "$(cat "$STUB_CWD")" = "$(cd "$TMP/work" && pwd)" ] && ok "--cwd runs devin in that directory" || fail "--cwd" "$(cat "$STUB_CWD")"
out="$("$WRAPPER" --cwd "$TMP/nope" "x" 2>&1)"; rc=$?
[ $rc -eq 2 ] && ok "--cwd missing dir -> exit 2" || fail "--cwd missing" "rc=$rc $out"

echo "prompt handling"
reset; tricky=$'line one "quoted" `backtick` $HOME\nline two'
"$WRAPPER" "$tricky" >/dev/null 2>&1
[ "$(cat "$STUB_PROMPT")" = "$tricky" ] && ok "quotes/backticks/newlines survive" || fail "tricky prompt"
reset; printf 'from stdin\n' | "$WRAPPER" >/dev/null 2>&1
[ "$(cat "$STUB_PROMPT")" = "from stdin" ] && ok "reads prompt from stdin when no arg" || fail "stdin prompt"
reset; printf 'from file' > "$TMP/p.md"; "$WRAPPER" --prompt-file "$TMP/p.md" "ignored positional" >/dev/null 2>&1
[ "$(cat "$STUB_PROMPT")" = "from file" ] && ok "--prompt-file wins over positional" || fail "--prompt-file" "$(cat "$STUB_PROMPT")"
out="$("$WRAPPER" 2>&1 </dev/null)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -qi "usage" && ok "no prompt -> usage, nonzero" || fail "empty prompt" "rc=$rc"
out="$("$WRAPPER" --help 2>&1)"; rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q -- "--retries" && echo "$out" | grep -q -- "--backoff" && echo "$out" | grep -q -- "--max-concurrent" && echo "$out" | grep -q -- "--slot-timeout" && echo "$out" | grep -q -- "--no-empty-retry" && echo "$out" | grep -q "124" && echo "$out" | grep -qE '\b9\b' && ok "--help prints the full header, including --retries, --backoff, --max-concurrent, --slot-timeout, --no-empty-retry, and exit codes 9 and 124" || fail "--help truncated" "rc=$rc out=$out"
reset; "$WRAPPER" --preamble "USE THIS PYTHON" "task body" >/dev/null 2>&1
[ "$(cat "$STUB_PROMPT")" = $'USE THIS PYTHON\n\ntask body' ] && ok "--preamble prepended with blank line" || fail "--preamble" "$(cat "$STUB_PROMPT")"
reset; DEVIN_TASK_PREAMBLE="ENV PRE" "$WRAPPER" "task body" >/dev/null 2>&1
[ "$(cat "$STUB_PROMPT")" = $'ENV PRE\n\ntask body' ] && ok "DEVIN_TASK_PREAMBLE honored" || fail "env preamble" "$(cat "$STUB_PROMPT")"
reset; "$WRAPPER" --inherit-env "task body" >/dev/null 2>&1
grep -qF "python3: $(command -v python3)" "$STUB_PROMPT" && grep -q "task body" "$STUB_PROMPT" && ok "--inherit-env names caller's python3" || fail "--inherit-env" "$(cat "$STUB_PROMPT")"
! grep -q "PATH=" "$STUB_PROMPT" && ok "--inherit-env does not dump PATH" || fail "inherit-env PATH dump"

echo "output modes"
reset; out="$(STUB_ANSWER="the final word" "$WRAPPER" --answer-only "x" 2>/dev/null)"; rc=$?
[ $rc -eq 0 ] && [ "$out" = "the final word" ] && ok "--answer-only prints only the last agent message" || fail "--answer-only" "rc=$rc out=$out"
reset; out="$("$WRAPPER" --json "x" 2>/dev/null)"; rc=$?
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["answer"]=="FINAL"; assert d["session_id"]=="stub-sess"; assert d["exit_code"]==0; assert any("wc -l f.txt" in t for t in d["tool_calls"]); assert d["passes"]==1' 2>/dev/null && ok "--json has answer, session_id, exit_code, tool_calls, passes" || fail "--json" "$out"
reset; out="$(DEVIN_TASK_HEARTBEAT=1 STUB_MODE=hang "$WRAPPER" --trace --timeout 3 "x" 2>&1 >/dev/null)"
echo "$out" | grep -q "elapsed" && ok "--trace heartbeats to stderr while running" || fail "--trace heartbeat" "$out"
reset; out="$("$WRAPPER" --trace "x" 2>&1 >/dev/null)"
echo "$out" | grep -q "exec: wc -l f.txt" && ok "--trace lists tool calls from export after run" || fail "--trace tool list" "$out"

echo "failure surfacing"
reset; out="$(STUB_MODE=reject "$WRAPPER" "write a file" 2>&1)"; rc=$?
[ $rc -eq 3 ] && ok "rejected action -> exit 3" || fail "reject exit" "rc=$rc"
echo "$out" | grep -q -- "--edit" && ok "rejection in auto mode suggests --edit" || fail "reject hint auto" "$out"
echo "$out" | grep -qi "even sed" && echo "$out" | grep -q -- "--allow" && ok "hint says shell commands count (even sed) and names --allow" || fail "hint shell note" "$out"
echo "$out" | grep -qi "partial" && ok "rejection warns about partial edits" || fail "partial warning" "$out"
reset; out="$(STUB_MODE=reject "$WRAPPER" --edit "run tests" 2>&1)"; rc=$?
[ $rc -eq 3 ] && echo "$out" | grep -q -- "--yolo" && ! echo "$out" | grep -q -- "--edit (" && ok "rejection in edit mode suggests --yolo only" || fail "reject hint edit" "rc=$rc $out"
reset; out="$(STUB_MODE=hang "$WRAPPER" --timeout 2 "slow" 2>&1)"; rc=$?
[ $rc -eq 124 ] && echo "$out" | grep -qi "timed out" && ok "--timeout kills and exits 124" || fail "timeout" "rc=$rc out=$out"
STUB_MODE=hang "$WRAPPER" --timeout 30 "slow" >/dev/null 2>&1 &
wpid=$!; sleep 1; kill -TERM "$wpid"; sleep 2
if pgrep -f "$TMP/bin/devin" >/dev/null; then fail "SIGTERM to wrapper kills devin child"; pkill -f "$TMP/bin/devin"; else ok "SIGTERM to wrapper kills devin child"; fi

echo "failure classification"
reset; out="$(STUB_MODE=capacity "$WRAPPER" "x" 2>&1)"; rc=$?
[ $rc -eq 6 ] && echo "$out" | grep -qi "capacity" && ok "capacity text -> exit 6" || fail "capacity classification" "rc=$rc $out"
reset; out="$(STUB_MODE=internal "$WRAPPER" "x" 2>&1)"; rc=$?
[ $rc -eq 7 ] && echo "$out" | grep -qi "internal" && ok "internal error text -> exit 7" || fail "internal classification" "rc=$rc $out"
reset; out="$(STUB_MODE=auth "$WRAPPER" "x" 2>&1)"; rc=$?
[ $rc -eq 8 ] && echo "$out" | grep -qi "auth" && ok "auth text -> exit 8" || fail "auth classification" "rc=$rc $out"
reset; out="$(STUB_MODE=ratelimit "$WRAPPER" "x" 2>&1)"; rc=$?
[ $rc -eq 6 ] && echo "$out" | grep -qi "rate limit" && ok "rate limit text -> exit 6" || fail "ratelimit classification" "rc=$rc $out"
reset; out="$(STUB_MODE=connection "$WRAPPER" "x" 2>&1)"; rc=$?
[ $rc -eq 6 ] && echo "$out" | grep -qi "connection error" && ok "Devin's 'Connection error, send a message to continue retrying' -> exit 6" || fail "connection classification" "rc=$rc $out"
reset; out="$(STUB_MODE=internal_in_auth "$WRAPPER" "x" 2>&1)"; rc=$?
[ $rc -eq 7 ] && ok "internal-inside-auth text -> exit 7, not 8 (transient-first ordering)" || fail "internal-in-auth ordering" "rc=$rc $out"
reset; out="$(STUB_MODE=reject "$WRAPPER" "x" 2>&1)"; rc=$?
[ $rc -eq 3 ] && ok "refusal detection keeps precedence over classification -> exit 3" || fail "refusal precedence" "rc=$rc $out"

echo "--retries"
reset; out="$(STUB_MODE=capacity_then_ok "$WRAPPER" --backoff 0 --retries 2 "x" 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ "$(wc -l < "$STUB_CALLS" | tr -d ' ')" = "3" ] && ok "--retries 2 retries capacity failures then succeeds (3 calls)" || fail "--retries 2" "rc=$rc calls=$(cat "$STUB_CALLS" 2>/dev/null | wc -l) $out"
reset; out="$(STUB_MODE=capacity "$WRAPPER" --backoff 0 --retries 0 "x" 2>&1)"; rc=$?
[ $rc -eq 6 ] && [ "$(wc -l < "$STUB_CALLS" | tr -d ' ')" = "1" ] && ok "--retries 0 does not retry (exit 6 after 1 call)" || fail "--retries 0" "rc=$rc calls=$(cat "$STUB_CALLS" 2>/dev/null | wc -l)"
reset; out="$(STUB_MODE=connection_then_ok "$WRAPPER" --backoff 0 --retries 1 "x" 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ "$(wc -l < "$STUB_CALLS" | tr -d ' ')" = "2" ] && ok "a connection error is retried under --retries (2 calls, exit 0)" || fail "connection retried" "rc=$rc calls=$(cat "$STUB_CALLS" 2>/dev/null | wc -l) $out"

echo "--backoff"
reset; out="$(DEVIN_TASK_RETRY_BASE=abc STUB_MODE=capacity_then_ok "$WRAPPER" --backoff 0 --retries 2 "x" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "--backoff wins over DEVIN_TASK_RETRY_BASE (a bad env value is never validated)" || fail "--backoff over env" "rc=$rc $out"
reset; out="$("$WRAPPER" --backoff abc "x" 2>&1)"; rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q -- "--backoff" && [ ! -f "$STUB_CALLS" ] && ok "--backoff abc -> exit 2 before any devin call" || fail "--backoff validation" "rc=$rc out=$out"
start=$(date +%s); reset; out="$(STUB_MODE=capacity "$WRAPPER" --backoff 1 --retries 2 "x" 2>&1)"; rc=$?
elapsed=$(( $(date +%s) - start ))
[ $rc -eq 6 ] && [ "$(wc -l < "$STUB_CALLS" | tr -d ' ')" = "3" ] && [ "$elapsed" -ge 3 ] && ok "sleep stays backoff x attempt (--backoff 1, 2 retries, >=1+2s)" || fail "--backoff formula" "rc=$rc elapsed=$elapsed calls=$(cat "$STUB_CALLS" 2>/dev/null | wc -l)"

echo "integer inputs are validated before anything runs"
reset; out="$(DEVIN_TASK_RETRY_BASE=abc STUB_MODE=capacity "$WRAPPER" --retries 1 "x" 2>&1)"; rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q "DEVIN_TASK_RETRY_BASE" && [ ! -f "$STUB_CALLS" ] \
  && ok "non-integer DEVIN_TASK_RETRY_BASE -> exit 2 before any devin call (not exit 0)" \
  || fail "RETRY_BASE validation" "rc=$rc calls=$(cat "$STUB_CALLS" 2>/dev/null) out=$out"
reset; out="$("$WRAPPER" --retries abc "x" 2>&1)"; rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q -- "--retries" && ! echo "$out" | grep -qi "integer expression expected" \
  && ok "--retries abc -> exit 2, no bash arithmetic noise on stderr" || fail "--retries validation" "rc=$rc out=$out"
reset; out="$("$WRAPPER" --timeout abc "x" 2>&1)"; rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q -- "--timeout" && ok "--timeout abc -> exit 2" || fail "--timeout validation" "rc=$rc out=$out"
reset; out="$("$WRAPPER" --timeout 0 "x" 2>&1)"; rc=$?
[ $rc -eq 2 ] && ok "--timeout 0 -> exit 2 (a pass needs at least a second)" || fail "--timeout 0" "rc=$rc out=$out"
reset; out="$("$WRAPPER" --max-passes 0 "x" 2>&1)"; rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q -- "--max-passes" && ok "--max-passes 0 -> exit 2" || fail "--max-passes validation" "rc=$rc out=$out"

echo "--max-concurrent"
reset; "$WRAPPER" "x" >/dev/null 2>&1
[ ! -d "$TMP/slots" ] && ok "without --max-concurrent no slot directory is touched" || fail "slot dir created unasked"
reset; out="$("$WRAPPER" --max-concurrent 0 "x" 2>&1)"; rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q -- "--max-concurrent" && ok "--max-concurrent 0 -> exit 2" || fail "--max-concurrent validation" "rc=$rc $out"
reset; out="$("$WRAPPER" --slot-timeout abc "x" 2>&1)"; rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q -- "--slot-timeout" && ok "--slot-timeout abc -> exit 2" || fail "--slot-timeout validation" "rc=$rc $out"
reset; out="$("$WRAPPER" --max-concurrent 2 "x" 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ ! -d "$TMP/slots/slot-1" ] && ok "a finished pass releases its slot" || fail "slot not released" "rc=$rc $(ls "$TMP/slots" 2>&1)"

# two wrappers, one slot: the second must not start until the first has ended.
# Timing-based (the stub holds its slot for 3s, the waiter polls every 2s).
reset; rm -f "$TMP/times"
STUB_TIMES="$TMP/times" STUB_MODE=slow3 "$WRAPPER" --max-concurrent 1 "a" >/dev/null 2>&1 &
c1=$!; sleep 1
STUB_TIMES="$TMP/times" STUB_MODE=slow3 "$WRAPPER" --max-concurrent 1 "b" >/dev/null 2>&1 &
c2=$!; wait $c1; r1=$?; wait $c2; r2=$?
starts=$(grep -c ' start ' "$TMP/times" 2>/dev/null || echo 0)
ends=$(grep -c ' end ' "$TMP/times" 2>/dev/null || echo 0)
[ $r1 -eq 0 ] && [ $r2 -eq 0 ] && [ "$starts" = "2" ] && [ "$ends" = "2" ] && ok "--max-concurrent 1: both runs completed (2 starts, 2 ends)" || fail "concurrent runs" "r1=$r1 r2=$r2 $(cat "$TMP/times" 2>&1)"
first_end=$(grep ' end ' "$TMP/times" | head -1 | awk '{print $3}')
second_start=$(grep ' start ' "$TMP/times" | tail -1 | awk '{print $3}')
[ -n "$first_end" ] && [ -n "$second_start" ] && [ "$second_start" -ge "$first_end" ] && ok "--max-concurrent 1: the second pass starts only after the first ends (no overlap)" || fail "passes overlapped" "first_end=$first_end second_start=$second_start $(cat "$TMP/times" 2>&1)"

reset; mkdir -p "$TMP/slots/slot-1"; echo 999999 > "$TMP/slots/slot-1/pid"
out="$("$WRAPPER" --max-concurrent 1 --slot-timeout 4 "x" 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ "$(wc -l < "$STUB_CALLS" | tr -d ' ')" = "1" ] && ok "a slot held by a dead pid is reclaimed" || fail "stale slot not reclaimed" "rc=$rc $out"

# one live holder process for the three "slot is taken" cases below; it must
# outlast all of them, or its slot is reclaimed as stale and nothing waits.
reset; sleep 300 & holder=$!; disown 2>/dev/null || true
hold_slot() { reset; mkdir -p "$TMP/slots/slot-1"; echo "$holder" > "$TMP/slots/slot-1/pid"; }
hold_slot; out="$("$WRAPPER" --max-concurrent 1 --slot-timeout 2 --retries 0 "x" 2>&1)"; rc=$?
[ $rc -eq 6 ] && echo "$out" | grep -qi "no free concurrency slot" && [ ! -f "$STUB_CALLS" ] && ok "--slot-timeout expiry -> exit 6 with no devin call" || fail "slot timeout" "rc=$rc $out"
hold_slot; out="$("$WRAPPER" --max-concurrent 1 --slot-timeout 2 --backoff 0 --retries 1 "x" 2>&1)"; rc=$?
[ $rc -eq 6 ] && [ "$(echo "$out" | grep -c "no free concurrency slot")" = "2" ] && ok "a slot timeout is retried under --retries (2 attempts, exit 6)" || fail "slot timeout retried" "rc=$rc $out"
hold_slot; out="$("$WRAPPER" --max-concurrent 1 --slot-timeout 2 --retries 0 --trace "x" 2>&1 >/dev/null)"
echo "$out" | grep -q "slots busy; waiting" && ok "--trace announces that it is waiting for a slot" || fail "trace wait line" "$out"
kill "$holder" 2>/dev/null
reset; out="$(STUB_TIMES=/dev/null STUB_MODE=slow3 "$WRAPPER" --max-concurrent 1 --trace "x" 2>&1 >/dev/null)"
echo "$out" | grep -q "concurrency slot 1 acquired" && ok "--trace names the slot when it is acquired" || fail "trace acquire line" "$out"

reset; out="$(STUB_MODE=hang "$WRAPPER" --max-concurrent 1 --timeout 2 "x" 2>&1)"; rc=$?
[ $rc -eq 124 ] && [ ! -d "$TMP/slots/slot-1" ] && ok "a --timeout kill releases the slot" || fail "slot leaked after timeout" "rc=$rc $(ls "$TMP/slots" 2>&1)"
reset; STUB_MODE=hang "$WRAPPER" --max-concurrent 1 --timeout 30 "x" >/dev/null 2>&1 &
wpid=$!; sleep 2; held=0; [ -d "$TMP/slots/slot-1" ] && held=1
kill -TERM "$wpid"; sleep 2
[ "$held" = "1" ] && [ ! -d "$TMP/slots/slot-1" ] && ok "SIGTERM to the wrapper releases the slot" || fail "slot leaked after SIGTERM" "held=$held $(ls "$TMP/slots" 2>&1)"
pkill -f "$TMP/bin/devin" 2>/dev/null

echo "--until loop"
cat > "$TMP/check.sh" <<'CHK'
#!/usr/bin/env bash
n=$(cat "$CHECK_COUNT" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$CHECK_COUNT"
echo "still missing rows: $((4-n))"; [ "$n" -ge 3 ]
CHK
chmod +x "$TMP/check.sh"; export CHECK_COUNT="$TMP/count"
reset; rm -f "$CHECK_COUNT"; out="$("$WRAPPER" --until "$TMP/check.sh" --max-passes 5 "label the rows" 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ "$(wc -l < "$STUB_CALLS" | tr -d ' ')" = "3" ] && ok "--until reruns until check passes (3 passes) and exits 0" || fail "--until loop" "rc=$rc calls=$(cat "$STUB_CALLS" 2>/dev/null | wc -l) $out"
paste -sd' ' "$STUB_ARGV.2" | grep -qF -- "-r stub-sess" && ok "pass 2 resumes the session by id" || fail "resume by id" "$(cat "$STUB_ARGV.2")"
! grep -qF -- "--model" "$STUB_ARGV.2" && ok "resume does not re-pass --model" || fail "resume model flag"
grep -q "still missing rows: 3" "$STUB_PROMPT.2" && grep -qi "check" "$STUB_PROMPT.2" && ok "pass 2 prompt carries the check output" || fail "pass 2 prompt" "$(cat "$STUB_PROMPT.2")"
[ "$(cat "$STUB_PROMPT.1")" = "label the rows" ] && ok "pass 1 prompt is the original" || fail "pass 1 prompt"
reset; rm -f "$CHECK_COUNT"; out="$("$WRAPPER" --until "$TMP/check.sh" --max-passes 2 "label" 2>&1)"; rc=$?
[ $rc -eq 5 ] && echo "$out" | grep -qi "max-passes" && ok "exhausting --max-passes -> exit 5" || fail "max passes" "rc=$rc $out"
reset; rm -f "$CHECK_COUNT"; out="$(STUB_MODE=reject "$WRAPPER" --until "$TMP/check.sh" "label" 2>&1)"; rc=$?
[ $rc -eq 3 ] && [ "$(wc -l < "$STUB_CALLS" | tr -d ' ')" = "1" ] && ok "refusal inside --until stops immediately" || fail "until refusal" "rc=$rc"
reset; rm -f "$CHECK_COUNT"; out="$("$WRAPPER" --until "$TMP/check.sh" --json "label" 2>/dev/null)"
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["passes"]==3' 2>/dev/null && ok "--json reports pass count" || fail "json passes" "$out"

echo "empty-turn detection"
reset; out="$("$WRAPPER" "say hi" 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ "$(wc -l < "$STUB_CALLS" | tr -d ' ')" = "1" ] && ok "normal export -> 1 call, no false-positive nudge" || fail "no false positive" "rc=$rc calls=$(cat "$STUB_CALLS" 2>/dev/null)"
reset; out="$(STUB_MODE=empty_then_ok "$WRAPPER" "do the task" 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ "$(wc -l < "$STUB_CALLS" | tr -d ' ')" = "2" ] && ok "empty turn then normal -> exit 0, 2 calls" || fail "empty then normal" "rc=$rc calls=$(cat "$STUB_CALLS" 2>/dev/null) $out"
paste -sd' ' "$STUB_ARGV.2" | grep -qF -- "-r stub-sess" && ok "nudge pass resumes the session by id" || fail "nudge resume" "$(cat "$STUB_ARGV.2" 2>/dev/null)"
grep -qF "Your previous turn produced no message and no tool call. Continue the task now and finish with a written answer." "$STUB_PROMPT.2" && ok "nudge pass prompt file contains the nudge text verbatim" || fail "nudge prompt text" "$(cat "$STUB_PROMPT.2" 2>/dev/null)"
reset; out="$(STUB_MODE=empty "$WRAPPER" "do the task" 2>&1)"; rc=$?
[ $rc -eq 9 ] && [ "$(wc -l < "$STUB_CALLS" | tr -d ' ')" = "2" ] && ok "empty twice -> exit 9 after exactly 2 calls" || fail "empty twice" "rc=$rc calls=$(cat "$STUB_CALLS" 2>/dev/null) $out"
reset; out="$(STUB_MODE=empty "$WRAPPER" --no-empty-retry "do the task" 2>&1)"; rc=$?
[ $rc -eq 9 ] && [ "$(wc -l < "$STUB_CALLS" | tr -d ' ')" = "1" ] && ok "--no-empty-retry on empty -> exit 9 after 1 call" || fail "--no-empty-retry" "rc=$rc calls=$(cat "$STUB_CALLS" 2>/dev/null)"
reset; out="$(STUB_MODE=empty_then_ok "$WRAPPER" --json "do the task" 2>/dev/null)"
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["passes"]==1, d["passes"]' 2>/dev/null && ok "--json after a nudge reports passes unchanged (nudge not counted)" || fail "json passes after nudge" "$out"

echo "empty-turn detection uses only the current pass's steps (cumulative export)"
cat > "$TMP/check2.sh" <<'CHK2'
#!/usr/bin/env bash
n=$(cat "$CHECK2_COUNT" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$CHECK2_COUNT"
echo "check call $n"; [ "$n" -ge 2 ]
CHK2
chmod +x "$TMP/check2.sh"; export CHECK2_COUNT="$TMP/count2"
reset; rm -f "$CHECK2_COUNT"; out="$(STUB_MODE=until_empty_pass2 "$WRAPPER" --until "$TMP/check2.sh" --max-passes 5 "do the task" 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ "$(wc -l < "$STUB_CALLS" | tr -d ' ')" = "3" ] && ok "an --until resume that appends only empty steps still triggers the nudge (3 calls), then exits 0" || fail "cumulative-export offset fix" "rc=$rc calls=$(cat "$STUB_CALLS" 2>/dev/null) $out"
paste -sd' ' "$STUB_ARGV.3" | grep -qF -- "-r stub-sess" && ok "the nudge (call 3) resumes the session by id" || fail "cumulative nudge resume" "$(cat "$STUB_ARGV.3" 2>/dev/null)"
grep -qF "Your previous turn produced no message and no tool call. Continue the task now and finish with a written answer." "$STUB_PROMPT.3" && ok "the nudge (call 3) prompt file contains the nudge text verbatim" || fail "cumulative nudge prompt" "$(cat "$STUB_PROMPT.3" 2>/dev/null)"

echo "is_empty_turn tolerates a non-object export"
reset; out="$(STUB_MODE=list_export "$WRAPPER" "do the task" 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ "$(wc -l < "$STUB_CALLS" | tr -d ' ')" = "1" ] && ! echo "$out" | grep -q "Traceback" && ok "a non-object (e.g. list) export is treated as not-empty, no traceback, 1 call" || fail "non-object export" "rc=$rc calls=$(cat "$STUB_CALLS" 2>/dev/null) out=$out"
reset; out="$(STUB_MODE=list_export "$WRAPPER" --json "do the task" 2>"$TMP/err")"; rc=$?
! grep -q "Traceback" "$TMP/err" && echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["exit_code"]==0, d; assert d["session_id"]=="", d' 2>/dev/null \
  && ok "--json over a non-object export: valid JSON on stdout, no traceback" || fail "--json non-object export" "rc=$rc out=$out err=$(cat "$TMP/err")"
reset; out="$(STUB_MODE=list_export "$WRAPPER" --answer-only "do the task" 2>"$TMP/err")"; rc=$?
! grep -q "Traceback" "$TMP/err" && ok "--answer-only over a non-object export: no traceback" || fail "--answer-only non-object export" "rc=$rc out=$out err=$(cat "$TMP/err")"

echo "the nudge pass is retried like any other pass (--retries)"
reset; out="$(STUB_MODE=empty_then_capacity_then_ok "$WRAPPER" --backoff 0 --retries 1 "do the task" 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ "$(wc -l < "$STUB_CALLS" | tr -d ' ')" = "3" ] && ok "a capacity failure during the nudge is retried like the main pass (3 calls, exit 0)" || fail "nudge retried" "rc=$rc calls=$(cat "$STUB_CALLS" 2>/dev/null) $out"

if [ "${DEVIN_TASK_TEST_NO_LIVE:-0}" = "1" ]; then
  echo "live: skipped"
else
  echo "live (real devin, free model)"
  PATH="${PATH#$TMP/bin:}"; unset DEVIN_TASK_USER_CONFIG
  out="$(cd "$TMP" && "$WRAPPER" --timeout 60 "Reply with exactly the word PONG and nothing else." 2>&1)"; rc=$?
  [ $rc -eq 0 ] && echo "$out" | grep -q PONG && ok "real devin round-trip" || fail "live" "rc=$rc out=$out"
  printf 'a\nb\nc\n' > "$TMP/f.txt"
  out="$(cd "$TMP" && "$WRAPPER" --answer-only --timeout 90 "Run exactly: head -2 f.txt   then reply with only the output, nothing else." 2>&1)"; rc=$?
  [ $rc -eq 0 ] && echo "$out" | grep -q "^b" && ok "live read-only head via allowlist, answer-only" || fail "live allowlist" "rc=$rc out=$out"
fi

echo; echo "passed=$PASS failed=$FAIL"
[ $FAIL -eq 0 ]
