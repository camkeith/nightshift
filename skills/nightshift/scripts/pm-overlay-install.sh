#!/usr/bin/env bash
# pm-overlay-install.sh — one keystroke floats the nightshift view over Claude Code.
#
#   bash pm-overlay-install.sh                install (default key: F9)
#   bash pm-overlay-install.sh --key F12      pick a different no-prefix key
#   bash pm-overlay-install.sh --print        show what it would write, change nothing
#   bash pm-overlay-install.sh --uninstall    remove the bindings again
#
# Re-running replaces the block it wrote last time, so changing the key does not leave the
# old one bound.
#
# WHY TMUX AND NOT CLAUDE CODE ITSELF
#
# Claude Code's footer IS keyboard-navigable, and pm-watch.sh uses that: run it as a
# background task and it becomes a footer entry you can arrow to and open. What the footer
# cannot do is host THIS view. It shows a task's streamed output; it does not give a
# third-party program a terminal, so a curses UI has nowhere to draw and no keystrokes.
#
# Nothing else in the CLI closes that gap, which is worth writing down so nobody spends an
# afternoon looking:
#
#   * `statusLine` runs a command and renders its stdout. It is a string producer with
#     no focus, no input, and no click target.
#   * There is no third-party panel API. /workflows is built into the binary. The
#     settings schema offers statusLine, subagentStatusLine, footerLinksRegexes and
#     prUrlTemplate; none of them register a view.
#   * Keybindings map to internal actions only (app:, chat:, footer:, ...). None shells out.
#   * footerLinksRegexes badges open a URL, not a local program.
#
# tmux, however, can float a program over whatever pane is running, which is exactly the
# behavior wanted: a key opens the overlay, Esc or q closes it, Claude Code is untouched
# underneath and never even knows it happened.
#
# TWO BINDINGS ARE INSTALLED, DELIBERATELY
#
#   <key>          no prefix. One keystroke from inside Claude Code. tmux swallows it
#                  globally, which is why the default is F9: Claude Code binds Ctrl and
#                  Alt combinations heavily and F9 is not among them.
#   prefix + C-n   the polite fallback, for when something else wants that F-key.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONF="$HOME/.tmux.conf"
KEY="${PM_OVERLAY_KEY:-F9}"
BEGIN="# --- nightshift overlay (added by pm-overlay-install.sh) ---"
END="# --- end nightshift overlay ---"
MODE="install"

while [ $# -gt 0 ]; do
  case "$1" in
    --key) KEY="${2:?--key needs a value}"; shift 2 ;;
    --print) MODE="print"; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

snippet() {
  cat <<EOF
$BEGIN
# ${KEY} floats pm-top over the current pane. Esc or q closes it.
# -E closes the popup when the program exits, so pm-top's own q just works, and so does
# 'a' (switch to a PM's session) which exits on purpose to let the popup get out of the way.
bind-key -n ${KEY} display-popup -E -w 92% -h 88% \\
  "cd '#{pane_current_path}' && bash '${HERE}/pm-top.sh'"
bind-key C-n display-popup -E -w 92% -h 88% \\
  "cd '#{pane_current_path}' && bash '${HERE}/pm-top.sh'"
$END
EOF
}

strip_block() {
  [ -f "$CONF" ] || return 0
  # awk rather than sed -i: BSD and GNU sed disagree on -i, and this has to work on macOS
  # without silently leaving a .bak file next to the user's config.
  awk -v b="$BEGIN" -v e="$END" '
    $0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }
  ' "$CONF" > "$CONF.ns-tmp" && mv "$CONF.ns-tmp" "$CONF"
}

if [ "$MODE" = "print" ]; then snippet; exit 0; fi

command -v tmux >/dev/null || { echo "tmux is not installed: brew install tmux" >&2; exit 1; }

# display-popup landed in tmux 3.2. Without this check the binding installs fine and then
# does nothing at all when pressed, which is a miserable thing to debug.
V=$(tmux -V | sed 's/[^0-9.]//g')
if [ "$(printf '%s\n3.2\n' "$V" | sort -V | head -1)" != "3.2" ]; then
  echo "tmux $V is too old for display-popup; 3.2+ required (brew upgrade tmux)" >&2
  exit 1
fi

strip_block
if [ "$MODE" = "uninstall" ]; then
  echo "removed the nightshift bindings from $CONF"
  echo "reload with: tmux source-file ~/.tmux.conf"
  exit 0
fi

printf '\n%s\n' "$(snippet)" >> "$CONF"
echo "bound ${KEY} (and prefix + C-n) in $CONF"

cat <<EOF

  Reload tmux config:   tmux source-file ~/.tmux.conf
  Then press:           ${KEY}

  Claude Code has to be running INSIDE tmux for this to work, because tmux is what draws
  the overlay. If it is not, start it that way once:

      tmux new -s work
      claude

  ${KEY}    open the nightshift view over Claude Code
  esc / q  close it, back to exactly where you were
  a        drop into the selected PM's own session; prefix + L returns here

EOF
