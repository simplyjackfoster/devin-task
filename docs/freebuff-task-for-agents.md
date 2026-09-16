# freebuff-task — instructions for an agent

You (the calling agent) can hand a self-contained coding or research task to the
Freebuff CLI's free models through `freebuff-task`, instead of doing it yourself.
It drives the real Freebuff TUI in a pseudo-terminal and returns the final answer
plus the diff it produced. Each run is isolated in a throwaway git worktree, so
Freebuff's edits never touch the working tree unless you apply them.

## When to use it
- Offload a self-contained side task to a free model to save your own tokens.
- Get a second implementation or opinion on a bounded problem.
- Mechanical multi-file edits you will review via the diff before applying.

Do NOT use it for tasks that need your own context, secrets, or anything the
worktree can't see (it branches from HEAD; uncommitted changes are invisible).

## Invocation
```
freebuff-task [flags] "prompt"
freebuff-task [flags] --prompt-file FILE
printf '%s' "$PROMPT" | freebuff-task [flags]
```
Always pass `--json` when you will parse the result. Always set `--cwd` to the
repo you want it to work in.

## The flags that matter
- `--cwd DIR` — repo to work in (must be inside a git repo). Default: current dir.
- `--json` — machine-readable result (see keys below). Use this.
- `--apply` — after a successful run, apply the worktree diff to the REAL tree.
  Refuses (exit 1) if it doesn't apply cleanly; the diff is still reported.
- `--diff` — include the unified diff in the output.
- `--answer-only` — print only the final answer, nothing else.
- `--model M` — default `glm-5.3-flash` (unmetered; prefer it). Others cost a session.
- `--timeout S` — whole-run wall clock, default 600. Note: model selection time is
  added on top, so worst case is roughly startup + S.
- `--until CMD` / `--progress CMD` / `--max-passes N` / `--max-stalls N` — iterate:
  after each pass run `bash -c CMD`; exit 0 ends the loop. `--progress` prints one
  integer per pass and bounds the loop by stalls instead of pass count.
- `--trace` — stream Freebuff's tool calls to stderr as they happen.
- `--preamble T` — prepend standing instructions (env `FREEBUFF_TASK_PREAMBLE`).
  The default already tells Freebuff not to ask questions and to put its final
  message last.

## Reading `--json`
Keys: `answer`, `session_id`, `worktree`, `branch`, `diff_stat`, `tool_calls`,
`elapsed`, `exit_code`, and for loops `passes` and `resume`. Take the result from
`answer`; inspect `diff_stat`/the worktree before deciding to `--apply`.

## Exit codes (branch on these)
- 0 ok
- 1 driver error (or `--apply` didn't apply cleanly)
- 2 usage error
- 3 the agent stopped to ask a question — the question is in `answer`; answer it and re-run
- 5 `--until` loop exhausted
- 6 rate limited / queued / session refused or exhausted / no instance slot — retryable, back off and retry
- 8 not signed in — a human must run `freebuff` once to log in
- 9 empty turn — Freebuff produced no answer; re-run
- 124 timeout
- 143 killed by signal

## Hard limits
- One Freebuff instance per machine: concurrent calls queue on a lock, they do not
  run in parallel. Do not launch several at once expecting speed.
- Requires a logged-in Freebuff (`~/.config/manicode`) with onboarding cleared. If
  you get exit 8, surface it to a human; do not try to authenticate.
- It runs the genuine Freebuff CLI. It does not call any API or forge identity.
- A worktree run shares the real repo's Freebuff project identity (the worktree
  leaf is named after the repo), so it reuses the repo's already-admitted
  free session. If a run still stalls at admission, use `--no-worktree`.

## Typical patterns
Review before applying:
```
freebuff-task --cwd "$REPO" --json "refactor foo() to bar() everywhere" > out.json
# inspect .diff_stat / the .worktree, then:
freebuff-task --cwd "$REPO" --apply "..."   # or git -C <worktree> diff | git -C "$REPO" apply
```
Iterate until tests pass:
```
freebuff-task --cwd "$REPO" --until "npm test" --max-passes 5 "make the test suite green"
```
