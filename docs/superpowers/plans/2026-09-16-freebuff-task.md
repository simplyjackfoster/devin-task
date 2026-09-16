# freebuff-task Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `freebuff-task` wrapper that hands a self-contained task to the Freebuff CLI's free models and returns the answer and diff, machine-readable, so an agent can use it as a subagent the way it uses `devin-task`.

**Architecture:** Freebuff ships only an interactive TUI, so the wrapper spawns the real `freebuff` binary under a pseudo-terminal, drives it with keystrokes, and reads the answer from the transcript Freebuff writes to `~/.config/manicode/projects/<basename>/chats/<ts>/`. Each run is isolated in a throwaway git worktree by default. The real CLI is driven as-is; no request identity is forged.

**Tech Stack:** Python 3 standard library only (`pty`, `os`, `select`, `termios`, `fcntl`, `json`, `argparse`, `subprocess` for git). Bash for tests and install. Matches `scripts/devin-task-acp`.

**Spec:** `docs/superpowers/specs/2026-09-16-freebuff-task-design.md` — read it alongside this plan.

## Global Constraints

- Python 3 stdlib only. No pip dependencies, no node-pty, no tmux.
- The wrapper never forges Freebuff's client identity, fingerprint or `x-freebuff-*` headers. It runs the genuine `freebuff` binary and reads its on-disk transcript.
- Config lives at `~/.config/manicode/` (override `FREEBUFF_CONFIG_DIR`). Real binary: `~/.config/manicode/freebuff`. Transcript root: `~/.config/manicode/projects/<cwd basename>/chats/<ISO timestamp>/`.
- Session identity is the new chat directory that appears after spawn, never the project directory (basename collisions share a project).
- Default model `glm-5.3-flash` (unmetered). Default preamble: "There is nobody watching this run. Do not ask questions; decide and proceed, or stop." + "Your final message is the answer; put it last."
- Exit codes: 0 ok, 1 driver error, 2 usage, 3 agent asked a question, 5 `--until` exhausted, 6 rate limited / queued / session refused / exhausted / no instance slot (retryable), 8 not signed in, 9 empty turn, 124 timeout, 143 killed.
- Prog name is `freebuff-task`. Follow `scripts/devin-task-acp` conventions: single file, `parse_args`, `read_prompt`, `main(argv)`, argparse with `add_help=True`.
- Commit after every green step. Commit message trailer:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

---

## File Structure

- Create `scripts/freebuff-task` — the driver (single Python file).
- Create `tests/fake-freebuff` — a scriptable Python test double that mimics the real TUI's disk writes and key handling.
- Create `tests/test_freebuff_task.sh` — offline test suite driving the wrapper against the fake via `PATH`.
- Create `tests/test_freebuff_task_live.sh` — opt-in single live run.
- Modify `install.sh` — symlink the wrapper, check `freebuff` and onboarding state.
- Modify `SKILL.md` — add the Freebuff section.
- Modify `README.md` — usage, verification findings table, limitations.

---

### Task 1: Verification pass against the real binary

Records the five unknowns the state machine depends on. No code; produces a findings table committed into `README.md`. Everything the fake mimics in later tasks is pinned here.

**Files:**
- Modify: `README.md` (append a `## Freebuff CLI facts (verified)` section)

- [ ] **Step 1: Confirm the exit key.** Run `freebuff --cwd /tmp` in a real terminal, send a trivial prompt, wait for the answer, then try Ctrl-C once, Ctrl-C twice, Ctrl-D. Record which cleanly exits (process gone, terminal restored). Expected from the binary strings: no `/exit`; likely Ctrl-C twice.

- [ ] **Step 2: Confirm `--continue`.** Note the finished chat dir name (e.g. `2026-09-16T13-55-35.778Z`). Run `freebuff --continue <that-name> --cwd <same cwd>`. Record whether it resumes with prior context, ignores the arg, or errors. This selects the `--until` resume mode.

- [ ] **Step 3: Confirm single-instance.** With one `freebuff` running, start a second `freebuff --cwd /tmp/other`. Record whether the second is refused and the exact on-screen/admission text.

- [ ] **Step 4: Pin log record shapes.** After one run, `cat ~/.config/manicode/projects/<basename>/chats/<ts>/log.jsonl`. Record verbatim: (a) the "Sending message with sdk run config" record and its `runId`, (b) the run-finish record that pairs with it, (c) a tool-call record and a tool-result record (fields carrying tool name and args). These pin `--trace` and completion detection.

- [ ] **Step 5: Confirm bracketed paste and `/model`.** Paste a two-line prompt without bracketed paste and see if the first line submits early. Then open `/model`, record the keystrokes to select an entry (arrow/enter, or type-to-filter).

- [ ] **Step 6: Write findings + commit.** Fill this table in `README.md` with real values, then commit.

```markdown
## Freebuff CLI facts (verified)

Verified against freebuff <version> on <date>. The driver depends on these.

| Fact | Finding |
|---|---|
| Exit key | <e.g. Ctrl-C twice> |
| `--continue <chat-dir-name>` | <resumes with context / ignored / errors> |
| Second concurrent instance | <refused with "<text>" / allowed> |
| Send-landed log record | `<verbatim jq-ish shape>` |
| Run-finish log record | `<verbatim shape, and the field linking it to runId>` |
| Tool-call log record | `<verbatim shape: fields for tool name + args>` |
| Bracketed paste needed for newlines | <yes/no> |
| `/model` selection keys | <e.g. type name, Enter> |
```

```bash
git add README.md
git commit -m "Record verified Freebuff CLI facts for the driver"
```

---

### Task 2: The fake-freebuff test double

A Python script that stands in for `freebuff` on `PATH` during tests. It reproduces the disk writes and key handling pinned in Task 1, scripted by env vars so each test picks a scenario. Everything downstream is tested against this, never the network.

**Files:**
- Create: `tests/fake-freebuff`
- Test: `tests/test_freebuff_task.sh` (first assertion only; full suite grows in later tasks)

**Interfaces:**
- Produces: an executable `tests/fake-freebuff` that, given `--cwd DIR`, honours `FREEBUFF_CONFIG_DIR` for its transcript root, and reads `FAKE_FREEBUFF_SCENARIO` ∈ {`answer`, `ask_user`, `interrupted`, `ratelimited`, `notsignedin`, `neverready`, `toolcalls`, `empty`} plus `FAKE_FREEBUFF_ANSWER`, `FAKE_FREEBUFF_WRITE` (a `path:::content` to write into cwd so a diff exists), `FAKE_FREEBUFF_DELAY`.
- Produces the same transcript layout the driver reads: `<config>/projects/<basename(cwd)>/chats/<ts>/{chat-messages.json,log.jsonl,chat-meta.json}`.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_freebuff_task.sh (new file; bash, set -euo pipefail)
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; export FREEBUFF_CONFIG_DIR="$WORK/config"; mkdir -p "$FREEBUFF_CONFIG_DIR"
export PATH="$ROOT/tests:$PATH"           # fake-freebuff shadows the real one
REPO="$WORK/repo"; mkdir -p "$REPO"; ( cd "$REPO" && git init -q && git commit -q --allow-empty -m init )
fail=0; ok(){ echo "ok - $1"; }; bad(){ echo "NOT ok - $1"; fail=1; }

