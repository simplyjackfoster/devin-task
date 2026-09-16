# freebuff-task: drive the Freebuff CLI as a headless subagent

Date: 2026-09-16. Status: approved design, not yet implemented.

## Goal

A `freebuff-task` wrapper that behaves like `devin-task`: one command, a prompt in,
an answer out, machine-readable with `--json`, so Claude Code (or any agent) can
hand a self-contained task to Freebuff's free models without spending its own
tokens. Freebuff only ships an interactive TUI, so the wrapper drives that TUI in
a pseudo-terminal and reads the result from the transcript Freebuff writes to disk.

## What was ruled out, and why

Freebuff (`npm i -g freebuff`, 0.0.175 at time of writing) is a thin TUI over the
public `@codebuff/sdk`. Its login token lives in
`~/.config/manicode/credentials.json` (`default.authToken`) and its free agents
are bundled definitions named `base3-free-<model>` (for example
`base3-free-glm-5-3-flash` on `z-ai/glm-5.3-flash`). Calling the SDK with that
token and one of those agent definitions is refused by the backend:

```
403 free_mode_cli_required
"Free mode is only available through the freebuff CLI. Install it with
`npm i -g freebuff`, then run `freebuff`. Calling the API directly is not
supported and may get your account banned."
```

The vendor gates free mode on the real CLI and warns of a ban. The wrapper does
not imitate the CLI's client identity, fingerprint or `x-freebuff-*` headers to
get past that gate. It runs the real CLI.

There is no non-interactive mode. The binary's only flags are `--cwd DIR`,
`--continue [id]`, `-v`, `-h` and a `login` command. With stdin not a TTY, or
stdin at `/dev/null`, it still renders the full TUI (including ads) to stdout and
never reads the piped prompt. `FREEBUFF_MODE` is a compile-time constant.

## Facts about the CLI the design relies on

- Real binary: `~/.config/manicode/freebuff` (Bun-compiled). The npm package is a
  launcher that downloads and updates it. `FREEBUFF_CONFIG_DIR` overrides the
  config directory.
- Per-session transcript, written live:
  `~/.config/manicode/projects/<cwd basename>/chats/<ISO timestamp>/` containing
  `chat-messages.json` (user and AI messages; AI messages carry `blocks[]`,
  `isComplete`, and a `[response interrupted]` marker when cut off),
  `log.jsonl` (includes `"[send-message] Sending message with sdk run config"`
  and per-iteration records with `runId`), `chat-meta.json`, `run-state.json`.
- The project key is the cwd basename, so two repos with the same basename share
  a project directory. The wrapper therefore identifies a session by the new chat
  directory that appears after spawn, never by project.
- `~/.config/manicode/settings.json` holds `mode`, `freebuffModel`,
  `hasSubmittedFirstPrompt`, `freebucksIntroSeenAt`. The last two gate first-run
  onboarding screens ("Press Enter to continue").
- `freebuff-instance-owner.json` holds one `{instanceId, pid}`; the server admits
  sessions per instance id. Assume one instance per machine until verified.
- Slash commands present in the binary: `/ads /compact /earn /help /login /logout
  /max /model /new /session /settings /usage`. No `/exit`.
- No permission prompts exist. Freebuff runs `run_terminal_command` without
  asking. Every run is effectively `--yolo`.
- The agent has an `ask_user` tool. Freebuff's own unattended runner suppresses
  it with the preamble line: "There is nobody watching this run. Do not ask
  questions; decide and proceed, or stop."
- GLM 5.3 Flash is the default model and "costs no session at all" (README), so
  it is the default here too.

## CLI surface

```
freebuff-task [flags] "prompt"
freebuff-task [flags] --prompt-file FILE
printf '%s' "$PROMPT" | freebuff-task [flags]
```

