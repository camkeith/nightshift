#!/usr/bin/env bash
# pm-top.sh — interactive view of running PMs. Drill into one, see its workers, tail output.
#
#   ^/v      move            enter/->   open a PM
#   tab      switch pane     <-/esc     back
#   r        refresh         q          quit
#
# Panes: LEDGER (the PM's own account), WORKERS (subagents it dispatched, newest first),
# OUTPUT (live tmux pane if running, else the last wake's recorded result).
#
# Read-only by construction. It never writes a ledger, registry, or worktree: a PM's
# ledger is its memory, and an observer that mutates it becomes an injection surface.
#
# Needs a real terminal. Inside a sandboxed agent session the tmux socket is denied, so
# the OUTPUT pane falls back to the recorded wake result rather than the live pane.

set -euo pipefail

REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ -t 1 ] || {
  echo "pm-top needs an interactive terminal." >&2
  echo "For a non-interactive snapshot use: bash $HERE/pm-status.sh" >&2
  exit 1
}

exec python3 "$HERE/pm_top.py" "$REPO"