# fake writes a transcript the driver can find
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="pong" \
  "$ROOT/tests/fake-freebuff" --cwd "$REPO" <<<"" >/dev/null 2>&1 || true
found="$(find "$FREEBUFF_CONFIG_DIR/projects" -name chat-messages.json | head -1)"
[ -n "$found" ] && grep -q pong "$found" && ok "fake writes transcript" || bad "fake writes transcript"

exit $fail
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash tests/test_freebuff_task.sh`
Expected: FAIL — `tests/fake-freebuff` does not exist.

- [ ] **Step 3: Write the fake**

```python
#!/usr/bin/env python3
# tests/fake-freebuff: stand-in for the real freebuff TUI during offline tests.
import os, sys, json, time, datetime, pathlib, signal

def cfg_root():
    base = os.environ.get("FREEBUFF_CONFIG_DIR") or os.path.expanduser("~/.config/manicode")
    return pathlib.Path(base)

def main(argv):
    cwd = os.getcwd()
    if "--cwd" in argv:
        cwd = argv[argv.index("--cwd") + 1]
    scen = os.environ.get("FAKE_FREEBUFF_SCENARIO", "answer")
    answer = os.environ.get("FAKE_FREEBUFF_ANSWER", "done")
    delay = float(os.environ.get("FAKE_FREEBUFF_DELAY", "0"))
    ts = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H-%M-%S.%f")[:-3] + "Z"
    chat = cfg_root() / "projects" / pathlib.Path(cwd).name / "chats" / ts
    chat.mkdir(parents=True, exist_ok=True)
    log = chat / "log.jsonl"
    msgs = chat / "chat-messages.json"
    meta = chat / "chat-meta.json"
    msgs.write_text("[]"); meta.write_text(json.dumps({"messageCount": 0}))
    sys.stdout.write("Freebuff ready. Type your message.\n"); sys.stdout.flush()
    if scen == "neverready":
        # never becomes usable: sit until killed
        signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
        time.sleep(3600)
    # wait for the driver's pasted prompt on stdin (a line)
    try:
        prompt = sys.stdin.readline()
    except Exception:
        prompt = ""
    if scen == "notsignedin":
        sys.stdout.write("Not signed in. Run `freebuff login`.\n"); sys.stdout.flush(); time.sleep(0.2); return
    if scen == "ratelimited":
        sys.stdout.write("Rate limited and shared by all users: queues when busy.\n"); sys.stdout.flush(); time.sleep(0.2); return
    run_id = "run-" + ts
    with log.open("a") as fh:
        fh.write(json.dumps({"msg": "[send-message] Sending message with sdk run config",
                             "data": {"runConfig": {"agent": "base3-free-glm-5-3-flash"}}}) + "\n")
    if scen == "empty":
        time.sleep(delay); return
    if scen == "toolcalls":
        with log.open("a") as fh:
            for t, a in (("read_files", "README.md"), ("run_terminal_command", "pytest -q")):
                fh.write(json.dumps({"type": "tool_call", "runId": run_id, "toolName": t, "input": a}) + "\n")
    time.sleep(delay)
    # optionally make a file change so a worktree diff exists
    w = os.environ.get("FAKE_FREEBUFF_WRITE")
    if w:
        path, _, content = w.partition(":::")
        p = pathlib.Path(cwd) / path; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(content)
    blocks = [{"type": "text", "content": answer, "textType": "text"}]
    interrupted = scen == "interrupted"
    if interrupted:
        blocks[0]["content"] = answer + "\n[response interrupted]"
    if scen == "ask_user":
        blocks = [{"type": "ask_user", "questions": ["Which database?"]},
                  {"type": "text", "content": "I need to know the database.", "textType": "text"}]
    msgs.write_text(json.dumps([
        {"variant": "user", "content": prompt.strip()},
        {"variant": "ai", "blocks": blocks, "isComplete": not interrupted,
         "metadata": {}, "timestamp": "now"}]))
    meta.write_text(json.dumps({"messageCount": 2, "messagesMtimeMs": time.time() * 1000}))
    with log.open("a") as fh:
        fh.write(json.dumps({"msg": "[send-message] run finished", "runId": run_id, "status": "done"}) + "\n")
    # idle until the driver sends the exit key(s), then quit
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    sys.stdout.write("\n> "); sys.stdout.flush()
    try:
        while True:
            ch = sys.stdin.read(1)
            if ch == "" or ch == "\x04":  # EOF / Ctrl-D
                return
    except Exception:
        return

if __name__ == "__main__":
    main(sys.argv[1:])
```

Then `chmod +x tests/fake-freebuff`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_freebuff_task.sh`
Expected: `ok - fake writes transcript`.

- [ ] **Step 5: Commit**

```bash
chmod +x tests/fake-freebuff tests/test_freebuff_task.sh
git add tests/fake-freebuff tests/test_freebuff_task.sh
git commit -m "Add fake-freebuff test double"
```

---

### Task 3: Driver skeleton — arg parsing, prompt input, exit-code constants

**Files:**
- Create: `scripts/freebuff-task`
- Test: `tests/test_freebuff_task.sh` (append)

**Interfaces:**
- Produces: `parse_args(argv) -> argparse.Namespace` with attributes `cwd, no_worktree, apply, diff, model, timeout, slot_timeout, preamble, keep_worktrees, answer_only, json, trace, summary, until, max_passes, progress, max_stalls, prompt, prompt_file`.
- Produces: `read_prompt(args, err) -> str` (argument, else `--prompt-file`, else stdin; usage error 2 if empty).
- Produces: module constants `EXIT_OK=0, EXIT_ERR=1, EXIT_USAGE=2, EXIT_ASK=3, EXIT_UNTIL=5, EXIT_RETRY=6, EXIT_AUTH=8, EXIT_EMPTY=9, EXIT_TIMEOUT=124`.
- Produces: `main(argv) -> int`.

- [ ] **Step 1: Write the failing test** (append to `tests/test_freebuff_task.sh` before `exit $fail`)

```bash
FT="$ROOT/scripts/freebuff-task"
# usage error when no prompt
set +e; printf '' | "$FT" --cwd "$REPO" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 2 ] && ok "empty prompt is usage error 2" || bad "empty prompt rc=$rc"
# --prompt-file is read
echo "hi there" > "$WORK/p.txt"
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="pong" \
  "$FT" --cwd "$REPO" --prompt-file "$WORK/p.txt" --answer-only >"$WORK/o1" 2>/dev/null || true
grep -q pong "$WORK/o1" && ok "answer-only prints answer" || bad "answer-only: $(cat "$WORK/o1")"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/test_freebuff_task.sh`
Expected: FAIL — `scripts/freebuff-task` missing.

- [ ] **Step 3: Write the skeleton** (`scripts/freebuff-task`; the later tasks fill `run_once`)