| Flag | Effect |
|---|---|
| `--cwd DIR` | repo to work in, default current directory. Must be inside a git repo (usage error otherwise, unless `--no-worktree`). |
| `--no-worktree` | run in the real working tree instead of an isolated one. Off by default. |
| `--apply` | on exit 0, apply the worktree's diff to the real working tree with plain `git apply`; refuse (exit 1, diff still printed with `--diff`) if it does not apply cleanly. |
| `--diff` | print the worktree diff after the answer. |
| `--model M` | Freebuff model, default `glm-5.3-flash`. Selected through the TUI's `/model` picker at session start when it differs from `settings.json`. |
| `--timeout S` | whole-run wall clock, default 600; exit 124. |
| `--slot-timeout S` | how long to wait for the machine-wide instance lock, default 600; exit 6 on expiry. |
| `--preamble T` | prepend standing instructions. Env `FREEBUFF_TASK_PREAMBLE`. The default preamble is the unattended-run line above plus "Your final message is the answer; put it last." |
| `--keep-worktrees N` | old worktrees to leave behind, default 3; older ones are removed at the start of a run. |
| `--answer-only` | print only the final message. |
| `--json` | print `{answer, session_id, worktree, branch, diff_stat, exit_code, tool_calls, elapsed}`. |
| `--trace` | live on stderr: driver state transitions, and every tool call as Freebuff logs it (tailed from `log.jsonl`, see below). |
| `--summary` | one line on stderr at exit (env `FREEBUFF_TASK_SUMMARY=1`). |

Exit codes: 0 ok, 1 driver error, 2 usage, 3 the agent stopped to ask a
question (the question is the answer), 5 `--until` exhausted, 6 rate limited, queued, session refused or
exhausted, or no instance slot (retryable), 8 not signed in, 9 empty turn (no AI
message after the send landed), 124 timeout, 143 killed by SIGTERM or SIGINT.

| `--until CMD` | after each pass run `bash -c CMD` in the run cwd; exit 0 ends the loop, otherwise resume the same Freebuff conversation with the check's output as the next prompt. Same semantics as devin-task. |
| `--max-passes N` | cap for `--until`, default 5; exit 5 when exhausted. Ignored when `--progress` is given. |
| `--progress CMD` | after each `--until` pass run `bash -c CMD`; it prints one integer. A pass that does not raise it is a stall; while it rises the run is unbounded. |
| `--max-stalls N` | consecutive stalls that end a `--progress` run, default 5; exit 5. |

Deliberately absent: `--edit`, `--yolo`, `--allow` (no permission model; the
worktree is the boundary), `--max-concurrent` (one instance), `--retries`
(callers retry on 6).

`--until` resumes a conversation with `freebuff --continue <id> --cwd <run cwd>`,
so the agent keeps its context between passes as it does under devin-task. This
depends on `--continue` accepting the chat directory name (verification item 2).
If it does not, the fallback is a fresh session per pass whose prompt carries the
previous answer and the check output; the flag surface is the same either way and
`--json` reports which mode ran (`resume: "continue" | "fresh"`).

## The run

1. **Lock.** `flock` on `$TMPDIR/freebuff-task.lock`, waiting up to
   `--slot-timeout`. Exit 6 on expiry.
2. **Worktree.** From the repo root of `--cwd`: prune worktrees under
   `$TMPDIR/freebuff-task/` beyond `--keep-worktrees`, then
   `git worktree add --detach $TMPDIR/freebuff-task/wt-<ts> HEAD`. Uncommitted
   changes in the real checkout are not copied; documented, `--no-worktree` is
   the escape hatch. With `--no-worktree`, the run cwd is `--cwd` itself.
3. **Spawn.** `freebuff --cwd <run cwd>` via `pty.fork()`, `TERM=xterm-256color`,
   window 80x24 set with `TIOCSWINSZ`, own process group. A reader thread drains
   the PTY into a bounded rolling buffer (last 64 KiB) used only for failure
   detection and `--trace`.
4. **Ready.** Snapshot the project's `chats/` directory before spawn. Ready means
   a new chat directory exists and the screen buffer has been unchanged for 750
   ms. If `--model` differs from `settings.json`'s `freebuffModel`, drive `/model`
   and select it, then wait for quiet again.
5. **Send.** Preamble, blank line, prompt, wrapped in bracketed paste
   (`ESC[200~` ... `ESC[201~`), then `\r`. The send has landed when `log.jsonl`
   gains a "Sending message with sdk run config" record; if it does not within
   30 s, resend once, then exit 9.
