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
| `--smart` | passes Devin's `--permission-mode smart` (per Devin's help: "additionally auto-runs actions a fast model judges safe"); still gets the generated read-only allowlist. On this account Devin currently reports it "not available" and falls back to normal (see below) |
| `--yolo` | run anything. Use for "write a script" tasks: Devin always runs what it wrote |
| `--allow 'Exec(prefix)'` | add a Devin permission rule, repeatable, e.g. `'Exec(python3 -c)'` |
| `--model M` | default `swe-1-7-medium`; `swe-1-7` and `glm-5-2` are also free at time of writing. Free-ness may be plan-specific: other tooling treats those three as quota-exempt on Pro plans, while a true free-tier account may only reach `swe-1-6-slow`. Run `devin models list` for what's actually free on your account |
| `--cwd DIR` | run there instead of `cd DIR &&` (which trips Claude Code's cwd-reset warning) |
| `--timeout S` | per-pass wall clock, default 600; exit 124 and the process tree is killed |
| `--preamble T` | prepend standing instructions; also `DEVIN_TASK_PREAMBLE` |
| `--inherit-env` | prepend the caller's `python3`, `node` and `CONDA_PREFIX` so Devin uses them |
| `--until CMD` | after each pass run `bash -c CMD`; exit 0 ends the loop, otherwise resume the session with the check output |
| `--max-passes N` | cap for `--until`, default 5; exit 5 when exhausted. Ignored when `--progress` is given |
| `--progress CMD` | after each `--until` pass run `bash -c CMD`; it must print one integer. A pass that does not raise it is a stall, and while the number rises the run is unbounded — `--progress` replaces pass counting |
| `--max-stalls N` | consecutive stalls that end a `--progress` run, default 5; exit 5 |
| `--retries N` | retry connection/capacity/rate-limit failures (exit 6) only, default 1; sleeps `backoff × attempt` seconds between attempts |
| `--backoff S` | retry backoff base in seconds, default 30; also `DEVIN_TASK_RETRY_BASE`, which the flag overrides |
| `--max-concurrent N` | run at most N devin passes at once across every `devin-task` on the machine (default: unlimited). Waits for a free slot; see [Concurrency](#concurrency) |
| `--slot-timeout S` | how long to wait for a slot, default 600; exit 6 on expiry, so `--retries` applies |
| `--no-empty-retry` | don't nudge-resume an empty turn (below) once; detection still runs and still exits 9 |
| `--answer-only` | print only Devin's final message |
| `--json` | print `{answer, session_id, exit_code, passes, tool_calls, metrics}`; on a resumed `--until` run `tool_calls` is cumulative across passes, as Devin's export is; `passes` counts only `--until` passes — a nudge pass (below) is never counted |
| `--trace` | heartbeat on stderr every 30s (elapsed, bytes of output) and the tool-call list after each pass |

Exit codes: 0 ok, 2 usage, 3 Devin refused an action, 5 `--until` exhausted
(`--max-passes`, or `--max-stalls` under `--progress`),
6 connection error, capacity, rate limit or no free concurrency slot
(retryable), 7 upstream internal error,
8 authentication failure, 9 empty turn persisted after a nudge, 124 timeout,
143 the wrapper was killed by SIGTERM or SIGINT.

`--retries`, `--backoff`, `--timeout`, `--max-passes`, `--max-concurrent`,
`--slot-timeout` and `--max-stalls` (and `DEVIN_TASK_RETRY_BASE`) are checked
before the first pass; a non-integer value
is a usage error (exit 2). `--backoff` is validated after it overrides
`DEVIN_TASK_RETRY_BASE`, so a bad env value with a good flag is fine.

### Classifying upstream failures, and `--retries`

When a pass exits non-zero, the wrapper scans Devin's stderr (and captured
stdout) for known upstream failure text, checked in this order so a
transient error is never misread as a dead login:

1. **connection error** (exit 6) — `connection error`, the CLI's
   "Connection error, send a message to continue retrying"
2. **capacity** (exit 6) — `high demand`, `try again later`, `currently
   busy/overloaded/at capacity`, `server is busy`, `overloaded`, `capacity`
3. **internal error** (exit 7) — `internal error occurred` / `internal
   error`. Devin sometimes wraps this inside a 401/403-looking message, so
   it is matched before the auth patterns below.
4. **auth** (exit 8) — `permission_denied`, `unauthenticated`,
   `unauthorized`, `invalid ... api key/token`, `authentication failed`
5. **rate limit** (exit 6) — `rate limit`, `too many requests`,
   `resource_exhausted`

The existing refusal detection (a rejected tool call → exit 3) keeps
precedence over all of these. Only exit-6 conditions (connection error,
capacity, rate limit) are retried, up to `--retries N` times (default 1),
sleeping `backoff × attempt` seconds between attempts (30s, then 60s, ...)
before re-running the same pass — a fresh pass, not a session resume, though a
pass already resumed under `--until` stays resumed. `--backoff SECS` sets the
base, defaulting to 30; `DEVIN_TASK_RETRY_BASE` does the same and the flag wins
(tests use `--backoff 0`). The default was raised from 5 to 30 because the rate
limits observed at concurrency needed roughly 60 seconds to clear.

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
`--max-passes`. An empty turn itself is not a `--retries` condition: it gets
its own single nudge. The nudge pass is otherwise an ordinary pass, so if it
fails with capacity or rate-limit text it is retried under `--retries` like
any other pass, and those attempts do consume the retry budget.

Devin's export is cumulative across a resumed session (see the `--json` row
above), so the check only looks at the steps the current pass actually added
since the last one — the step count before the pass, remembered across
resumes — rather than the whole export, so an empty pass is still caught on
pass 3+ of an `--until` run even though earlier passes' content is still in
the same export.

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

