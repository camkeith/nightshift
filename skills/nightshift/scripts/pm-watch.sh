#!/usr/bin/env bash
# pm-watch.sh — emit one line per PM state change, for use as a Claude Code background task.
#
#   bash pm-watch.sh              watch until stopped
#   bash pm-watch.sh --once       print the current state and exit
#   PM_WATCH_INTERVAL=15          seconds between polls (default 20)
#
# WHY THIS EXISTS: arrow navigation inside the Claude Code CLI.
#
# The `Footer` keybinding context is documented as "Footer indicator navigation (tasks,
# teams, diff, artifacts)" with:
#
#     footer:down          Down     navigate INTO the footer
#     footer:next/previous Right/Left
#     footer:openSelected  Enter    open the selected item
#     footer:clearSelection Escape
#
# Background tasks are one of the four things that populate it. So a long-running task
# started from your session becomes a footer indicator you can arrow down to, select, and
# open with Enter, which shows its streamed output. Escape clears the selection.
#
# That is the only supported route from a keystroke in Claude Code to third-party state.
# There is no panel API: `statusLine` is a string producer with no focus or input, all 68
# keybinding actions are internal, and `footerLinksRegexes` badges open a URL.
#
# HOW TO USE IT
#
# Ask Claude to run this in the background, e.g. "run pm-watch.sh in the background".
# It then appears in the footer for as long as it runs.
#
# Output is deliberately sparse: one line only when something actually changes. A watcher
# that reprints every poll turns the footer into noise and trains you to ignore it, which
# is the same failure the notification policy avoids.

set -uo pipefail

REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
REG="$REPO/.claude/worktrees/registry"
INTERVAL="${PM_WATCH_INTERVAL:-20}"
ONCE="${1:-}"

snapshot() {
  NS_REG="$REG" python3 -c '
import glob, json, os, re
reg = os.environ["NS_REG"]
rows = []
if os.path.isdir(reg):
    for p in sorted(glob.glob(os.path.join(reg, "*.json"))):
        try:
            d = json.load(open(p))
        except Exception:
            continue
        wt = d.get("worktree", "")
        st = (d.get("status") or "?").upper()
        if st in ("DONE", "STOPPED"):
            continue
        led = ""
        try:
            with open(os.path.join(wt, "LEDGER.md")) as f:
                for _ in range(60):
                    line = f.readline()
                    if not line:
                        break
                    m = re.match(r"^STATUS:\s*(\S+)", line)
                    if m:
                        led = m.group(1)
                        break
        except Exception:
            pass
        blk = 0
        try:
            txt = open(os.path.join(wt, "LEDGER.md")).read()
            m = re.search(r"^## BLOCKERS\s*$(.*?)(?=^## |\Z)", txt, re.M | re.S)
            blk = len(re.findall(r"^- \[ \]", m.group(1), re.M)) if m else 0
        except Exception:
            pass
        rows.append((d.get("slug", "?"), led or st, d.get("wakes", 0),
                     round(float(d.get("cost_usd") or 0), 2), blk))
if not rows:
    print("NONE")
else:
    print(" | ".join(f"{s}:{k}:w{w}:${c}:b{b}" for s, k, w, c, b in rows))
' 2>/dev/null
}

render() {
  # human-facing line; the snapshot above is the change-detection key.
  # Fields are trimmed because the snapshot joins rows with " | ", so a split field can
  # carry the separator's padding and " b0" would not compare equal to "b0".
  echo "$1" | tr '|' '\n' | while IFS=: read -r slug state wakes cost blockers; do
    slug=$(echo "$slug" | xargs); blockers=$(echo "${blockers:-b0}" | xargs)
    [ -n "$slug" ] || continue
    printf '%s %s %s %s' "$slug" "$state" "$wakes" "$cost"
    [ "${blockers#b}" != "0" ] && printf ' BLOCKED:%s' "${blockers#b}"
    printf '\n'
  done
}

if [ "$ONCE" = "--once" ]; then
  s=$(snapshot)
  [ "$s" = "NONE" ] && echo "no active PMs" || render "$s"
  exit 0
fi

# Single-instance guard. Kickoff starts a watcher every time it runs, so without this a
# second feature launched on Tuesday leaves two watchers in the footer reporting the same
# three PMs.
#
# Liveness is a HEARTBEAT, not `kill -0`. Claude Code's sandbox denies both `ps` and
# `kill`, so a signal probe does not return false for a dead process, it errors for every
# process, and the guard would wave through every duplicate. The running watcher rewrites
# this file each poll instead, and a lock older than a few intervals is treated as
# abandoned, which also covers a task killed from /tasks that never got to clean up.
LOCK="$REPO/.claude/worktrees/.watch.pid"
STALE=$(( INTERVAL * 3 )); [ "$STALE" -lt 90 ] && STALE=90
mkdir -p "$(dirname "$LOCK")"
if [ -f "$LOCK" ] && NS_LOCK="$LOCK" NS_STALE="$STALE" python3 -c '
import os, sys, time
sys.exit(0 if time.time() - os.stat(os.environ["NS_LOCK"]).st_mtime
         < float(os.environ["NS_STALE"]) else 1)' 2>/dev/null; then
  echo "a watcher is already running (pid $(cat "$LOCK" 2>/dev/null)); nothing to do"
  exit 0
fi
echo $$ > "$LOCK"
# Only clear a lock we still own. Without the check, a duplicate that correctly declined
# to start would delete the live watcher's lock on its way out.
trap '[ "$(cat "$LOCK" 2>/dev/null)" = "$$" ] && rm -f "$LOCK"' EXIT INT TERM

echo "watching nightshift PMs in $(basename "$REPO") · one line per change"
prev=""
while true; do
  echo $$ > "$LOCK"        # heartbeat: this file's mtime is what "still alive" means
  cur=$(snapshot)
  if [ "$cur" != "$prev" ]; then
    if [ "$cur" = "NONE" ]; then
      [ -n "$prev" ] && echo "$(date +%H:%M:%S) all PMs finished or stopped"
    else
      # awk, not `paste -sd' · '`: paste treats the delimiter as a cycling CHARACTER list,
      # so three rows come out joined by " ", "·", " " in rotation rather than by " · ".
      echo "$(date +%H:%M:%S) $(render "$cur" | awk '{s = s (NR>1 ? "  ·  " : "") $0} END {print s}')"
    fi
    prev="$cur"
  fi
  sleep "$INTERVAL"
done
