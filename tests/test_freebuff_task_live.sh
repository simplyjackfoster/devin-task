#!/usr/bin/env bash
# Opt-in live smoke test for freebuff-task: runs the REAL freebuff-task
# wrapper against the REAL freebuff CLI and the real account/network. Off by
# default so CI and ordinary test runs never touch the live account.
set -euo pipefail
[ "${FREEBUFF_TASK_LIVE:-}" = "1" ] || { echo "skip - set FREEBUFF_TASK_LIVE=1 to run"; exit 0; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(mktemp -d)"
trap 'rm -rf "$REPO"' EXIT
( cd "$REPO" && git init -q && echo "the secret word is albatross" > note.txt && git add . && git commit -q -m init )
out="$("$ROOT/scripts/freebuff-task" --cwd "$REPO" --answer-only "What is the secret word in note.txt? Answer with one word.")"
echo "$out" | grep -qi albatross && echo "ok - live run read the file" || { echo "NOT ok - live: $out"; exit 1; }