### Progress-based stopping: `--progress` and `--max-stalls`

`--max-passes` is the wrong bound for a job whose size you do not know up
front. `--progress CMD` measures the work instead: after each `--until` pass
the wrapper runs `bash -c CMD` in the working directory and reads a single
integer from its stdout — rows written, files converted, whatever the caller
counts.

```bash
devin-task --yolo --max-concurrent 5 --backoff 60 --retries 3 \
  --until 'test -z "$(./check.sh --missing)"' \
  --progress './check.sh --count' --prompt-file chunk.md
```

- A pass whose number is higher than the previous reading resets the stall
  counter. **While progress continues the run is not bounded** —
  `--progress` replaces pass counting, and `--max-passes` is ignored. It still
  applies when `--progress` is absent.
- A pass whose number did not rise is a **stall**. `--max-stalls N`
  consecutive stalls (default 5) end the run with exit **5** — the same code as
  an exhausted `--max-passes` — and a stderr line naming the stall count and
  the last value.
- `--until` still decides success. `--progress` only decides when to give up.
- The reading and the change since the last pass go into the resume prompt
  next to the check output, so Devin sees both what is missing and whether the
  previous pass moved the needle.

The command is run once **before pass 1** to establish a baseline, so pass 1's
own gain is measured; a job resumed with rows already done that produces none
is correctly a stall. A command that fails or prints a non-integer at that
baseline is a usage error (exit **2**, before any Devin call). From pass 1 on,
the same result counts as a stall instead — a check that breaks halfway through
a long run should not be a crash. `--progress` has no effect without `--until`.

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

Concurrent runs in one directory do not interfere: each has its own session,
temp prompt and export, and `--until` resumes by session id. The limit is
upstream, not local. On the free tier **five concurrent sessions is the
observed safe ceiling**: eight concurrent sessions were throttled on about a
third of passes, while five with `--backoff 60` ran clean for an hour.

`--max-concurrent N` enforces that ceiling for you. It is a machine-wide limit,
shared by every `devin-task` process, not a per-invocation one — start twenty
runs with `--max-concurrent 5` and only five talk to Devin at a time:

```bash
devin-task --yolo --max-concurrent 5 --backoff 60 --retries 3 \
  --until './check.sh' --prompt-file chunk.md
```

A slot is a directory under `${TMPDIR:-/tmp}/devin-task-slots`
(`DEVIN_TASK_SLOT_DIR` overrides it) holding the owning wrapper's pid. `mkdir`
is the atomic primitive — macOS has no `flock` — so `slot-1`..`slot-N` are
claimed race-free. A slot is acquired before each Devin pass and released on
every exit path, including a `--timeout` kill and SIGTERM/SIGINT. A slot whose
pid is no longer alive (a `kill -9`, a reboot) is reclaimed as stale; the
reclaim goes through `mv` first, so when two waiters spot the same dead pid
only one can win and the loser cannot delete the winner's new slot.

