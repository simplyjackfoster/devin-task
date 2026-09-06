---
name: devin
description: Delegate a self-contained task to the local Devin CLI on the free SWE-1.7 model via the `devin-task` wrapper. Use to offload research, second opinions, mechanical multi-file edits, labeling/batch jobs, or side tasks that can run in parallel without spending Claude tokens. Also use when the user says "ask devin", "hand this to devin", or "use swe".
---

# Devin CLI delegation

`devin-task` runs one non-interactive Devin turn on `swe-1-7-medium` (free,
262K context) and prints Devin's output. It is a symlink in `~/.local/bin` to
`scripts/devin-task` in this skill.

```bash
devin-task "prompt"                                   # read-only
devin-task --edit "prompt"                            # may write files
devin-task --yolo "prompt"                            # may also run any command
devin-task --cwd ~/proj --prompt-file /tmp/p.md       # no cd &&, no shell quoting
devin-task --answer-only "prompt"                     # only Devin's final message
devin-task --json "prompt"                            # {answer, session_id, exit_code, passes, tool_calls}
devin-task --yolo --until 'python3 check.py' --max-passes 12 "prompt"   # loop until check exits 0
devin-task --inherit-env --yolo "prompt"              # tell Devin which python3/node to use
devin-task --trace "prompt"                           # heartbeat on stderr + tool-call list after
devin-task --retries 2 "prompt"                       # retry connection/capacity/rate-limit failures (exit 6)
devin-task --retries 3 --backoff 60 "prompt"          # 60s x attempt between retries (default 30)
devin-task --max-concurrent 5 "prompt"                # machine-wide cap on simultaneous devin passes
devin-task --until 'CHK' --progress 'COUNT' "prompt"  # stop on stalled progress, not on a pass count
devin-task --no-empty-retry "prompt"                  # skip the empty-turn nudge; still exit 9
```

From the Bash tool pass `timeout: 600000` or use `run_in_background: true`;
the tool's default 120s kills most real tasks. `--until` loops must run in the
background (600s cap × passes). The wrapper forwards SIGTERM and kills Devin's
whole process tree, so a killed call leaves nothing behind.

## Choosing the mode up front

Devin stops at the first refused action and prints nothing, so pick the mode
the task will need. The wrapper exits 3 with a mode-specific hint on refusal,
and partial edits may already be on disk.

| Mode | Devin may |
|---|---|
| default | use file tools, and run the read-only shell allowlist: `cat head tail sed -n grep rg wc ls stat file diff jq cut tr uniq pwd which git log/status/diff/show` (pipes allowed; `>` redirection and `sed -i` are refused) |
| `--edit` | also write files. Still no commands beyond the allowlist. |
| `--smart` | Devin's `--permission-mode smart`: additionally auto-runs actions a fast model judges safe, per Devin's help text. Still gets the read-only allowlist. On this account Devin reports it "not available" and falls back to normal; whether the judging model bills anything when it does become available is unverified. |
| `--yolo` | run anything. Use for "write a script" tasks: Devin always runs what it wrote. |

`--allow 'Exec(<prefix>)'` (repeatable) extends the allowlist in any mode,
e.g. `--allow 'Exec(python3 -c)'` or `--allow 'Exec(pytest)'`. Devin's own
smart mode and `--sandbox` do not work headless on this account, so in
`--yolo` the prompt is the only guardrail: say what Devin may and may not touch.

## Environment mismatch