```python
#!/usr/bin/env python3
"""freebuff-task: hand a one-shot task to the Freebuff CLI's free models.

Drives the real `freebuff` TUI in a pty and reads the answer from the transcript
Freebuff writes to ~/.config/manicode/projects/<cwd basename>/chats/<ts>/.
See docs/superpowers/specs/2026-09-16-freebuff-task-design.md.
"""
import argparse, json, os, sys

PROG = "freebuff-task"
EXIT_OK, EXIT_ERR, EXIT_USAGE, EXIT_ASK = 0, 1, 2, 3
EXIT_UNTIL, EXIT_RETRY, EXIT_AUTH, EXIT_EMPTY, EXIT_TIMEOUT = 5, 6, 8, 9, 124
DEFAULT_PREAMBLE = ("There is nobody watching this run. Do not ask questions; "
                    "decide and proceed, or stop. Your final message is the "
                    "answer; put it last.")

def parse_args(argv):
    p = argparse.ArgumentParser(prog=PROG, add_help=True)
    p.add_argument("--cwd")
    p.add_argument("--no-worktree", action="store_true")
    p.add_argument("--apply", action="store_true")
    p.add_argument("--diff", action="store_true")
    p.add_argument("--model", default="glm-5.3-flash")
    p.add_argument("--timeout", type=float, default=600)
    p.add_argument("--slot-timeout", type=float, default=600)
    p.add_argument("--preamble", default=os.environ.get("FREEBUFF_TASK_PREAMBLE", DEFAULT_PREAMBLE))
    p.add_argument("--keep-worktrees", type=int, default=3)
    p.add_argument("--answer-only", action="store_true")
    p.add_argument("--json", action="store_true")
    p.add_argument("--trace", action="store_true")
    p.add_argument("--summary", action="store_true")
    p.add_argument("--until")
    p.add_argument("--max-passes", type=int, default=5)
    p.add_argument("--progress")
    p.add_argument("--max-stalls", type=int, default=5)
    p.add_argument("--prompt-file")
    p.add_argument("prompt", nargs="?")
    return p.parse_args(argv)

def read_prompt(args, err):
    if args.prompt is not None:
        text = args.prompt
    elif args.prompt_file:
        with open(args.prompt_file) as fh:
            text = fh.read()
    elif not sys.stdin.isatty():
        text = sys.stdin.read()
    else:
        text = ""
    text = text.strip()
    if not text:
        err("no prompt given")
        sys.exit(EXIT_USAGE)
    return text

def main(argv):
    args = parse_args(argv)
    def err(m): sys.stderr.write(f"{PROG}: {m}\n")
    prompt = read_prompt(args, err)
    # run_once / run_loop wired in later tasks; placeholder call:
    from_run = run_once(args, prompt, err)
    return from_run

def run_once(args, prompt, err):  # replaced/extended by later tasks
    raise NotImplementedError

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

Note: the `answer-only` assertion in this task's test will not pass until Task 9 wires `run_once`. Split it: keep only the usage-error assertion green here; move the `answer-only` assertion into Task 9's step. Update the test accordingly before running.

- [ ] **Step 4: Run to verify the usage-error assertion passes**

Run: `bash tests/test_freebuff_task.sh`
Expected: `ok - empty prompt is usage error 2`.

- [ ] **Step 5: Commit**

```bash
chmod +x scripts/freebuff-task
git add scripts/freebuff-task tests/test_freebuff_task.sh
git commit -m "Add freebuff-task skeleton: args, prompt input, exit codes"
```

---

### Task 4: Worktree management

**Files:**
- Modify: `scripts/freebuff-task`
- Test: `tests/test_freebuff_task.sh` (append)

**Interfaces:**
- Consumes: `args.cwd, args.no_worktree, args.keep_worktrees`.
- Produces: `repo_root(cwd) -> str` (git top level; `SystemExit(EXIT_USAGE)` if not a repo and not `--no-worktree`).
- Produces: `make_worktree(root, keep) -> (path, branch_or_None)` and `remove_old_worktrees(root, keep)`.
- Produces: `worktree_diff(path) -> (diff_text, stat_text)` using `git -C path add -N .` then `git -C path diff`.
- Produces: `run_dir(args) -> (cwd_for_run, worktree_path_or_None)`.

- [ ] **Step 1: Write the failing test**

```bash
# worktree is created under $TMPDIR/freebuff-task and a diff is captured
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="ok" FAKE_FREEBUFF_WRITE="new.txt:::hello" \
  "$FT" --cwd "$REPO" --diff --answer-only >"$WORK/o2" 2>/dev/null || true
grep -q "new.txt" "$WORK/o2" && ok "diff shows worktree change" || bad "diff missing: $(cat "$WORK/o2")"
# real checkout untouched
[ ! -e "$REPO/new.txt" ] && ok "real checkout untouched" || bad "real checkout was written"
```

- [ ] **Step 2: Run to verify it fails** — Run: `bash tests/test_freebuff_task.sh`; expected FAIL (no worktree logic / `run_once` raises).

- [ ] **Step 3: Implement** (add to `scripts/freebuff-task`)

```python
import subprocess, tempfile, time, shutil, glob

def _git(root, *a):
    return subprocess.run(["git", "-C", root, *a], capture_output=True, text=True)

def repo_root(cwd, no_worktree, err):
    r = _git(cwd, "rev-parse", "--show-toplevel")
    if r.returncode != 0:
        if no_worktree:
            return cwd
        err("--cwd is not inside a git repo (use --no-worktree to run in place)")
        sys.exit(EXIT_USAGE)
    return r.stdout.strip()

def _wt_base():
    return os.path.join(tempfile.gettempdir(), "freebuff-task")

def remove_old_worktrees(root, keep):
    base = _wt_base()
    dirs = sorted(glob.glob(os.path.join(base, "wt-*")), key=os.path.getmtime)
    for d in dirs[:max(0, len(dirs) - keep)]:
        _git(root, "worktree", "remove", "--force", d)
        shutil.rmtree(d, ignore_errors=True)

def make_worktree(root, keep):
    base = _wt_base(); os.makedirs(base, exist_ok=True)
    remove_old_worktrees(root, keep)
    path = os.path.join(base, "wt-" + time.strftime("%Y%m%d-%H%M%S") + f"-{os.getpid()}")
    r = _git(root, "worktree", "add", "--detach", path, "HEAD")
    if r.returncode != 0:
        raise RuntimeError("git worktree add failed: " + r.stderr)
    return path

def worktree_diff(path):
    _git(path, "add", "-N", ".")
    diff = _git(path, "diff").stdout
    stat = _git(path, "diff", "--stat").stdout
    return diff, stat

def run_dir(args, err):
    root = repo_root(args.cwd or os.getcwd(), args.no_worktree, err)
    if args.no_worktree:
        return (args.cwd or os.getcwd()), None
    return make_worktree(root, args.keep_worktrees), None if False else make_worktree.__self__ if False else (make_worktree(root, args.keep_worktrees))
```

Fix `run_dir` to return a 2-tuple cleanly:

```python
def run_dir(args, err):
    root = repo_root(args.cwd or os.getcwd(), args.no_worktree, err)
    if args.no_worktree:
        return (args.cwd or os.getcwd()), None
    wt = make_worktree(root, args.keep_worktrees)
    return wt, wt
