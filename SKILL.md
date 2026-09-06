---
name: devin
description: Delegate a self-contained task to the local Devin CLI on the free SWE-1.7 model via the `devin-task` wrapper. Use to offload research, second opinions, mechanical multi-file edits, or side tasks that can run in parallel without spending Claude tokens. Also use when the user says "ask devin", "hand this to devin", or "use swe".
---

# Devin CLI delegation

`devin-task` runs one non-interactive Devin turn in the current directory on
`swe-1-7-medium` (free, 262K context) and prints Devin's final answer to stdout.
It is a symlink in `~/.local/bin` to `scripts/devin-task` in this skill.

```bash
devin-task "prompt"                       # read-only: Devin can read files, run read-only commands
devin-task --edit "prompt"                # may also edit files in the workspace
devin-task --yolo "prompt"                # auto-approves everything, incl. shell commands
devin-task --model swe-1-7 "prompt"       # SWE-1.7 Max, also free; glm-5-2 is free too
devin-task --timeout 300 "prompt"         # default 600s, exits 124 on timeout
printf '%s' "$LONG_PROMPT" | devin-task   # long prompts via stdin
```

When calling from the Bash tool, pass `timeout: 600000` (the tool default of
120s will kill most real tasks) or use `run_in_background: true`. The wrapper
forwards SIGTERM to Devin, so a killed call does not leave a stray process.

## When to use

- Research or summarising a codebase area you don't want to read yourself.
- A second opinion on a diff, plan, or bug hypothesis (independent model family).
- Mechanical, well-specified edits across many files (`--edit`).
- Side tasks that can run in the background while you keep working
  (`run_in_background: true`).

Do not use it for anything that needs the conversation's context Devin can't
see, or where a wrong answer is expensive to detect. You own the result: read
Devin's output critically and verify edits with `git diff`.

## Writing the prompt

Devin starts cold. Put everything it needs in the prompt: goal, relevant paths,
constraints, and the exact output shape you want (e.g. "answer as a markdown
list of file:line findings"). Multi-line prompts are fine; the wrapper passes
them through a file, so quotes and backticks are safe.

## Choosing the mode up front

Devin stops at the first refused action and reports nothing, so pick the mode
the task will actually need instead of escalating after a failure:

- Read-only (default) permits `sed`, `grep`, `wc`, `ls`, `cat` style reads but
  refuses interpreters (`python3 -c` is rejected). Fine for critique, research,
  and summaries.
- `--edit` writes files but still cannot run commands. Devin will almost always
  try to run a script it just wrote, so "write X.py" tasks belong in `--yolo`.
- `--yolo` for anything that runs code, tests, or tools. Say what it may and
  may not touch in the prompt; Devin's own `--sandbox` flag does not work in
  print mode on this account, so the prompt is the only guardrail.

## Failure modes

- Exit 3 with "Devin refused an action": the mode was too restrictive. The
  message names the flag to use. Devin may have written files before stopping,
  so check `git status` before re-running.
- Devin's stdout concatenates its progress messages without newlines; the
  final answer is at the end.
- Exit 124: timed out. Narrow the task or raise `--timeout`.
- Empty stdout with exit 0 should not happen; if it does, check stderr.

## Cost

`swe-1-7-medium`, `swe-1-7` and `glm-5-2` are free on this account. Any
`--model` outside those bills Devin credits; `devin models list` shows prices.

Tests: `bash tests/test_devin_task.sh` (uses a stub devin, plus one live call).
