#!/usr/bin/env bash
# pm-launch.sh — run a PM for hours or days under an OS-level supervisor.
#
# Usage:
#   pm-launch.sh <slug>              start (or reattach to) a PM in tmux
#   pm-launch.sh <slug> --once       run exactly one wake in the foreground (test/debug)
#   pm-launch.sh <slug> --stop       stop the PM's tmux session
#
# WHY A WRAPPER AND NOT /loop:
#   /loop registers its wakeups in memory. A closed laptop lid, a `claude`
#   autoupdate, or a crash ends the run silently with no recovery. Claude Code can
#   supply pacing; it cannot supply durability. That has to come from the OS.
#
# WHY EACH WAKE IS A FRESH `claude -p`:
#   It makes the "resume from files" requirement true by construction instead of by
#   discipline. A fresh process cannot accidentally rely on session memory, so if
#   LEDGER.md is not sufficient to continue, that breaks immediately and visibly on
#   wake 2 rather than silently on day 2 after a compaction.

set -euo pipefail

# Resolve the repo from the current git worktree rather than pinning a path, so this
# works in any checkout. Run these scripts from inside the repo you want a PM to work on.
REPO="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$REPO" ] || { echo "error: not inside a git repository. cd into your repo first." >&2; exit 1; }
WT_ROOT="$REPO/.claude/worktrees"          # see pm-provision.sh for why it lives here
REGISTRY="$WT_ROOT/registry"
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

INTERVAL="${PM_INTERVAL:-300}"      # seconds between wakes
MAX_FAILS="${PM_MAX_FAILS:-5}"      # consecutive failures before giving up

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

