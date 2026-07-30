#!/usr/bin/env bash
# pm-overlay-install.sh — bind a key that overlays pm-top on top of Claude Code.
#
#   bash pm-overlay-install.sh          add the binding to ~/.tmux.conf
#   bash pm-overlay-install.sh --print  show what it would add, change nothing
#
# WHY TMUX AND NOT CLAUDE CODE ITSELF
#
# Claude Code has no extension point for this, and it is worth knowing why so nobody
# spends an afternoon looking:
#
#   * `statusLine` runs a command and renders its stdout. It is a string producer with
#     no focus, no input, and no click target. There is nothing to arrow into.
#   * There is no third-party panel API. /workflows is built into the binary. The
#     settings schema offers statusLine, subagentStatusLine, footerLinksRegexes and
#     prUrlTemplate; none of them register a view.
#   * Keybindings map to internal actions only (app:, chat:, task:, ...). None shells out.
#   * footerLinksRegexes is the one interactive footer feature and it opens a URL.
#
# tmux, however, can float a program over whatever pane is running, which is exactly the
# behavior wanted: a key opens the overlay, Esc or q closes it, Claude Code is untouched
# underneath and never even knows it happened.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONF="$HOME/.tmux.conf"
KEY="${PM_OVERLAY_KEY:-C-n}"          # prefix + Ctrl-n

read -r -d '' SNIPPET <<EOF || true

# --- nightshift overlay (added by pm-overlay-install.sh) ---
# prefix + ${KEY}  floats pm-top over the current pane. Esc or q closes it.
# -E closes the popup when the program exits, so pm-top's own q just works.
bind-key ${KEY} display-popup -E -w 90% -h 85% \\
  "cd '#{pane_current_path}' && bash '${HERE}/pm-top.sh'"
# --- end nightshift overlay ---
EOF

if [ "${1:-}" = "--print" ]; then
  printf '%s\n' "$SNIPPET"
  exit 0
fi

command -v tmux >/dev/null || { echo "tmux is not installed: brew install tmux" >&2; exit 1; }

if [ -f "$CONF" ] && grep -q "nightshift overlay" "$CONF"; then
  echo "already installed in $CONF"
else
  printf '%s\n' "$SNIPPET" >> "$CONF"
  echo "added the binding to $CONF"
fi

cat <<EOF

  Reload tmux config:   tmux source-file ~/.tmux.conf
  Then, inside tmux:    prefix + ${KEY}

  If you are not already running Claude Code inside tmux, start it that way once:

      tmux new -s work
      claude

  After that, prefix + ${KEY} floats the nightshift view over your session and Esc or q
  drops you straight back into Claude Code, exactly where you were.

EOF