Devin's shell is a login shell and may order PATH differently from the caller
(here: Homebrew python3 without duckdb comes before miniconda's). For anything
that imports packages, pass `--inherit-env` (adds the caller's `python3`,
`node` and `CONDA_PREFIX` to the prompt) or write the interpreter path into
the prompt yourself. `DEVIN_TASK_PREAMBLE` / `--preamble` prepend arbitrary
standing instructions.

## Writing the prompt

Devin starts cold. Put everything it needs in the prompt: goal, relevant
paths, constraints, the exact output shape. Long prompts: write them to a file
and use `--prompt-file`; the wrapper never passes prompts through the shell.
Devin's plain stdout concatenates its progress messages without newlines, so
for anything parsed use `--answer-only` or `--json`.

**Checkpoint the output.** For any task that produces many rows or files, tell
Devin in the prompt to append its output early and often — every 20 rows or so
— and to write append-only, never rewriting the output file. A pass that hits
the 600-second `--timeout` otherwise leaves nothing at all behind, because
Devin was still holding the whole result to write at the end. Across a
300-pass run, killed and timed-out passes with append-only output never lost or
corrupted a row; the cost is duplicate ids after a retry, which a dedupe pass
collapses. Two lines in the prompt do it:

> Append each result to `out.jsonl` as you finish it, at least every 20 rows.
> Only ever append to that file — never rewrite it, never rewrite earlier lines.

`examples/batch/` is a complete loop built this way: `check.sh` (the
`--until` check and the `--progress` counter), `run.sh` (chunked prompts) and
`dedupe.sh` (collapse the duplicate ids a retry leaves behind).

## Resumable tasks with --until

`--until CMD` runs `bash -c CMD` in the working directory after each pass.
Exit 0 ends the loop; otherwise the next pass resumes the same Devin session
with the check's exit code and last 40 lines of output, so Devin sees exactly
what is still missing. `--max-passes` (default 5) exhausted gives exit 5.
Write the check to print what is missing, not just fail.

For a job whose size you do not know up front, bound it by progress instead of
by pass count. `--progress CMD` runs `bash -c CMD` after each pass; it must
print a single integer (rows done, files written). A pass that raises it resets
the stall counter and the run keeps going — `--progress` replaces
`--max-passes`, which is then ignored. `--max-stalls N` consecutive passes
without a gain (default 5) end the run with exit 5, naming the stall count and
last value. `--until` still decides success. The value and the change since the
last pass go into the resume prompt next to the check output. The command is
baselined once before pass 1; a failing or non-integer reading there is exit 2,
but the same thing later is just a stall.

## Concurrency

Concurrent runs in one directory do not interfere — each has its own session,
temp prompt and export. The limit is upstream. On the free tier **five
concurrent sessions is the observed safe ceiling**: eight were throttled on
about a third of passes, five with `--backoff 60` ran clean for an hour.

`--max-concurrent N` enforces it machine-wide (a lock directory under
`${TMPDIR:-/tmp}/devin-task-slots`, `DEVIN_TASK_SLOT_DIR` to move it), so you
can fire off twenty background runs and only N talk to Devin at once. A slot is
taken before each pass and released on every exit path, including a `--timeout`
kill and SIGTERM; a slot whose owner died is reclaimed. Waiting longer than
`--slot-timeout SECS` (default 600) exits 6, which `--retries` re-attempts.
For a batch job the settings that ran clean were
`--max-concurrent 5 --backoff 60 --retries 3`.

## Failure modes

- Exit 3: refused action. The message names the flag to use; check `git status`.
- Exit 124: timed out; the process tree is killed. Narrow the task or raise `--timeout`.
- Exit 5: `--until` check still failing after `--max-passes`, or `--max-stalls`
  consecutive passes with no `--progress` gain. Its last output is on stderr.
- Exit 6: upstream connection error, capacity or rate-limit error, or no free
  `--max-concurrent` slot within `--slot-timeout` (all retryable).
  Devin's own "Connection error, send a message to continue retrying" counts.
  The wrapper already retries these itself up to `--retries N` times
  (default 1), sleeping `backoff × attempt` seconds between attempts — the base
  is `--backoff SECS` (default 30, or `DEVIN_TASK_RETRY_BASE`; the flag wins) —
  before giving up with exit 6. Retry the whole `devin-task` call again, or
  raise `--retries`.
- Exit 7: upstream internal error. Not retried automatically; re-run if it looks transient.
- Exit 8: authentication failure (bad/expired credentials). Run `devin auth status`;
  a refused action (exit 3) is not this — internal-error text inside a
  401/403-looking message is classified as exit 7, not 8.
- Exit 9: empty turn persisted after a nudge. On `swe-1-7*` models a pass can
  exit 0 with no agent message and no tool call (a known upstream failure).
  The wrapper resumes the session once with a fixed nudge prompt; if still
  empty, it exits 9. `--no-empty-retry` skips the resume and exits 9 right
  away. A nudge pass never counts against `--max-passes` or `--json`'s
  `passes`, and an empty turn is not itself retried by `--retries`. A capacity
  or rate-limit failure during the nudge is retried under `--retries` like any
  other pass, and does consume the retry budget.
- Exit 143: the wrapper itself was killed by SIGTERM or SIGINT. It kills
  Devin's process tree on the way out, so nothing is left running.
- Exit 2 also covers a non-integer `--retries`, `--backoff`, `--timeout`,
  `--max-passes`, `--max-concurrent`, `--slot-timeout`, `--max-stalls` or
  `DEVIN_TASK_RETRY_BASE`; these are checked before the first pass.
- `--trace` cannot stream Devin's tool calls live: print mode writes the
  conversation export only at the end and Devin's logs carry no tool calls. The
  heartbeat shows elapsed time and bytes of output so far; the tool-call list
  follows after each pass. Live streaming would need a client for `devin acp`.

## Cost

`swe-1-7-medium`, `swe-1-7` and `glm-5-2` are free on this account. Any other
`--model` bills Devin credits; `devin models list` shows prices. Which models
are free may be plan-specific, so `devin models list` is the source of truth
for your account, not this doc.

Tests: `bash tests/test_devin_task.sh` (106 stub-devin checks plus two live calls).
