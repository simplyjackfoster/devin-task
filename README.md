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
devin-task [--edit | --yolo] [--model M] [--timeout SECS] "prompt"
printf '%s' "$LONG_PROMPT" | devin-task [flags]
```

| Flag | Devin mode | What Devin may do |
|---|---|---|
| (none) | `auto` | read files; run `sed`, `grep`, `wc`, `ls`, `cat` style commands |
| `--edit` | `accept-edits` | also write files in the workspace |
| `--yolo` | `dangerous` | also run any command (`python3`, tests, tools) |

- `--model` defaults to `swe-1-7-medium`. `swe-1-7` and `glm-5-2` are also
  free at time of writing; `devin models list` shows current prices.
- `--timeout` defaults to 600s. On timeout the wrapper kills Devin and exits 124.
- Exit 3 means Devin refused an action in the current mode and stopped. The
  message names the flag to use next.

Pick the mode up front. Devin stops at the first refused action and prints
nothing, and it will almost always try to run a script it just wrote, so
"write X.py" tasks belong in `--yolo` from the start. There is no working
sandbox in print mode, so state in the prompt what Devin may and may not touch.

### From Claude Code's Bash tool

Pass `timeout: 600000` (the tool's default 120s will kill most real tasks) or
run with `run_in_background: true`. The wrapper forwards SIGTERM to Devin, so
a killed call leaves no stray process.

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
  answer is at the end.

## Tests

```bash
bash tests/test_devin_task.sh
```

Nineteen checks against a stub `devin` on PATH (argv, prompt delivery,
refusal detection, timeout, signal propagation) plus one live round-trip on
the free model.

## Layout

```
SKILL.md              Claude Code skill: when and how Claude should delegate
scripts/devin-task    the wrapper (bash, no dependencies beyond devin)
tests/                stub-based test suite
install.sh            symlinks into ~/.claude/skills and ~/.local/bin
```

MIT.