```

`run_once` (temporary, until Task 6+) should call `run_dir`, run the fake via the driver stub added in Task 6, then print diff if asked. For this task, stub `run_once` to: make the run dir, spawn fake with `subprocess` writing into it, read the transcript with a helper added in Task 8, and honour `--diff`. To keep tasks independent, defer the answer read to Task 8 and here only assert the diff. Implement a minimal `run_once` that spawns the fake with `subprocess.run` (not pty yet), captures the diff, prints it:

```python
def run_once(args, prompt, err):
    cwd, wt = run_dir(args, err)
    # minimal spawn for this task; replaced by pty driver in Task 6
    env = dict(os.environ)
    subprocess.run(["freebuff", "--cwd", cwd], input=prompt + "\n",
                   text=True, capture_output=True, env=env)
    if args.diff and wt:
        diff, stat = worktree_diff(wt)
        sys.stdout.write(diff)
    return EXIT_OK
```

- [ ] **Step 4: Run to verify it passes** — Run: `bash tests/test_freebuff_task.sh`; expected `ok - diff shows worktree change` and `ok - real checkout untouched`.

- [ ] **Step 5: Commit**

```bash
git add scripts/freebuff-task tests/test_freebuff_task.sh
git commit -m "freebuff-task: isolate each run in a throwaway git worktree"
```

---

### Task 5: Machine-wide instance lock

**Files:**
- Modify: `scripts/freebuff-task`
- Test: `tests/test_freebuff_task.sh` (append)

**Interfaces:**
- Produces: context manager `instance_lock(slot_timeout, err)` using `fcntl.flock` on `$TMPDIR/freebuff-task.lock`; on timeout writes an error and `sys.exit(EXIT_RETRY)`.

- [ ] **Step 1: Write the failing test**

```bash
# a held lock makes a second run give up with exit 6 under a short slot timeout
python3 - "$WORK" <<'PY' &
import fcntl, os, sys, time, tempfile
lk = os.path.join(tempfile.gettempdir(), "freebuff-task.lock")
f = open(lk, "w"); fcntl.flock(f, fcntl.LOCK_EX); time.sleep(3)
PY
sleep 0.5
set +e; FAKE_FREEBUFF_SCENARIO=answer "$FT" --cwd "$REPO" --slot-timeout 1 "hi" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 6 ] && ok "lock contention exits 6" || bad "lock rc=$rc"
wait
```

- [ ] **Step 2: Run to verify it fails** — expected FAIL (no lock; second run proceeds, rc≠6).

- [ ] **Step 3: Implement**

```python
import fcntl
from contextlib import contextmanager

@contextmanager
def instance_lock(slot_timeout, err):
    path = os.path.join(tempfile.gettempdir(), "freebuff-task.lock")
    fh = open(path, "w")
    deadline = time.time() + slot_timeout
    while True:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            if time.time() >= deadline:
                err("timed out waiting for the Freebuff instance slot")
                sys.exit(EXIT_RETRY)
            time.sleep(0.5)
    try:
        yield
    finally:
        fcntl.flock(fh, fcntl.LOCK_UN); fh.close()
```

Wrap the body of `run_once` in `with instance_lock(args.slot_timeout, err):`.

- [ ] **Step 4: Run to verify it passes** — expected `ok - lock contention exits 6`.

- [ ] **Step 5: Commit**

```bash
git add scripts/freebuff-task tests/test_freebuff_task.sh
git commit -m "freebuff-task: single machine-wide instance lock"
```

---

### Task 6: PTY spawn and ready detection

Replaces the `subprocess.run` stub with a real pty driver.

**Files:**
- Modify: `scripts/freebuff-task`
- Test: `tests/test_freebuff_task.sh` (append)

**Interfaces:**
- Produces: class `PtyProcess` with `spawn(argv, env)`, `.write(bytes)`, `.read_nonblocking() -> bytes`, `.screen` (bounded 64 KiB buffer, decoded lazily), `.alive`, `.send_signal(sig)`, `.close()`. Uses `pty.fork`, `TIOCSWINSZ` to 80x24, `TERM=xterm-256color`.
- Produces: `snapshot_chats(config_root, cwd) -> set[str]` and `new_chat_dir(config_root, cwd, before, timeout) -> str`.
- Produces: `wait_ready(pty, chatdir_getter, quiet=0.75, timeout=...) -> str` returning the new chat dir once it exists and the screen has been quiet.

- [ ] **Step 1: Write the failing test**

```bash
# driver detects the fake's new chat dir (ready) and does not hang
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="ready-ok" \
  timeout 30 "$FT" --cwd "$REPO" --answer-only "hi" >"$WORK/o6" 2>/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "pty run completes" || bad "pty run rc=$rc: $(cat "$WORK/o6")"
```

(Note: `--answer-only` output is asserted in Task 9; here only the clean exit.)

- [ ] **Step 2: Run to verify it fails** — expected FAIL (run_once still uses subprocess stub / raises).

- [ ] **Step 3: Implement** the `PtyProcess`, `snapshot_chats`, `new_chat_dir`, `wait_ready`, and rewrite `run_once` to: take the lock, make the run dir, snapshot chats, spawn `freebuff --cwd <cwd>` under pty, `wait_ready`. Config root helper:

```python
import pty, select, struct, fcntl as _fcntl, termios, signal, errno

def config_root():
    return os.environ.get("FREEBUFF_CONFIG_DIR") or os.path.expanduser("~/.config/manicode")

def chats_dir(cwd):
    return os.path.join(config_root(), "projects", os.path.basename(os.path.abspath(cwd)), "chats")

def snapshot_chats(cwd):
    d = chats_dir(cwd)
    return set(os.listdir(d)) if os.path.isdir(d) else set()

def new_chat_dir(cwd, before, deadline):
    d = chats_dir(cwd)
    while time.time() < deadline:
        if os.path.isdir(d):
            new = sorted(set(os.listdir(d)) - before)
            if new:
                return os.path.join(d, new[-1])
        time.sleep(0.1)
    return None

class PtyProcess:
    def __init__(self):
        self.pid = None; self.fd = None; self.screen = b""; self._max = 64 * 1024
    def spawn(self, argv, env):
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe(argv[0], argv, env)
            os._exit(127)
        self.pid, self.fd = pid, fd
        winsz = struct.pack("HHHH", 24, 80, 0, 0)
        _fcntl.ioctl(fd, termios.TIOCSWINSZ, winsz)
        return self
    def read_nonblocking(self):
        try:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                data = os.read(self.fd, 4096)
                self.screen = (self.screen + data)[-self._max:]
                return data
        except OSError:
            return b""
        return b""
    def write(self, data):
        os.write(self.fd, data)
    @property
    def alive(self):
        try:
            pid, _ = os.waitpid(self.pid, os.WNOHANG); return pid == 0
        except OSError:
            return False
    def send_signal(self, sig):
        try: os.killpg(os.getpgid(self.pid), sig)
        except OSError: pass
    def close(self):
        try: os.close(self.fd)
        except OSError: pass

def wait_ready(proc, cwd, before, quiet, deadline):
    chatdir = None; last_change = time.time(); prev = b""
    while time.time() < deadline:
        proc.read_nonblocking()
        if chatdir is None:
            chatdir = new_chat_dir(cwd, before, min(deadline, time.time() + 0.11))
        if proc.screen != prev:
            prev = proc.screen; last_change = time.time()
        if chatdir is not None and time.time() - last_change >= quiet:
            return chatdir
    return chatdir