[ $# -ge 1 ] || die "usage: pm-launch.sh <slug> [--once|--stop]"
SLUG="$1"; MODE="${2:-}"

CLAIM="$REGISTRY/$SLUG.json"
[ -f "$CLAIM" ] || die "no registry claim for '$SLUG'. run pm-provision.sh first."

WORKTREE=$(python3 -c "import json;print(json.load(open('$CLAIM'))['worktree'])")
SESSION="pm-$SLUG"
[ -d "$WORKTREE" ] || die "worktree missing: $WORKTREE"
[ -f "$WORKTREE/LEDGER.md" ] || die "no LEDGER.md in $WORKTREE. re-run pm-provision.sh."

if [ "$MODE" = "--stop" ]; then
  tmux kill-session -t "$SESSION" 2>/dev/null && say "stopped $SESSION" || say "$SESSION was not running"
  python3 - "$CLAIM" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["status"] = "STOPPED"
json.dump(d, open(p, "w"), indent=2)
PY
  exit 0
fi

# The wake prompt. Deliberately near-stateless: it tells the PM where it lives and
# what to read, and nothing about what it was doing. The ledger supplies that.
read -r -d '' WAKE_PROMPT <<PROMPT || true
Use the nightshift skill. You are PM "$SLUG", working in $WORKTREE.

This is a fresh process with no memory of previous wakes. Everything you know is on
disk. Read $WORKTREE/LEDGER.md first, then the OpenSpec tasks.md it points at, then
continue the loop from wherever the ledger says you are.

Do one useful unit of work this wake, verify it yourself, write the result back to the
ledger, and exit. Do not try to finish the whole feature in one wake.

If every remaining task is BLOCKED, set STATUS: READY-FOR-HUMAN at the top of the
ledger and exit without doing more work.
PROMPT

# Standing Workflow orchestration for the PM. Opt in with PM_WORKFLOWS=1.
#
# The `ultracode` KEYWORD cannot be self-granted: it is human-typed and deliberately
# hardened against firing from non-human input. But the same capability is a settings
# key, documented as "xhigh effort plus standing dynamic-workflow orchestration,
# session-scoped, typically provided via --settings". The supervisor launches the PM
# and the supervisor is the human's, so it can grant this at launch. No self-grant,
# no keyword, no loophole.
#
# OFF BY DEFAULT, and the reason is cost, not capability. A PM wakes at least 24 times
# a day, and a workflow fans out to many agents per call. Standing orchestration across
# several PMs for several days is a large multiplier on something nobody has priced.
# Turn it on per feature, when the work genuinely fans out (a broad audit, a migration
# across many files, a multi-lens review), not as a default posture.
#
# workflowSizeGuideline is pinned to "small" (<5 agents) because the PM already has
# parallel background `Agent` dispatch for ordinary fan-out. Workflows are for when it
# needs deterministic control flow, not for raw width.
#
# UNTESTED as of this writing. The flag and the settings key are both documented and
# `claude --help` confirms --settings, but no PM has yet run a wake with it enabled.
WORKFLOW_SETTINGS='{"ultracode":true,"workflowSizeGuideline":"small"}'

run_one_wake() {
  cd "$WORKTREE"
  # OPENCLAW_SESSION=true puts gstack skills in auto-choose mode instead of stopping
  # to ask. Verified by running gstack-session-kind directly.
  # Do NOT set CI or GITHUB_ACTIONS: those resolve to `headless`, which makes gstack
  # BLOCK on an AskUserQuestion failure rather than auto-choosing. That is worse than
  # doing nothing.
  if [ "${PM_WORKFLOWS:-0}" = "1" ]; then
    OPENCLAW_SESSION=true PM_SLUG="$SLUG" \
      claude -p "$WAKE_PROMPT" --settings "$WORKFLOW_SETTINGS"
  else
    OPENCLAW_SESSION=true PM_SLUG="$SLUG" \
      claude -p "$WAKE_PROMPT"
  fi
}

# Stamp the heartbeat AND the ledger's LAST WAKE line.
#
# Both are the supervisor's job, never the PM's, for two measured reasons:
#
#  1. The registry lives outside the PM's worktree, and a sandboxed PM gets
#     "EPERM: operation not permitted, open 'smoke.json'" trying to write it. If the PM
#     owned the heartbeat, every healthy PM would look dead after two hours and the
#     watchdog would restart live ones, putting two claude processes on one branch. That
#     is the exact corruption the registry exists to prevent.
#  2. A PM hand-editing header fields corrupts them. Observed on the first real wake:
#     "LAST WAKE: 2026-07-29T16:/ wake 2", a mangled timestamp that also leaked into the
#     OPENSPEC: line. The supervisor runs unsandboxed with a real clock, so it should own
#     every machine-readable field. The PM owns prose sections only.
beat() {
  python3 - "$CLAIM" "$1" "$WORKTREE/LEDGER.md" <<'PY'
import json, re, sys, datetime
claim, status, ledger = sys.argv[1], sys.argv[2], sys.argv[3]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

d = json.load(open(claim))
d["heartbeat"] = now
d["status"] = status
json.dump(d, open(claim, "w"), indent=2)
open(claim, "a").write("\n")

try:
    text = open(ledger).read()
    fixed, n = re.subn(r"^LAST WAKE:.*$", f"LAST WAKE: {now}", text, count=1, flags=re.M)
    if n:
        open(ledger, "w").write(fixed)
except FileNotFoundError:
    pass
PY
}

if [ "$MODE" = "--once" ]; then
  say "single wake for '$SLUG' (foreground)"
  run_one_wake
  beat RUNNING
  exit 0
fi

command -v tmux >/dev/null || die "tmux not found: brew install tmux"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  # A session existing does NOT mean a supervisor is running. When the loop reaches
  # READY-FOR-HUMAN or DONE it breaks and `exec bash`, deliberately leaving the session
  # open for inspection. The pane is then an idle shell, and refusing to relaunch on that
  # basis strands the PM: you unblock it, try to restart, and are told it is already
  # running when nothing is.
  PANE_CMD=$(tmux list-panes -t "$SESSION" -F '#{pane_current_command}' 2>/dev/null | head -1)
  case "$PANE_CMD" in
    bash|sh|zsh|"")
      say "'$SLUG' has a finished session (supervisor exited, pane is an idle $PANE_CMD)"
      say "  replacing it with a fresh supervisor"
      tmux kill-session -t "$SESSION" 2>/dev/null || true
      ;;
    *)
      say "'$SLUG' is already running (pane: $PANE_CMD)"
      say "  attach:  tmux attach -t $SESSION"
      say "  stop:    bash $SKILL_DIR/scripts/pm-launch.sh $SLUG --stop"
      exit 0
      ;;
  esac
fi

# Refuse to relaunch into a terminal state. Otherwise the loop would wake, immediately
# see READY-FOR-HUMAN, and stop again, burning a wake to learn what the ledger already says.
if grep -qE '^STATUS: (READY-FOR-HUMAN|DONE)' "$WORKTREE/LEDGER.md" 2>/dev/null; then
  warn "'$SLUG' is $(grep -m1 '^STATUS:' "$WORKTREE/LEDGER.md" | cut -d' ' -f2-)"
  warn "Resolve its BLOCKERS and set STATUS: RUNNING in $WORKTREE/LEDGER.md before relaunching."
  exit 1
fi