If no slot is free the wrapper polls every 2 seconds up to `--slot-timeout
SECS` (default 600) and then exits **6** with a stderr line — the same
retryable class as a rate limit, so `--retries` re-attempts the acquisition.
Without `--max-concurrent` the slot directory is never touched. `--trace`
prints one line when the wait starts and one when the slot is acquired.

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

A hundred and six checks against a stub `devin` on PATH (argv, generated config and
allowlist, prompt delivery, preamble, output modes, refusal detection,
timeout, signal propagation, failure classification, `--retries` and
`--backoff`, integer validation of the numeric flags, the `--max-concurrent`
slot limiter (non-overlap of two concurrent runs, stale-slot reclaim, slot
timeout, and slot release after a `--timeout` kill and after SIGTERM), the
`--until` loop, `--progress`/`--max-stalls` (an unbounded productive run, five
zero-gain passes, a gain resetting the counter, and a non-integer reading), empty-turn detection and
`--no-empty-retry`, including a cumulative-export case where a later `--until`
pass adds only empty steps, a non-object export, and a capacity failure
retried during the nudge) plus two live calls on the free model. Set
`DEVIN_TASK_TEST_NO_LIVE=1` to skip the two live calls (prints `live: skipped`
instead). CI runs this suite with that var set, and the ACP suite, which makes
no live calls, as it is, on every push and pull request.

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

## Experimental: ACP transport

`scripts/devin-task-acp` is a spike, not part of the skill. It drives `devin
acp` — the Agent Client Protocol server, JSON-RPC 2.0 over stdio — instead of
print mode, in Python 3 with nothing but the standard library:

```bash
scripts/devin-task-acp --trace "summarise README.md in one line"
scripts/devin-task-acp --json --approve none "what would you run for X?"
```

Two things ACP buys over print mode: tool calls arrive as they happen, so
`--trace` streams them live, and every shell command comes back as a
`session/request_permission` request that this script answers itself, so the
permission policy lives here instead of in a generated Devin config.

`--approve` picks that policy:

- `read` (default) allows a command only if all three hold: nothing anywhere in
  the string spawns a command or opens a file for writing (no backtick, `$(…)`,
  `<(…)`, `>(…)` or `>` — only a true descriptor duplication, `2>&1`, `>&2` or
  `>&-`, is exempt; `>&file` is a redirect and is denied); **every** `&&` /
  `||` / `;` / `|` / `&` separated segment starts with one of
  cat head tail sed grep rg wc ls stat file diff jq cut tr uniq pwd which, or
  `git`; and no segment is an in-place `sed` (`-i`, `-i.bak`, `-I`,
  `--in-place`, or a bundled cluster such as `-ni.bak`) or a
  `git` outside log/status/diff/show or carrying `--output`.
- `all` allows everything, `none` cancels everything (a dry run of what Devin
  would reach for).

Anything cancelled is printed to stderr as `denied: <command>`. A denial does
not end the run: Devin continues, says the command was rejected, and still
finishes with `end_turn`.

Other flags mirror the wrapper: `--model`, `--timeout`, `--cwd`,
`--prompt-file`, `--json`, `--trace`, positional or stdin prompt.
`--answer-only` drops the trailing stats line; stdout is only the agent's
message either way. Exit codes: 0 ok, 2 usage, 3 something was denied and the
answer came back empty, 124 timeout, 143 signalled, 1 JSON-RPC error.

Not covered yet: no `--edit` equivalent, no `--until` loop, no session resume,
no `--allow` for extra rules.

The `read` policy is a word match over the raw string, not a shell parser, and
it errs towards denying. It refuses every redirection (`>`, `>>`, `&>`), every
substitution (backtick, `$(…)`, `<(…)`, `>(…)`) and every chaining operator
that introduces a non-allowlisted command — which also means it refuses
harmless ones: `cd sub && cat f` is denied because `cd` is not on the list, and
quoting is not understood, so `grep -E "a|b" f` and `sed -n 's/a;b/c/p' f` are
denied over the `|` and `;` inside the quotes. A
`shlex(punctuation_chars=True)` tokeniser would fix the quoting cases and is
the obvious follow-up. The checks are this blunt because a live run had Devin
fold two requested commands into a single chained one, and each looser version
of the rule had a way to smuggle a write past it.

```bash
bash tests/test_devin_task_acp.sh
```

Sixty-three checks against a stub `devin` that speaks enough of the protocol.
No live call in there; the spike's live check is run by hand.
