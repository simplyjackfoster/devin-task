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

# --- stub devin: records argv, copies prompt file, obeys STUB_MODE ---
mkdir -p "$TMP/bin"
cat > "$TMP/bin/devin" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_ARGV"
while [ $# -gt 0 ]; do
  if [ "$1" = "--prompt-file" ]; then cp "$2" "$STUB_PROMPT"; fi
  shift
done
case "${STUB_MODE:-ok}" in
  ok)     echo "STUB-OK" ;;
  reject) echo "warning: rejected a tool call that requires confirmation. Running in non-interactive mode. Use --permission-mode dangerous to auto-approve all tools." >&2; exit 0 ;;
  hang)   sleep 30; echo "never" ;;
esac
STUB
chmod +x "$TMP/bin/devin"
export PATH="$TMP/bin:$PATH" STUB_ARGV="$TMP/argv" STUB_PROMPT="$TMP/prompt"
has_arg() { grep -qxF -- "$1" "$STUB_ARGV"; }
argv_pair() { paste -sd' ' "$STUB_ARGV" | grep -qF -- "$1"; }

echo "default invocation"
out="$("$WRAPPER" "say hi" 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ "$out" = "STUB-OK" ] && ok "exit 0, passes stdout through" || fail "exit 0 / stdout" "rc=$rc out=$out"
argv_pair "--model swe-1-7-medium" && ok "defaults to free swe-1-7-medium" || fail "default model" "$(cat "$STUB_ARGV")"
argv_pair "--respect-workspace-trust false" && ok "skips workspace trust prompt" || fail "workspace trust"
has_arg "-p" && ok "print mode" || fail "print mode"
argv_pair "--permission-mode auto" && ok "read-only (auto) permission by default" || fail "default perm" "$(cat "$STUB_ARGV")"
[ "$(cat "$STUB_PROMPT")" = "say hi" ] && ok "prompt delivered via --prompt-file" || fail "prompt file" "$(cat "$STUB_PROMPT" 2>&1)"

echo "flags"
"$WRAPPER" --edit "x" >/dev/null 2>&1
argv_pair "--permission-mode accept-edits" && ok "--edit -> accept-edits" || fail "--edit" "$(cat "$STUB_ARGV")"
"$WRAPPER" --yolo "x" >/dev/null 2>&1
argv_pair "--permission-mode dangerous" && ok "--yolo -> dangerous" || fail "--yolo" "$(cat "$STUB_ARGV")"
"$WRAPPER" --model swe-1-7 "x" >/dev/null 2>&1
argv_pair "--model swe-1-7" && ! argv_pair "swe-1-7-medium" && ok "--model overrides" || fail "--model" "$(cat "$STUB_ARGV")"

echo "prompt handling"
tricky=$'line one "quoted" `backtick` $HOME\nline two'
"$WRAPPER" "$tricky" >/dev/null 2>&1
[ "$(cat "$STUB_PROMPT")" = "$tricky" ] && ok "quotes/backticks/newlines survive" || fail "tricky prompt" "$(cat "$STUB_PROMPT")"
printf 'from stdin\n' | "$WRAPPER" >/dev/null 2>&1
[ "$(cat "$STUB_PROMPT")" = "from stdin" ] && ok "reads prompt from stdin when no arg" || fail "stdin prompt" "$(cat "$STUB_PROMPT")"
out="$("$WRAPPER" 2>&1 </dev/null)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -qi "usage" && ok "no prompt -> usage, nonzero" || fail "empty prompt" "rc=$rc out=$out"

echo "failure surfacing"
out="$(STUB_MODE=reject "$WRAPPER" "write a file" 2>&1)"; rc=$?
[ $rc -eq 3 ] && ok "rejected write -> exit 3" || fail "reject exit" "rc=$rc"
echo "$out" | grep -q -- "--edit" && ok "rejection in auto mode suggests --edit" || fail "reject hint auto" "$out"
echo "$out" | grep -qi "partial" && ok "rejection warns about partial edits" || fail "partial warning" "$out"
out="$(STUB_MODE=reject "$WRAPPER" --edit "run tests" 2>&1)"; rc=$?
[ $rc -eq 3 ] && echo "$out" | grep -q -- "--yolo" && ! echo "$out" | grep -q -- "--edit (" && ok "rejection in edit mode suggests --yolo only" || fail "reject hint edit" "rc=$rc $out"
out="$(STUB_MODE=hang "$WRAPPER" --timeout 2 "slow" 2>&1)"; rc=$?
[ $rc -eq 124 ] && echo "$out" | grep -qi "timed out" && ok "--timeout kills and exits 124" || fail "timeout" "rc=$rc out=$out"
STUB_MODE=hang "$WRAPPER" --timeout 30 "slow" >/dev/null 2>&1 &
wpid=$!; sleep 1; kill -TERM "$wpid"; sleep 2
if pgrep -f "$TMP/bin/devin" >/dev/null; then fail "SIGTERM to wrapper kills devin child"; pkill -f "$TMP/bin/devin"; else ok "SIGTERM to wrapper kills devin child"; fi

echo "live (real devin, free model)"
PATH="${PATH#$TMP/bin:}" 
out="$(cd "$TMP" && "$WRAPPER" --timeout 60 "Reply with exactly the word PONG and nothing else." 2>&1)"; rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q PONG && ok "real devin round-trip" || fail "live" "rc=$rc out=$out"

echo; echo "passed=$PASS failed=$FAIL"
[ $FAIL -eq 0 ]
