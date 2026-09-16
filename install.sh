#!/usr/bin/env bash
# Link this checkout into Claude Code (~/.claude/skills/devin) and put
# devin-task and freebuff-task on PATH (~/.local/bin). Re-runnable.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

command -v devin >/dev/null || {
  echo "devin CLI not found on PATH. Install it first: https://docs.devin.ai/cli" >&2; exit 1; }

echo "preflight:"
if ! devin --version; then
  echo "devin --version failed. Reinstall the Devin CLI: https://docs.devin.ai/cli" >&2
  exit 1
fi
if ! devin doctor; then
  echo "devin doctor reported a failure (see above). Run 'devin auth login', then re-run ./install.sh." >&2
  exit 1
fi

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

echo
echo "freebuff-task:"
ln -sfn "$HERE/scripts/freebuff-task" ~/.local/bin/freebuff-task
chmod +x "$HERE/scripts/freebuff-task"
echo "linked  ~/.local/bin/freebuff-task -> $HERE/scripts/freebuff-task"
if command -v freebuff >/dev/null; then
  freebuff --version || true
else
  echo "warning: freebuff not found on PATH; install with: npm i -g freebuff"
fi
fb_cfg="$HOME/.config/manicode/settings.json"
if [ -f "$fb_cfg" ] && grep -q '"hasSubmittedFirstPrompt": *true' "$fb_cfg"; then
  :
else
  echo "note: run \`freebuff\` once interactively to log in and clear onboarding, then re-run install."
fi