```

Rewrite `run_once` prologue:

```python
def run_once(args, prompt, err):
    with instance_lock(args.slot_timeout, err):
        cwd, wt = run_dir(args, err)
        before = snapshot_chats(cwd)
        env = dict(os.environ); env["TERM"] = "xterm-256color"
        proc = PtyProcess().spawn(["freebuff", "--cwd", cwd], env)
        deadline = time.time() + args.timeout
        chatdir = wait_ready(proc, cwd, before, 0.75, deadline)
        if not chatdir:
            proc.send_signal(signal.SIGTERM); proc.close()
            err("freebuff never became ready"); return EXIT_ERR
        # send + completion wired in Tasks 7-9
        rc = drive(proc, args, prompt, chatdir, wt, deadline, err)
        return rc

def drive(proc, args, prompt, chatdir, wt, deadline, err):
    # filled in Tasks 7-9; temporary: just wait for exit
    proc.send_signal(signal.SIGINT); time.sleep(0.3); proc.send_signal(signal.SIGINT)
    proc.close()
    return EXIT_OK
```

- [ ] **Step 4: Run to verify it passes** — expected `ok - pty run completes`.

- [ ] **Step 5: Commit**

```bash
git add scripts/freebuff-task tests/test_freebuff_task.sh
git commit -m "freebuff-task: pty spawn and ready detection"
```

---

### Task 7: Send the prompt with bracketed paste, confirm it landed

**Files:**
- Modify: `scripts/freebuff-task`
- Test: `tests/test_freebuff_task.sh` (append)

**Interfaces:**
- Produces: `send_prompt(proc, chatdir, text, deadline, err) -> None`; wraps `text` in `\x1b[200~` ... `\x1b[201~` then `\r`; polls `log.jsonl` for a "Sending message with sdk run config" line within 30 s; resends once; `sys.exit(EXIT_EMPTY)` if still absent.
- Produces: `log_lines(chatdir) -> list[dict]` (tolerant JSON-per-line reader).

- [ ] **Step 1: Write the failing test**

```bash
# multi-line prompt is delivered as one message (no early submit)
printf 'line one\nline two\n' > "$WORK/multi.txt"
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="multi-ok" \
  timeout 30 "$FT" --cwd "$REPO" --prompt-file "$WORK/multi.txt" --json "" >"$WORK/o7" 2>/dev/null || true
python3 -c "import json,sys; d=json.load(open('$WORK/o7')); sys.exit(0 if d.get('answer')=='multi-ok' else 1)" \
  && ok "multi-line prompt delivered" || bad "multi-line: $(cat "$WORK/o7")"
```

(`--json` answer field is completed in Task 9; if running strictly in order, assert only that the send-landed log line appears by checking the transcript instead. Keep whichever matches your execution order.)

- [ ] **Step 2: Run to verify it fails**

- [ ] **Step 3: Implement**

```python
SEND_MARKER = "Sending message with sdk run config"

def log_lines(chatdir):
    p = os.path.join(chatdir, "log.jsonl")
    out = []
    if not os.path.exists(p): return out
    with open(p, errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line: continue
            try: out.append(json.loads(line))
            except ValueError: pass
    return out

def _send_landed(chatdir):
    return any(SEND_MARKER in (r.get("msg") or "") for r in log_lines(chatdir))

def send_prompt(proc, chatdir, text, deadline, err):
    payload = b"\x1b[200~" + text.encode() + b"\x1b[201~\r"
    proc.write(payload)
    sent_deadline = min(deadline, time.time() + 30)
    resent = False
    while time.time() < sent_deadline:
        proc.read_nonblocking()
        if _send_landed(chatdir):
            return
        if not resent and time.time() - (sent_deadline - 30) > 15:
            proc.write(payload); resent = True
        time.sleep(0.3)
    err("prompt never registered with freebuff"); sys.exit(EXIT_EMPTY)
```

Call `send_prompt` at the top of `drive` before completion handling.

- [ ] **Step 4: Run to verify it passes**

- [ ] **Step 5: Commit**

```bash
git add scripts/freebuff-task tests/test_freebuff_task.sh
git commit -m "freebuff-task: bracketed-paste send with landed-confirmation"
```

---

### Task 8: Completion detection and answer extraction

**Files:**
- Modify: `scripts/freebuff-task`
- Test: `tests/test_freebuff_task.sh` (append)

**Interfaces:**
- Produces: `read_messages(chatdir) -> list[dict]` (reads `chat-messages.json`, tolerant of partial writes).
- Produces: `last_ai(chatdir) -> dict | None`.
- Produces: `is_complete(chatdir) -> bool` (last AI message `isComplete` true, no `[response interrupted]` in any text block, and a run-finish line present per the Task 1 finding; fall back to `chat-meta.json` mtime quiescence).
- Produces: `extract_answer(msg) -> str` (join `text` blocks with `textType=="text"`, skip reasoning).
- Produces: `pending_question(msg) -> str | None` (an `ask_user` block).
- Produces: `wait_complete(chatdir, deadline) -> str` returning `"done" | "ask" | "timeout"`.

- [ ] **Step 1: Write the failing test**

```bash
# ask_user scenario -> exit 3 with the question as the answer
set +e
FAKE_FREEBUFF_SCENARIO=ask_user timeout 30 "$FT" --cwd "$REPO" --answer-only "go" >"$WORK/o8" 2>/dev/null
rc=$?; set -e
[ "$rc" -eq 3 ] && grep -qi "database" "$WORK/o8" && ok "ask_user -> exit 3" || bad "ask_user rc=$rc out=$(cat "$WORK/o8")"
# interrupted scenario is not treated as complete (times out or errors, never a clean 0 answer)
set +e; FAKE_FREEBUFF_SCENARIO=interrupted timeout 12 "$FT" --cwd "$REPO" --answer-only "go" >"$WORK/o8b" 2>/dev/null; rc=$?; set -e
[ "$rc" -ne 0 ] && ok "interrupted is not a clean success" || bad "interrupted returned 0"
```

- [ ] **Step 2: Run to verify it fails**

- [ ] **Step 3: Implement**

```python
INTERRUPTED = "[response interrupted]"

def read_messages(chatdir):
    p = os.path.join(chatdir, "chat-messages.json")
    for _ in range(3):
        try:
            return json.load(open(p))
        except (ValueError, FileNotFoundError):
            time.sleep(0.1)
    return []

def last_ai(chatdir):
    ai = [m for m in read_messages(chatdir) if m.get("variant") == "ai"]
    return ai[-1] if ai else None

def _texts(msg):
    return [b for b in msg.get("blocks", []) if b.get("type") == "text"]

def extract_answer(msg):
    return "\n".join(b.get("content", "") for b in _texts(msg)
                     if b.get("textType") == "text").strip()

def pending_question(msg):
    for b in msg.get("blocks", []):
        if b.get("type") == "ask_user":
            qs = b.get("questions") or []
            return "\n".join(qs) if isinstance(qs, list) else str(qs)
    return None

def _run_finished(chatdir):
    return any("finished" in (r.get("msg") or "") for r in log_lines(chatdir))

def is_complete(chatdir):
    msg = last_ai(chatdir)
    if not msg or not msg.get("isComplete"):
        return False
    if any(INTERRUPTED in (b.get("content") or "") for b in _texts(msg)):
        return False
    return _run_finished(chatdir)

def wait_complete(chatdir, deadline):
    while time.time() < deadline:
        msg = last_ai(chatdir)
        if msg and pending_question(msg) and msg.get("isComplete"):
            return "ask"
        if is_complete(chatdir):
            return "done"
        time.sleep(0.5)
    return "timeout"
```

Extend `drive` to, after `send_prompt`: `state = wait_complete(chatdir, deadline)`; on `"ask"` set answer to the question and return `EXIT_ASK`; on `"timeout"` return `EXIT_TIMEOUT`; on `"done"` extract the answer. Store answer for Task 9's output.

- [ ] **Step 4: Run to verify it passes**

- [ ] **Step 5: Commit**

```bash
git add scripts/freebuff-task tests/test_freebuff_task.sh
git commit -m "freebuff-task: completion detection, answer and ask_user handling"
```

---

### Task 9: Output — plain, --answer-only, --diff, --json; exit sequence

**Files:**
- Modify: `scripts/freebuff-task`
- Test: `tests/test_freebuff_task.sh` (append the deferred assertions from Tasks 3, 6, 7)

**Interfaces:**
- Produces: `emit(args, result, wt)` where `result = {answer, session_id, tool_calls, elapsed, exit_code}`; `--json` prints the full object incl. `worktree, branch, diff_stat`; `--answer-only` prints only `answer`; default prints answer then, if `--diff`, the diff.
- Produces: `finish_pty(proc)` — Ctrl-C twice (500 ms apart), 3 s, SIGTERM group, 3 s, SIGKILL.

- [ ] **Step 1: Write the failing test** (move here the `answer-only`, pty-run, and `--json` answer assertions)

```bash
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="pong" \
  timeout 30 "$FT" --cwd "$REPO" --json "hi" >"$WORK/o9" 2>/dev/null || true
python3 -c "import json; d=json.load(open('$WORK/o9')); assert d['answer']=='pong'; assert d['exit_code']==0; assert 'worktree' in d" \
  && ok "--json shape" || bad "--json: $(cat "$WORK/o9")"
```

- [ ] **Step 2: Run to verify it fails**

- [ ] **Step 3: Implement** `emit` and `finish_pty`, and have `drive` build `result`, call `worktree_diff` when `--diff`/`--json`, call `finish_pty`, then `emit`. `session_id` = basename of `chatdir`. `elapsed` from a start timestamp taken in `run_once`.

```python
def finish_pty(proc):
    proc.write(b"\x03"); time.sleep(0.5); proc.write(b"\x03"); time.sleep(3)
    if proc.alive: proc.send_signal(signal.SIGTERM); time.sleep(3)
    if proc.alive: proc.send_signal(signal.SIGKILL)
    proc.close()

def emit(args, result, wt, diff, stat):
    if args.json:
        obj = dict(result); obj["worktree"] = wt or ""
        obj["branch"] = ""  # detached worktree; no branch
        obj["diff_stat"] = stat or ""
        sys.stdout.write(json.dumps(obj) + "\n"); return
    if args.answer_only:
        sys.stdout.write(result["answer"] + "\n"); return
    sys.stdout.write(result["answer"] + "\n")
    if args.diff and diff:
        sys.stdout.write("\n" + diff)
```

- [ ] **Step 4: Run to verify it passes** — the deferred assertions from Tasks 3/6/7 now pass too.

- [ ] **Step 5: Commit**

```bash
git add scripts/freebuff-task tests/test_freebuff_task.sh
git commit -m "freebuff-task: output modes and clean pty exit"
```

---

### Task 10: --apply

**Files:**
- Modify: `scripts/freebuff-task`
- Test: `tests/test_freebuff_task.sh` (append)

**Interfaces:**
- Produces: `apply_diff(root, diff, err) -> bool` — `git -C root apply` reading the diff on stdin; on failure print a message and return False (caller sets exit 1, still emits so `--diff` shows what failed).

- [ ] **Step 1: Write the failing test**

```bash
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="applied" FAKE_FREEBUFF_WRITE="applied.txt:::yes" \
  timeout 30 "$FT" --cwd "$REPO" --apply --answer-only "go" >/dev/null 2>&1 || true
[ -f "$REPO/applied.txt" ] && grep -q yes "$REPO/applied.txt" && ok "--apply writes to real tree" || bad "--apply did not apply"
```

- [ ] **Step 2: Run to verify it fails**

- [ ] **Step 3: Implement**

```python
def apply_diff(root, diff, err):
    if not diff.strip():
        return True
    r = subprocess.run(["git", "-C", root, "apply"], input=diff, text=True, capture_output=True)
    if r.returncode != 0:
        err("git apply failed; the diff does not apply cleanly:\n" + r.stderr)
        return False
    return True
```

In `drive`, when `args.apply` and exit is OK, compute the real repo root (from the original `--cwd`, not the worktree) and call `apply_diff`; if it returns False, set exit code 1.

- [ ] **Step 4: Run to verify it passes**

- [ ] **Step 5: Commit**

```bash
git add scripts/freebuff-task tests/test_freebuff_task.sh
git commit -m "freebuff-task: --apply the worktree diff to the real tree"
```

---

### Task 11: Failure classification

**Files:**
- Modify: `scripts/freebuff-task`
- Test: `tests/test_freebuff_task.sh` (append)

**Interfaces:**
- Produces: `classify(screen_text) -> int | None` returning an exit code for a known failure screen, checked transient-first: rate limit / queue / admission → 6; buy-credits / new-session → 6; not signed in → 8; else None.
- `drive` calls `classify(proc.screen.decode(errors="replace"))` when ready-detection or completion times out, before returning a generic code.

- [ ] **Step 1: Write the failing test**

```bash
set +e; FAKE_FREEBUFF_SCENARIO=notsignedin timeout 15 "$FT" --cwd "$REPO" "hi" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 8 ] && ok "not-signed-in -> exit 8" || bad "notsignedin rc=$rc"
set +e; FAKE_FREEBUFF_SCENARIO=ratelimited timeout 15 "$FT" --cwd "$REPO" "hi" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 6 ] && ok "rate-limited -> exit 6" || bad "ratelimited rc=$rc"
```

- [ ] **Step 2: Run to verify it fails**

- [ ] **Step 3: Implement**

```python
def classify(screen):
    s = screen.lower()
    if any(k in s for k in ("rate limited", "queues when busy", "cannot safely start or resume")):
        return EXIT_RETRY
    if any(k in s for k in ("buy more credits", "continue in a new session")):
        return EXIT_RETRY
    if "not signed in" in s:
        return EXIT_AUTH
    return None
```

In `run_once`, when `wait_ready` returns no chatdir, and in `drive` on a `"timeout"` from `wait_complete`, call `classify` first and return its code if any. Keep reading the pty so `proc.screen` is populated for these screens (the notsignedin/ratelimited fakes print to stdout and exit; ensure the driver drains the pty after spawn even before ready).

- [ ] **Step 4: Run to verify it passes**

- [ ] **Step 5: Commit**

```bash
git add scripts/freebuff-task tests/test_freebuff_task.sh
git commit -m "freebuff-task: classify known Freebuff failure screens"
```

---

### Task 12: --trace tool-call streaming and tool_calls in --json

**Files:**
- Modify: `scripts/freebuff-task`
- Test: `tests/test_freebuff_task.sh` (append)

**Interfaces:**
- Produces: `TailTracer(chatdir, start_ts, enabled)` with `.poll()` — reads new `log.jsonl` records past a stored offset, and for each with a tool call (shape from Task 1; the fake uses `{"type":"tool_call","toolName":..,"input":..}`) prints `freebuff-task: [<elapsed>s] <tool> <arg>` to stderr when `--trace`, and always counts them.
- Produces: `.tool_names` (list) and `.count` for `--json`.

- [ ] **Step 1: Write the failing test**

```bash
FAKE_FREEBUFF_SCENARIO=toolcalls FAKE_FREEBUFF_ANSWER="traced" \
  timeout 30 "$FT" --cwd "$REPO" --json "go" >"$WORK/o12" 2>"$WORK/e12" || true
python3 -c "import json; d=json.load(open('$WORK/o12')); assert d['tool_calls']>=2, d" && ok "tool_calls counted" || bad "tool_calls: $(cat "$WORK/o12")"
grep -q "read_files" "$WORK/e12" && echo "note: trace lines require --trace" || true
FAKE_FREEBUFF_SCENARIO=toolcalls timeout 30 "$FT" --cwd "$REPO" --trace "go" 2>"$WORK/e12b" >/dev/null || true
grep -q "read_files" "$WORK/e12b" && ok "--trace prints tool calls" || bad "no trace line"
```

- [ ] **Step 2: Run to verify it fails**

- [ ] **Step 3: Implement**

```python
class TailTracer:
    def __init__(self, chatdir, start_ts, trace):
        self.path = os.path.join(chatdir, "log.jsonl"); self.offset = 0
        self.start = start_ts; self.trace = trace; self.tool_names = []; self.count = 0
    def poll(self):
        if not os.path.exists(self.path): return
        with open(self.path, errors="replace") as fh:
            fh.seek(self.offset)
            for line in fh:
                if not line.endswith("\n"): break
                self.offset = fh.tell()
                line = line.strip()
                if not line: continue
                try: rec = json.loads(line)
                except ValueError: continue
                tool = rec.get("toolName")
                if not tool and rec.get("type") == "tool_call":
                    tool = rec.get("tool")
                if tool:
                    self.count += 1; self.tool_names.append(tool)
                    if self.trace:
                        arg = rec.get("input") or rec.get("args") or ""
                        el = f"{time.time() - self.start:.1f}"
                        sys.stderr.write(f"{PROG}: [{el}s] {tool} {arg}\n"); sys.stderr.flush()
```

In `drive`, build a `TailTracer` after `send_prompt`, call `.poll()` inside the `wait_complete` loop (add a poll call there or copy the loop into `drive`), and put `tracer.count` into `result["tool_calls"]`.

- [ ] **Step 4: Run to verify it passes**

- [ ] **Step 5: Commit**

```bash
git add scripts/freebuff-task tests/test_freebuff_task.sh
git commit -m "freebuff-task: stream tool calls in --trace and count them in --json"
```

---

### Task 13: Model selection via /model

**Files:**
- Modify: `scripts/freebuff-task`; `tests/fake-freebuff` (accept a `/model` line)
- Test: `tests/test_freebuff_task.sh` (append)

**Interfaces:**
- Produces: `select_model(proc, model, err)` — if `model` differs from `settings.json`'s `freebuffModel`, type `/model`, then the selection keys pinned in Task 1 (default: type the model name, Enter), then wait for quiet. Reads `settings.json` from `config_root()`.
- The fake gains: if it reads a line beginning `/model`, it records the requested model into `chat-meta.json` as `model` so the test can assert.

- [ ] **Step 1: Write the failing test**

```bash
echo '{"freebuffModel":"z-ai/glm-5.2"}' > "$FREEBUFF_CONFIG_DIR/settings.json"
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="m" \
  timeout 30 "$FT" --cwd "$REPO" --model glm-5.3-flash --answer-only "go" >/dev/null 2>&1 || true
found="$(find "$FREEBUFF_CONFIG_DIR/projects" -name chat-meta.json | head -1)"
grep -q "glm-5.3-flash" "$found" && ok "/model selection sent" || bad "model not selected: $(cat "$found")"
```

- [ ] **Step 2: Run to verify it fails**

- [ ] **Step 3: Implement** `select_model` in the driver (call it in `run_once` after `wait_ready`, before `send_prompt`), and extend the fake to capture a leading `/model` line into `chat-meta.json`. Use the exact keys from Task 1; the plan's default (type name + Enter) is the fallback.

```python
def current_model():
    p = os.path.join(config_root(), "settings.json")
    try: return json.load(open(p)).get("freebuffModel", "")
    except Exception: return ""

def select_model(proc, model, deadline):
    if not model or model in current_model():
        return
    proc.write(b"/model\r"); time.sleep(0.5)
    proc.write(model.encode() + b"\r")
    # settle
    end = min(deadline, time.time() + 5)
    while time.time() < end:
        proc.read_nonblocking(); time.sleep(0.2)
```

Fake change: in the readline handling, if the first stdin line starts with `/model`, read the next line as the model name and write `{"model": name, ...}` into `chat-meta.json`, then continue to the real prompt on the following line.

- [ ] **Step 4: Run to verify it passes**

- [ ] **Step 5: Commit**

```bash
git add scripts/freebuff-task tests/fake-freebuff tests/test_freebuff_task.sh
git commit -m "freebuff-task: select the model via /model when it differs"
```

---

### Task 14: --until / --progress loop with --continue resume

**Files:**
- Modify: `scripts/freebuff-task`
- Test: `tests/test_freebuff_task.sh` (append)

**Interfaces:**
- Produces: `run_loop(args, prompt, err) -> int` wrapping repeated `run_once`-style passes. After each pass runs `bash -c args.until` in the run cwd; exit 0 ends the loop (EXIT_OK); else resume the same conversation. `--progress` replaces pass counting with stall counting. Resume mode from Task 1: if `--continue <id>` works, spawn `freebuff --continue <session_id> --cwd <cwd>`; else start fresh with the previous answer + check output prepended.
- `--json` gains `passes`, `resume` ("continue"|"fresh"), cumulative `tool_calls`.
- `main` routes to `run_loop` when `args.until` else `run_once`.

- [ ] **Step 1: Write the failing test**

```bash
# --until that succeeds on the first check ends immediately with 0
FAKE_FREEBUFF_SCENARIO=answer FAKE_FREEBUFF_ANSWER="loop" \
  timeout 40 "$FT" --cwd "$REPO" --until "true" --json "go" >"$WORK/o14" 2>/dev/null || true
python3 -c "import json; d=json.load(open('$WORK/o14')); assert d['exit_code']==0 and d['passes']>=1, d" && ok "--until success" || bad "--until: $(cat "$WORK/o14")"
# --until that never succeeds hits max-passes -> exit 5
set +e; FAKE_FREEBUFF_SCENARIO=answer timeout 60 "$FT" --cwd "$REPO" --until "false" --max-passes 2 "go" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 5 ] && ok "--until exhausted -> 5" || bad "exhausted rc=$rc"
```

- [ ] **Step 2: Run to verify it fails**

- [ ] **Step 3: Implement** `run_loop`. Reuse the single-pass body by refactoring the lock+spawn+drive of `run_once` into `_one_pass(args, prompt, resume_id, err) -> (rc, result, wt, cwd)`. Keep the worktree stable across passes (make it once, reuse its cwd; pass `resume_id=session_id`). After each pass run the check:

```python
def _check(cmd, cwd):
    return subprocess.run(["bash", "-c", cmd], cwd=cwd, capture_output=True, text=True)

