# devin-task

Hand tasks to the local [Devin CLI](https://docs.devin.ai/cli) from Claude Code
(or any shell) on the free SWE-1.7 model. One command, read-only by default,
with explicit escalation to edits or full autonomy, and a detector for the
CLI's silent-refusal failure mode.

```bash
devin-task "summarise how auth works in src/"          # read-only
devin-task --edit "rename foo() to bar() everywhere"    # may edit files
devin-task --yolo "write add.py and run it"             # may also run commands
```

Ships as a Claude Code skill: once installed, Claude reaches for it on
"ask devin", "hand this to devin", or whenever a self-contained side task
can run on a free model instead of spending Claude tokens.

## Why not the existing repos

- [club-cog/devin-handoff](https://github.com/club-cog/devin-handoff) creates
  cloud Devin sessions through the API. That bills ACUs; this uses the local
  CLI and a free model.
- [ianandersonlol/devin-review-cc](https://github.com/ianandersonlol/devin-review-cc)
  drives the local CLI but is review-only. Its multi-vendor review panel is a
  good complement to this.

## Install

```bash
git clone https://github.com/simplyjackfoster/devin-task.git
cd devin-task && ./install.sh
```

`install.sh` symlinks the checkout to `~/.claude/skills/devin` and the wrapper
to `~/.local/bin/devin-task`, lists your free models, and runs a smoke test.
Requires the Devin CLI to be installed and logged in (`devin auth status`).

Claude Code loads the skill on its next session start. To skip permission
prompts, add `Bash(devin-task:*)` to your allow list.

## Usage

```
devin-task [flags] "prompt"
devin-task [flags] --prompt-file FILE
printf '%s' "$PROMPT" | devin-task [flags]
```

| Flag | Effect |
|---|---|
| (none) | read-only: file tools plus a read-only shell allowlist (below) |
| `--edit` | also write files in the workspace; still no commands beyond the allowlist |
| `--yolo` | run anything. Use for "write a script" tasks: Devin always runs what it wrote |
| `--allow 'Exec(prefix)'` | add a Devin permission rule, repeatable, e.g. `'Exec(python3 -c)'` |
| `--model M` | default `swe-1-7-medium`; `swe-1-7` and `glm-5-2` are also free at time of writing |
| `--cwd DIR` | run there instead of `cd DIR &&` (which trips Claude Code's cwd-reset warning) |
| `--timeout S` | per-pass wall clock, default 600; exit 124 and the process tree is killed |
| `--preamble T` | prepend standing instructions; also `DEVIN_TASK_PREAMBLE` |
| `--inherit-env` | prepend the caller's `python3`, `node` and `CONDA_PREFIX` so Devin uses them |
| `--until CMD` | after each pass run `bash -c CMD`; exit 0 ends the loop, otherwise resume the session with the check output |
| `--max-passes N` | cap for `--until`, default 5; exit 5 when exhausted |
| `--retries N` | retry capacity/rate-limit failures (exit 6) only, default 1; sleeps `5 × attempt` seconds between attempts, overridable via `DEVIN_TASK_RETRY_BASE` |
| `--no-empty-retry` | don't nudge-resume an empty turn (below) once; detection still runs and still exits 9 |
| `--answer-only` | print only Devin's final message |
| `--json` | print `{answer, session_id, exit_code, passes, tool_calls, metrics}`; on a resumed `--until` run `tool_calls` is cumulative across passes, as Devin's export is; `passes` counts only `--until` passes — a nudge pass (below) is never counted |
| `--trace` | heartbeat on stderr every 30s (elapsed, bytes of output) and the tool-call list after each pass |

Exit codes: 0 ok, 2 usage, 3 Devin refused an action, 5 `--until` exhausted,
6 capacity or rate limit (retryable), 7 upstream internal error,
8 authentication failure, 9 empty turn persisted after a nudge, 124 timeout.

### Classifying upstream failures, and `--retries`

When a pass exits non-zero, the wrapper scans Devin's stderr (and captured
stdout) for known upstream failure text, checked in this order so a
transient error is never misread as a dead login:

1. **capacity** (exit 6) — `high demand`, `try again later`, `currently
   busy/overloaded/at capacity`, `server is busy`, `overloaded`, `capacity`
2. **internal error** (exit 7) — `internal error occurred` / `internal
   error`. Devin sometimes wraps this inside a 401/403-looking message, so
   it is matched before the auth patterns below.
3. **auth** (exit 8) — `permission_denied`, `unauthenticated`,
   `unauthorized`, `invalid ... api key/token`, `authentication failed`
4. **rate limit** (exit 6) — `rate limit`, `too many requests`,
   `resource_exhausted`

The existing refusal detection (a rejected tool call → exit 3) keeps
precedence over all of these. Only exit-6 conditions (capacity, rate limit)
are retried, up to `--retries N` times (default 1), sleeping `5 × attempt`
seconds between attempts (5s, then 10s, ...) before re-running the same
pass — a fresh pass, not a session resume, though a pass already resumed
under `--until` stays resumed. Set `DEVIN_TASK_RETRY_BASE` to change the
5-second base (tests use `0`).

### Empty turns and `--no-empty-retry`

On `swe-1-7*` models, a pass sometimes exits 0 having spent the whole turn in
reasoning and emitted nothing: no `agent` step has a non-empty message, and no
step has any tool call. The wrapper checks for this after every pass (before
the `--until` check, so it runs on `--until` passes too) and, on detection,
resumes the same session once (`-r SESSION_ID`) with exactly:

> Your previous turn produced no message and no tool call. Continue the task
> now and finish with a written answer.

If the resumed pass is still empty, the wrapper exits 9 with a stderr line.
If the export is missing or unparseable, the check does nothing — it is not
treated as empty. `--no-empty-retry` skips the resume; detection still runs,
so an empty turn still exits 9, just after one call instead of two. A nudge
pass is never counted in `--json`'s `passes` and never counts against
`--max-passes`. This is separate from `--retries`: empty turns are not
retried by `--retries`, they get their own single nudge.

Caveat: Devin's export is cumulative across a resumed session (see the
`--json` row above), so once `--until` has resumed a session for its own
retry loop, later passes carry earlier passes' messages and tool calls in the
same export — an empty-turn check on pass 3+ of an `--until` run can't
distinguish "this pass was empty" from "an earlier pass wasn't". In practice
this rarely matters: `--until`'s own resume prompt already re-engages Devin
after any pass that made no progress.

### Read-only shell allowlist

Devin's own read-only mode approves shell commands heuristically, and in
practice a plain `head` or `sed -n` sometimes gets refused, which kills the
run. The wrapper generates a config for each run that merges your
`~/.config/devin/config.json` with explicit `Exec(...)` allow rules for:

```
cat head tail "sed -n" grep rg wc ls stat file diff jq cut tr uniq pwd which
git log / git status / git diff / git show
```

Verified: pipes between these pass, `>` redirection and `sed -i` are still
refused. Anything that can write on its own (`python3`, `awk`, `find`,
`sort -o`, `tee`) is deliberately absent; add it with `--allow` when a task
needs it. Needs `python3` on the caller's PATH to build the config; without
it the wrapper warns and runs with Devin's defaults.

### Resumable tasks with `--until`

```bash
devin-task --yolo --cwd ~/proj --until 'python3 check_labels.py chunk_07' --max-passes 12 \
  --prompt-file /tmp/label_chunk_07.md
```

Each failing check resumes the same Devin session (by id, so concurrent runs
in one directory do not collide) with the check's exit code and last 40 lines
of output. Write checks that print what is missing. Run loops in the
background from Claude Code: the Bash tool caps a call at 600s.

### Environment mismatch

Devin runs commands in a login shell, which can order PATH differently from
your caller. On this machine Homebrew's python3 (no duckdb) comes before
miniconda's. `--inherit-env` puts the caller's interpreter paths at the top
of the prompt; `--preamble` does the same for anything else.

### From Claude Code's Bash tool

Pass `timeout: 600000` (the tool's default 120s will kill most real tasks) or
run with `run_in_background: true`. The wrapper forwards SIGTERM and kills
Devin's whole process tree, so a killed call leaves nothing behind.

### Concurrency

Three concurrent runs in one directory worked with no interference. No rate
limit was observed on the free models and none is documented.

## Why a wrapper at all

Verified against Devin CLI 3000.6.14 on macOS:

- In print mode, a refused tool call exits **0 with empty stdout** and only a
  stderr warning. Without detection, a caller reads that as success.
- Stdin prompts are rejected; only inline or `--prompt-file`. Multi-line
  prompts with quotes and backticks break inline, so the wrapper writes a
  temp file.
- `--respect-workspace-trust false` is required or print mode fails in any
  directory not yet trusted.
- macOS has no `timeout` binary.
- `--permission-mode smart` reports "not available" and falls back to normal.
  `--sandbox` forces an "autonomous" mode that also refuses headless. Neither
  gives a safer middle ground between edit and yolo.
- Devin's stdout concatenates progress messages without newlines; the final
  answer is at the end. `--answer-only` and `--json` read it from the
  conversation export instead.
- The export is written only when the run ends and Devin's log files carry no
  tool calls, so `--trace` cannot stream tool calls live. Live streaming would
  need a JSON-RPC client for `devin acp`; that is the planned follow-up.

## Tests

```bash
bash tests/test_devin_task.sh
```

Sixty-five checks against a stub `devin` on PATH (argv, generated config and
allowlist, prompt delivery, preamble, output modes, refusal detection,
timeout, signal propagation, failure classification, `--retries`, the
`--until` loop, empty-turn detection and `--no-empty-retry`) plus two live
calls on the free model.

If you edit `scripts/devin-task` while a run is in flight, write to a temp
file and `mv` it over: bash reads scripts incrementally, so rewriting the file
in place can make a running wrapper resume parsing mid-file when its wait
loop ends.

## Layout

```
SKILL.md              Claude Code skill: when and how Claude should delegate
scripts/devin-task    the wrapper (bash, no dependencies beyond devin)
tests/                stub-based test suite
install.sh            symlinks into ~/.claude/skills and ~/.local/bin
```

MIT.
