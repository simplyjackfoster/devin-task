#!/usr/bin/env bash
# run.sh: label every row of an input file with Devin, a chunk at a time,
# resuming until check.sh reports nothing missing.
#
# Env:
#   BATCH_INPUT   one JSON object per line, each with an "id"  (default input.jsonl)
#   BATCH_OUTPUT  append-only results file                     (default output.jsonl)
#   BATCH_CHUNK   ids handed to Devin per invocation           (default 20)
#   DEVIN_TASK    path to the wrapper                          (default devin-task on PATH)
#
# The settings below are the ones that ran clean on the free tier: five
# concurrent sessions, a 60-second backoff base, three retries, and a 1200s
# per-pass timeout because the slow tail overruns the default 600. --until decides
# success, --progress decides when to give up, so a chunk that keeps producing
# rows is never cut off by a pass count.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"                    # so ./check.sh in --until and --progress resolves
export BATCH_INPUT="${BATCH_INPUT:-$HERE/input.jsonl}"
export BATCH_OUTPUT="${BATCH_OUTPUT:-$HERE/output.jsonl}"
CHUNK="${BATCH_CHUNK:-20}"
DEVIN_TASK="${DEVIN_TASK:-devin-task}"

[ -r "$BATCH_INPUT" ] || { echo "run.sh: cannot read BATCH_INPUT $BATCH_INPUT" >&2; exit 2; }
touch "$BATCH_OUTPUT" || exit 2
export BATCH_ONLY="$(mktemp)"          # the current chunk's ids; check.sh scopes to it
trap 'rm -f "$BATCH_ONLY"' EXIT

while :; do
  missing="$(BATCH_ONLY="" ./check.sh --missing)"   # unscoped: the whole file
  [ -z "$missing" ] && { echo "run.sh: every id is done"; break; }
  printf '%s\n' "$missing" | head -"$CHUNK" > "$BATCH_ONLY"
  echo "run.sh: handing Devin $(wc -l < "$BATCH_ONLY" | tr -d ' ') of $(printf '%s\n' "$missing" | wc -l | tr -d ' ') remaining ids"

  PROMPT="$(mktemp)"
  {
    echo "Label each of these rows from $BATCH_INPUT. For every id below, find"
    echo "its line in that file and decide a label for it."
    echo
    echo "Ids to do (they are also in $BATCH_ONLY, one per line):"
    cat "$BATCH_ONLY"
    echo
    # The checkpointing rule: append early, append often, never rewrite. A pass
    # killed at the 600s --timeout otherwise leaves nothing at all behind.
    echo "Append each result to $BATCH_OUTPUT as you finish it, at least every 20 rows."
    echo "Only ever append to that file - never rewrite it, never rewrite earlier lines."
    echo
    echo 'One JSON object per line: {"id": "<id>", "label": "<label>"}'
    echo "Do not touch any other file. When ./check.sh --missing prints nothing you are done."
  } > "$PROMPT"

  # --timeout 1200, not the default 600: at 5 concurrent the slow tail of
  # passes runs past ten minutes and would be killed at exit 124 mid-chunk.
  "$DEVIN_TASK" --yolo --cwd "$HERE" --timeout 1200 \
    --max-concurrent 5 --backoff 60 --retries 3 \
    --until 'test -z "$(./check.sh --missing)"' \
    --progress './check.sh --count' \
    --prompt-file "$PROMPT"
  rc=$?
  rm -f "$PROMPT"

  case $rc in
    0) ;;   # this chunk is complete; loop round for the next one
    5) echo "run.sh: devin-task gave up on this chunk (exit 5: stalled, or out of passes)" >&2; exit 5 ;;
    *) echo "run.sh: devin-task exited $rc; stopping" >&2; exit "$rc" ;;
  esac
done

echo "run.sh: $(BATCH_ONLY="" ./check.sh --count) rows done. Collapse retry duplicates with ./dedupe.sh"
