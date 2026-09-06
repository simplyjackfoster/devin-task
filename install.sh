#!/usr/bin/env bash
# Link this checkout into Claude Code (~/.claude/skills/devin) and put
# devin-task on PATH (~/.local/bin). Re-runnable.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

command -v devin >/dev/null || {
  echo "devin CLI not found on PATH. Install it first: https://docs.devin.ai/cli" >&2; exit 1; }

mkdir -p ~/.claude/skills ~/.local/bin
if [ -e ~/.claude/skills/devin ] && [ ! -L ~/.claude/skills/devin ]; then
  echo "~/.claude/skills/devin exists and is not a symlink; move it aside first." >&2; exit 1
fi
ln -sfn "$HERE" ~/.claude/skills/devin
ln -sfn "$HERE/scripts/devin-task" ~/.local/bin/devin-task
chmod +x "$HERE/scripts/devin-task"

echo "linked  ~/.claude/skills/devin -> $HERE"
echo "linked  ~/.local/bin/devin-task -> $HERE/scripts/devin-task"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "note: add ~/.local/bin to PATH" ;; esac
echo "free models on this account:"; devin models list 2>/dev/null | grep -F 'Free' || echo "  (none listed; check 'devin models list')"
echo "smoke test:"; ~/.local/bin/devin-task --timeout 60 "Reply with exactly the word PONG."