6. **Complete.** Poll every 500 ms. Done when `chat-messages.json`'s last AI
   message has `isComplete: true`, no `[response interrupted]` text, and
   `log.jsonl` shows the run's finish record for the same `runId` (or, if that
   record format is not stable, `chat-meta.json` unchanged for 3 s after
   `isComplete`). An `ask_user` block in that message means exit 3.
7. **Exit.** Ctrl-C twice with 500 ms between, wait 3 s, then SIGTERM the
   process group, then SIGKILL after 3 s more. Ctrl-D is the fallback if
   verification shows Ctrl-C is swallowed. The worktree is never removed on exit.
8. **Report.** Answer is the concatenated `text` blocks (not reasoning blocks) of
   the last AI message. Diff and `--stat` come from `git -C <worktree> diff` (plus
   `git status --porcelain` for untracked files, added with `git add -N`). Then
   `--apply` if asked, then output.

## Streaming tool calls (`--trace`)

Freebuff appends to the session's `log.jsonl` while the run is in progress. The
driver tails it from the offset at send time and, for each record that carries a
tool call or tool result, prints one line to stderr as it appears:

```
freebuff-task: [12.3s] read_files README.md, SKILL.md
freebuff-task: [14.9s] run_terminal_command "python3 -m pytest -q"
freebuff-task: [21.0s] str_replace scripts/foo.py
```

The exact record shape is pinned in the verification pass (item 4) and mirrored
by `tests/fake-freebuff`. Records that do not match are ignored, never fatal.
The same tail feeds `tool_calls` in `--json` (count and names, cumulative across
`--until` passes) so callers get what devin-task's `tool_calls` gave.

## Failure classification

Checked in this order, transient first, against the screen buffer and log:

| Signal | Exit |
|---|---|
| rate limited / queued text, or the admission message "cannot safely start or resume your session" | 6 |
| "Press Enter to buy more credits", "continue in a new session" (session exhausted) | 6 |
| "Not signed in", login screen | 8 |
| send landed but no AI message before timeout | 9 |
| onboarding "Press Enter to continue" screen before the prompt is ready | 1 with a message pointing at `install.sh`'s first-run step |

## Install and skill

- `install.sh` symlinks `scripts/freebuff-task` to `~/.local/bin/freebuff-task`,
  checks `freebuff --version`, checks `settings.json` for
  `hasSubmittedFirstPrompt`, and if missing tells the user to run `freebuff` once
  interactively to clear onboarding and log in.
- `SKILL.md` gains a "Freebuff" section: when to prefer it (unmetered GLM 5.3
  Flash, edits allowed by default because of the worktree), the `--apply`
  workflow, and the one-instance limit.

## Testing

- `tests/fake-freebuff`: a Python script that draws a prompt line to the
  terminal, creates the chat directory and files with the same shapes, and on
  Enter writes a scripted `chat-messages.json` and `log.jsonl` (configurable via
  env: normal answer, ask_user, interrupted, rate-limited screen, not signed in,
  never-ready). It exits on Ctrl-C twice.
- `tests/test_freebuff_task.sh`: drives the wrapper against the fake through
  `PATH`, covering each exit code, `--json` shape, worktree creation and pruning,
  `--apply` success and refusal, `--no-worktree`, bracketed-paste of a multi-line
  prompt, timeout, `--trace` tool-call lines, and `--until` / `--progress` loops
  in both resume modes.
- `tests/test_freebuff_task_live.sh`: opt-in (`FREEBUFF_TASK_LIVE=1`), one real
  run that reads a file and reports its content.

## Verification pass before finalizing the state machine

Against the real binary, recorded in the README:

1. Which key sequence exits: Ctrl-C twice, Ctrl-D, or only SIGTERM.
2. Whether `--continue <id>` takes the chat directory name and resumes with context (selects the `--until` resume mode).
3. Whether a second concurrent instance is refused, and with what text.
4. How the `/model` picker is driven from keys, the exact finish record in `log.jsonl`, and the shape of its tool-call and tool-result records.
5. Whether a prompt containing newlines submits early without bracketed paste.

## Limitations

- Uncommitted changes in the real checkout are invisible to an isolated run.
- One run at a time per machine.
- Freebuff shows ads in the TUI; they are ignored, not suppressed.
- The transcript format is unversioned; a Freebuff update can break detection.
  The fake in `tests/` pins the shapes seen in 0.0.175.