def run_loop(args, prompt, err):
    # one worktree for the whole loop
    ...
    passes, stalls, last_prog = 0, 0, None
    resume_id = None
    while True:
        rc, result, wt, cwd = _one_pass(args, prompt, resume_id, err, reuse_wt=wt)
        passes += 1
        chk = _check(args.until, cwd)
        if chk.returncode == 0:
            result["passes"] = passes; emit(...); return EXIT_OK
        if args.progress:
            p = _check(args.progress, cwd)
            try: val = int(p.stdout.strip())
            except ValueError: val = last_prog
            stalls = 0 if (last_prog is not None and val is not None and val > last_prog) else stalls + 1
            last_prog = val if val is not None else last_prog
            if stalls >= args.max_stalls:
                return EXIT_UNTIL
        else:
            if passes >= args.max_passes:
                return EXIT_UNTIL
        resume_id = result["session_id"]  # continue mode; if Task 1 said unsupported, prepend chk.stdout to prompt instead
        prompt = f"The check failed:\n{chk.stdout}\n{chk.stderr}\nContinue."
```

Wire the resume-mode branch per the Task 1 finding: spawn with `--continue resume_id` if supported, else fresh session with the composed prompt. Record `resume` in `result`.

- [ ] **Step 4: Run to verify it passes**

- [ ] **Step 5: Commit**

```bash
git add scripts/freebuff-task tests/test_freebuff_task.sh
git commit -m "freebuff-task: --until/--progress loop with conversation resume"
```

---

### Task 15: install.sh, SKILL.md, README usage

**Files:**
- Modify: `install.sh`, `SKILL.md`, `README.md`
- Test: manual + `bash -n install.sh`

- [ ] **Step 1: Extend `install.sh`** to symlink `scripts/freebuff-task` → `~/.local/bin/freebuff-task`, run `freebuff --version` (warn if absent), and check `hasSubmittedFirstPrompt` in `~/.config/manicode/settings.json`; if missing, print: "Run `freebuff` once interactively to log in and clear onboarding, then re-run install."

```bash
ln -sf "$PWD/scripts/freebuff-task" "$HOME/.local/bin/freebuff-task"
if command -v freebuff >/dev/null; then freebuff --version || true
else echo "warning: freebuff not found; install with: npm i -g freebuff"; fi
cfg="$HOME/.config/manicode/settings.json"
if [ -f "$cfg" ] && grep -q '"hasSubmittedFirstPrompt": *true' "$cfg"; then :
else echo "note: run \`freebuff\` once interactively to log in and clear onboarding"; fi
```

- [ ] **Step 2: Add the Freebuff section to `SKILL.md`** — when to prefer it (unmetered GLM 5.3 Flash; edits are safe because each run is isolated in a worktree), the answer+diff+`--apply` workflow, exit codes, the one-instance limit, and that it drives the real CLI.

- [ ] **Step 3: Add usage to `README.md`** — the flag table, exit codes, the worktree/`--apply` model, `--until` loops, and a pointer to the verified-facts table from Task 1.

- [ ] **Step 4: Verify** — `bash -n install.sh`; run `install.sh` in a scratch `HOME` and confirm the symlink; `freebuff-task -h` prints.

- [ ] **Step 5: Commit**

```bash
git add install.sh SKILL.md README.md
git commit -m "freebuff-task: install, skill entry, and docs"
```

---

### Task 16: Opt-in live test

**Files:**
- Create: `tests/test_freebuff_task_live.sh`

- [ ] **Step 1: Write the guarded test**

```bash
#!/usr/bin/env bash
set -euo pipefail
[ "${FREEBUFF_TASK_LIVE:-}" = "1" ] || { echo "skip - set FREEBUFF_TASK_LIVE=1 to run"; exit 0; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(mktemp -d)"; ( cd "$REPO" && git init -q && echo "the secret word is albatross" > note.txt && git add . && git commit -q -m init )
out="$("$ROOT/scripts/freebuff-task" --cwd "$REPO" --answer-only "What is the secret word in note.txt? Answer with one word.")"
echo "$out" | grep -qi albatross && echo "ok - live run read the file" || { echo "NOT ok - live: $out"; exit 1; }
```

- [ ] **Step 2: Run** `bash tests/test_freebuff_task_live.sh` (skips by default); optionally once with `FREEBUFF_TASK_LIVE=1`.

- [ ] **Step 3: Commit**

```bash
chmod +x tests/test_freebuff_task_live.sh
git add tests/test_freebuff_task_live.sh
git commit -m "freebuff-task: opt-in live smoke test"
```

---

### Task 17: Full suite green + self-review

- [ ] **Step 1:** `bash tests/test_freebuff_task.sh` — all `ok -`, no `NOT ok -`.
- [ ] **Step 2:** Re-run against a repo whose basename collides with another (two temp dirs both named `repo`) to confirm session identity uses the new chat dir, not the project.
- [ ] **Step 3:** Confirm `--no-worktree` writes to the real tree and `--diff` still reports.
- [ ] **Step 4:** Commit any fixes; open the PR against `main` from `feat-freebuff-task`.

---

## Self-Review

**Spec coverage:** every spec section maps to a task — SDK-ruled-out (Task 1 records real-CLI facts), CLI surface (Tasks 3, 9), the eight-step run (Tasks 5–9), worktree (Task 4), lock (Task 5), `--trace` streaming (Task 12), `--until`/`--continue` (Task 14), failure classes (Task 11), `/model` (Task 13), install/skill/docs (Task 15), tests incl. fake (Task 2) and live (Task 16), verification pass (Task 1). `--apply` (Task 10) and the collision check (Task 17) are covered.

**Placeholder scan:** the only forward references are the deliberate "wired in a later task" stubs for `run_once`/`drive`, each with the real code arriving in the named task; no TBDs left in shipped code.

**Type consistency:** `run_dir -> (cwd, wt)`, `wait_ready -> chatdir`, `wait_complete -> "done"|"ask"|"timeout"`, `extract_answer(msg)`, `TailTracer.count/.tool_names`, `result` keys `{answer, session_id, tool_calls, elapsed, exit_code, passes, resume}` are used consistently across tasks.

**Known execution note:** Task 3's test defines `answer-only` and Task 7/9 define `--json` assertions that only pass once `run_once`/`drive` are complete; the plan says to keep the usage-error assertion in Task 3 and move output assertions to Task 9. An executor going strictly task-by-task should honour those move notes so each task's suite is green when it lands.