# The supervised loop, written to a file so tmux runs something inspectable rather
# than a giant quoted one-liner.
RUNNER="$WT_ROOT/.run-$SLUG.sh"
cat > "$RUNNER" <<RUNNER_EOF
#!/usr/bin/env bash
set -uo pipefail
fails=0
wake=0
while true; do
  # Check for a terminal state BEFORE waking, not only after.
  #
  # Checking only afterwards burns a full wake to rediscover what the ledger already
  # said. Observed live: the PM had written READY-FOR-HUMAN and an explicit "do not wake
  # again", and was woken anyway for a wake 3 that could only re-read its own conclusion.
  # That is a wasted wake at best, and at worst an idle PM slowly editing its own findings.
  if grep -qE '^STATUS: (READY-FOR-HUMAN|DONE)' "$WORKTREE/LEDGER.md" 2>/dev/null; then
    ST=\$(grep -m1 '^STATUS:' "$WORKTREE/LEDGER.md" 2>/dev/null | cut -d' ' -f2)
    BLK=\$(sed -n '/^## BLOCKERS/,/^## NEEDS-HUMAN-QA/p' "$WORKTREE/LEDGER.md" 2>/dev/null | grep -c '^- \[ \]')
    QA=\$(sed -n '/^## NEEDS-HUMAN-QA/,/^## DECISIONS/p' "$WORKTREE/LEDGER.md" 2>/dev/null | grep -c '^- \[ \]')
    if [ "\$ST" = "DONE" ]; then
      MSG="$SLUG finished. \$QA item(s) need your QA."
    else
      MSG="$SLUG stopped: \$BLK blocker(s), \$QA needing QA. Nothing else it can do."
    fi
    printf '\033[32m%s\033[0m\n' "\$MSG"
    osascript -e "display notification \"\$MSG\" with title \"nightshift\" sound name \"Glass\"" 2>/dev/null || true
    break
  fi

  wake=\$((wake + 1))
  printf '\n\033[36m=== wake %d  %s ===\033[0m\n' "\$wake" "\$(date -u +%H:%M:%SZ)"

  if bash "$SKILL_DIR/scripts/pm-launch.sh" "$SLUG" --once; then
    fails=0
  else
    fails=\$((fails + 1))
    printf '\033[33mwake failed (%d/%d consecutive)\033[0m\n' "\$fails" "$MAX_FAILS"
    if [ "\$fails" -ge "$MAX_FAILS" ]; then
      printf '\033[31mgiving up after %d consecutive failures\033[0m\n' "\$fails"
      python3 -c "
import json,datetime
p='$CLAIM'; d=json.load(open(p))
d['status']='CRASHED'
d['heartbeat']=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
json.dump(d,open(p,'w'),indent=2)"
      osascript -e 'display notification "$SLUG crashed after $MAX_FAILS wakes. Nothing is running." with title "nightshift" sound name "Basso"' 2>/dev/null || true
      break
    fi
    # Back off on repeated failure so a hard-broken PM does not burn tokens in a
    # tight crash loop overnight.
    sleep \$(( fails * 60 ))
    continue
  fi

  # Stop cleanly when the PM says it is done or is waiting on the human.
  if grep -qE '^STATUS: (READY-FOR-HUMAN|DONE)' "$WORKTREE/LEDGER.md" 2>/dev/null; then
    ST=\$(grep -m1 '^STATUS:' "$WORKTREE/LEDGER.md" 2>/dev/null | cut -d' ' -f2)
    BLK=\$(sed -n '/^## BLOCKERS/,/^## NEEDS-HUMAN-QA/p' "$WORKTREE/LEDGER.md" 2>/dev/null | grep -c '^- \[ \]')
    QA=\$(sed -n '/^## NEEDS-HUMAN-QA/,/^## DECISIONS/p' "$WORKTREE/LEDGER.md" 2>/dev/null | grep -c '^- \[ \]')
    if [ "\$ST" = "DONE" ]; then
      MSG="$SLUG finished. \$QA item(s) need your QA."
    else
      MSG="$SLUG stopped: \$BLK blocker(s), \$QA needing QA. Nothing else it can do."
    fi
    printf '\033[32m%s\033[0m\n' "\$MSG"
    osascript -e "display notification \"\$MSG\" with title \"nightshift\" sound name \"Glass\"" 2>/dev/null || true
    break
  fi

  sleep $INTERVAL
done
printf 'supervisor exited. session stays open for inspection.\n'
exec bash
RUNNER_EOF
chmod +x "$RUNNER"

say "launching '$SLUG' in tmux session '$SESSION'"
# caffeinate -i prevents idle sleep for the whole supervised tree. Without it the
# first closed lid ends the run.
tmux new-session -d -s "$SESSION" -c "$WORKTREE" "caffeinate -i bash '$RUNNER'"
beat RUNNING

cat <<EOF

  PM '$SLUG' is running.

    watch      tmux attach -t $SESSION      (detach: ctrl-b then d)
    status     bash $SKILL_DIR/scripts/pm-status.sh
    stop       bash $SKILL_DIR/scripts/pm-launch.sh $SLUG --stop

  wake interval ${INTERVAL}s. it stops on its own at READY-FOR-HUMAN or DONE.

EOF
