#!/usr/bin/env bash
# pm-launch.sh — run a PM for hours or days under an OS-level supervisor.
#
# Usage:
#   pm-launch.sh <slug>              start (or reattach to) a PM in tmux
#   pm-launch.sh <slug> --once       run exactly one wake in the foreground (test/debug)
#   pm-launch.sh <slug> --stop       stop the PM's tmux session
#   pm-launch.sh <slug> --provider claude|codex|cursor
#                                    set/persist the inference provider (combinable with --once)
#
# WHY A WRAPPER AND NOT /loop:
#   /loop registers its wakeups in memory. A closed laptop lid, a provider CLI
#   autoupdate, or a crash ends the run silently with no recovery. The agent CLI can
#   supply pacing; it cannot supply durability. That has to come from the OS.
#
# WHY EACH WAKE IS A FRESH PROVIDER PROCESS:
#   It makes the "resume from files" requirement true by construction instead of by
#   discipline. A fresh process cannot accidentally rely on session memory, so if
#   LEDGER.md is not sufficient to continue, that breaks immediately and visibly on
#   wake 2 rather than silently on day 2 after a compaction.
#
# PROVIDERS:
#   claude (default) — `claude -p` with nightshift skill + cost JSON
#   codex            — `codex exec` (ledger-driven; no Claude Agent/Workflow tools)
#   cursor           — `cursor-agent -p` (same limits as codex)
#   Resolve order: --provider > PM_PROVIDER env > claim.provider > claude.
#   CLI/env values are written to the claim so restarts stick.

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
MAX_STAGNANT="${PM_MAX_STAGNANT:-5}" # wakes with no progress before stopping

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }

[ $# -ge 1 ] || die "usage: pm-launch.sh <slug> [--once|--stop] [--provider claude|codex|cursor]"
SLUG="$1"; shift

MODE=""
PROVIDER_FLAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --once|--stop)
      [ -z "$MODE" ] || die "only one of --once / --stop allowed"
      MODE="$1"
      shift
      ;;
    --provider)
      [ $# -ge 2 ] || die "--provider needs claude|codex|cursor"
      PROVIDER_FLAG="$2"
      shift 2
      ;;
    --provider=*)
      PROVIDER_FLAG="${1#--provider=}"
      shift
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

CLAIM="$REGISTRY/$SLUG.json"

# A claim can be empty. It is created empty (that is what makes the claim atomic) and the
# JSON body is written last, so provisioning dying in between leaves a zero-byte file.
# Every script that json.loads it then crashes. Observed live during a config-gate test.
load_claim() {
  python3 -c "
import json, sys
try:
    d = json.load(open('$CLAIM'))
except Exception:
    sys.exit(0)
print(d.get(sys.argv[1], '') or '')
" "$1" 2>/dev/null || true
}
[ -f "$CLAIM" ] || die "no registry claim for '$SLUG'. run pm-provision.sh first."

WORKTREE=$(load_claim worktree)
SESSION="pm-$SLUG"
[ -n "$WORKTREE" ] || die "claim for '$SLUG' is empty or malformed. delete $CLAIM and re-provision."
[ -d "$WORKTREE" ] || die "worktree missing: $WORKTREE"
[ -f "$WORKTREE/LEDGER.md" ] || die "no LEDGER.md in $WORKTREE. re-run pm-provision.sh."

if [ "$MODE" = "--stop" ]; then
  tmux kill-session -t "$SESSION" 2>/dev/null && say "stopped $SESSION" || say "$SESSION was not running"
  python3 - "$CLAIM" <<'PY'
import json, sys
p = sys.argv[1]
try:
    d = json.load(open(p))
except Exception:
    d = {}
d["status"] = "STOPPED"
json.dump(d, open(p, "w"), indent=2)
open(p, "a").write("\n")
PY
  exit 0
fi

# Resolve inference provider. Persist when CLI or env explicitly set one so the
# supervised loop's later --once calls (which only read the claim) keep the choice.
CLAIM_PROVIDER=$(load_claim provider)
PROVIDER="${PROVIDER_FLAG:-${PM_PROVIDER:-${CLAIM_PROVIDER:-claude}}}"
case "$PROVIDER" in
  claude|codex|cursor) ;;
  *) die "unknown provider '$PROVIDER' (want claude|codex|cursor)" ;;
esac

if [ -n "$PROVIDER_FLAG" ] || [ -n "${PM_PROVIDER:-}" ]; then
  CLAIM="$CLAIM" PROVIDER="$PROVIDER" python3 -c '
import json, os
p, prov = os.environ["CLAIM"], os.environ["PROVIDER"]
try:
    d = json.load(open(p))
except Exception:
    d = {}
d["provider"] = prov
json.dump(d, open(p, "w"), indent=2)
open(p, "a").write("\n")
'
  say "provider set to '$PROVIDER' (persisted on claim)"
fi

provider_bin() {
  case "$1" in
    claude) echo claude ;;
    codex) echo codex ;;
    cursor) echo cursor-agent ;;
  esac
}
BIN=$(provider_bin "$PROVIDER")
command -v "$BIN" >/dev/null || die "'$BIN' not found on PATH. install it, or pick another --provider"

# Shared wake body. Ledger is the memory; the provider process is disposable.
read -r -d '' WAKE_BODY <<PROMPT || true
You are PM "$SLUG", working in $WORKTREE.

This is a fresh process with no memory of previous wakes. Everything you know is on
disk. Read $WORKTREE/LEDGER.md first, then the OpenSpec tasks.md it points at, then
continue the loop from wherever the ledger says you are.

Do one useful unit of work this wake, verify it yourself, write the result back to the
ledger, and exit. Do not try to finish the whole feature in one wake.

If every remaining task is BLOCKED, set STATUS: READY-FOR-HUMAN at the top of the
ledger and exit without doing more work.
PROMPT

# Claude can load the nightshift skill; other providers only get the ledger-driven body.
if [ "$PROVIDER" = "claude" ]; then
  WAKE_PROMPT="Use the nightshift skill. $WAKE_BODY"
else
  WAKE_PROMPT="Follow the nightshift PM loop using only what is on disk (LEDGER.md and any OpenSpec files it references). You do not have Claude Code's Agent/Workflow tools. $WAKE_BODY"
fi

# Standing Workflow orchestration for the PM. Opt in with PM_WORKFLOWS=1.
# Claude-only: Codex/Cursor have no equivalent settings key.
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

# Settings passed to EVERY Claude wake, so a PM's behavior does not depend on whatever
# the human's global settings happen to be.
#
# askUserQuestionTimeout is the important one. It defaults to "never", which means a
# question blocks until the run ages out. For a PM that is the worst possible default:
# nobody is there, so waiting cannot produce an answer, it only converts a bug into a
# stall. 60s is the shortest the enum allows and still far longer than needed, because
# a question during a wake is already a symptom of an under-specified dispatch.
#
# The human's own sessions are unaffected by this; it applies only to wakes.
WAKE_SETTINGS='{"askUserQuestionTimeout":"60s"}'
WORKFLOW_SETTINGS='{"askUserQuestionTimeout":"60s","ultracode":true,"workflowSizeGuideline":"small"}'

# Best-effort wake accounting. Claude's result JSON has total_cost_usd. Other providers
# may or may not; never invent a number.
record_wake() {
  CLAIM="$CLAIM" OUT="$1" PROVIDER="$PROVIDER" python3 -c '
import json, os
claim, out, provider = os.environ["CLAIM"], os.environ["OUT"], os.environ["PROVIDER"]
try:
    raw = open(out).read().strip()
    if not raw:
        raise SystemExit
    d = json.loads(raw)
except Exception:
    # Still count the wake so stagnation/cost visibility is not frozen on parse failure.
    try:
        c = json.load(open(claim))
    except Exception:
        c = {}
    c["wakes"] = c.get("wakes", 0) + 1
    c["provider"] = provider
    json.dump(c, open(claim, "w"), indent=2); open(claim, "a").write("\n")
    raise SystemExit

# Claude: list of events with type==result
# Codex --json / cursor-agent --output-format json: object or event stream
cost = None
turns = None
text = ""

def from_result(r):
    global cost, turns, text
    if not isinstance(r, dict):
        return
    if r.get("total_cost_usd") is not None:
        cost = float(r["total_cost_usd"] or 0)
    elif r.get("cost_usd") is not None:
        cost = float(r["cost_usd"] or 0)
    elif isinstance(r.get("usage"), dict) and r["usage"].get("cost_usd") is not None:
        cost = float(r["usage"]["cost_usd"] or 0)
    if r.get("num_turns") is not None:
        turns = r.get("num_turns")
    text = r.get("result") or r.get("message") or r.get("last_message") or text

if isinstance(d, list):
    for o in d:
        if isinstance(o, dict) and o.get("type") == "result":
            from_result(o)
            break
    if cost is None:
        for o in d:
            if isinstance(o, dict):
                from_result(o)
elif isinstance(d, dict):
    from_result(d)
    if d.get("type") == "result":
        from_result(d)

try:
    c = json.load(open(claim))
except Exception:
    c = {}
c["wakes"] = c.get("wakes", 0) + 1
c["provider"] = provider
if cost is not None:
    c["cost_usd"] = round(c.get("cost_usd", 0.0) + cost, 4)
    c["last_wake_cost_usd"] = round(cost, 4)
if turns is not None:
    c["last_wake_turns"] = turns
json.dump(c, open(claim, "w"), indent=2); open(claim, "a").write("\n")
if text:
    print(str(text)[:2000])
' 2>/dev/null || true
}

run_one_wake() {
  cd "$WORKTREE"
  OUT="$WORKTREE/.nightshift-wake.json"
  : > "$OUT"
  rc=0

  case "$PROVIDER" in
    claude)
      # OPENCLAW_SESSION=true puts gstack skills in auto-choose mode instead of stopping
      # to ask. Verified by running gstack-session-kind directly.
      # Do NOT set CI or GITHUB_ACTIONS: those resolve to `headless`, which makes gstack
      # BLOCK on an AskUserQuestion failure rather than auto-choosing. That is worse than
      # doing nothing.
      # --output-format json so the wake reports total_cost_usd exactly. Without this a
      # PM's spend is invisible until the bill: it wakes >=24x/day, each wake fans out, and
      # PM_WORKFLOWS multiplies that again. An unattended system that can quietly cost money
      # needs the number surfaced, not estimated.
      if [ "${PM_WORKFLOWS:-0}" = "1" ]; then
        OPENCLAW_SESSION=true PM_SLUG="$SLUG" \
          claude -p "$WAKE_PROMPT" --settings "$WORKFLOW_SETTINGS" --output-format json > "$OUT" || rc=$?
      else
        OPENCLAW_SESSION=true PM_SLUG="$SLUG" \
          claude -p "$WAKE_PROMPT" --settings "$WAKE_SETTINGS" --output-format json > "$OUT" || rc=$?
      fi
      ;;
    codex)
      # Unattended: full bypass. workspace-write is not enough for package installs / tests.
      # stdin must be /dev/null: when a prompt is also passed, a live/piped stdin makes
      # codex wait on "Reading additional input from stdin..." and stall the wake.
      codex exec --json \
        --dangerously-bypass-approvals-and-sandbox \
        -C "$WORKTREE" \
        "$WAKE_PROMPT" < /dev/null > "$OUT" || rc=$?
      ;;
    cursor)
      cursor-agent -p --force --trust --sandbox disabled \
        --workspace "$WORKTREE" \
        --output-format json \
        "$WAKE_PROMPT" < /dev/null > "$OUT" || rc=$?
      ;;
  esac

  record_wake "$OUT"
  return $rc
}

# Stamp the heartbeat AND the ledger's LAST WAKE line.
#
# Both are the supervisor's job, never the PM's, for two measured reasons:
#
#  1. The registry lives outside the PM's worktree, and a sandboxed PM gets
#     "EPERM: operation not permitted, open 'smoke.json'" trying to write it. If the PM
#     owned the heartbeat, every healthy PM would look dead after two hours and the
#     watchdog would restart live ones, putting two provider processes on one branch. That
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

try:
    d = json.load(open(claim))
except Exception:
    d = {}
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
  say "single wake for '$SLUG' via $PROVIDER (foreground)"
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
# than a giant quoted one-liner. Provider lives on the claim; each --once re-reads it.
RUNNER="$WT_ROOT/.run-$SLUG.sh"
cat > "$RUNNER" <<RUNNER_EOF
#!/usr/bin/env bash
set -uo pipefail
fails=0
wake=0
stagnant=0
LAST_SIG=""
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

  # No-progress detection. The expensive silent failure is not a crash, it is a PM that
  # wakes, does something useless, writes a log line, and looks healthy forever. Nothing
  # else in this loop catches that: STATUS stays RUNNING, the heartbeat keeps ticking,
  # and pm-status shows green while the spend climbs.
  #
  # Progress = a new commit on the branch, or a newly checked box in the ledger.
  SIG=\$(cd "$WORKTREE" && printf '%s|%s' \
        "\$(git rev-list --count HEAD 2>/dev/null || echo 0)" \
        "\$(grep -c '^- \[x\]' LEDGER.md 2>/dev/null || echo 0)")
  if [ "\$SIG" = "\${LAST_SIG:-}" ]; then
    stagnant=\$((stagnant + 1))
  else
    stagnant=0
  fi
  LAST_SIG="\$SIG"
  if [ "\$stagnant" -ge "$MAX_STAGNANT" ]; then
    MSG="$SLUG made no progress in $MAX_STAGNANT wakes. Stopping so it stops costing money."
    printf '\033[33m%s\033[0m\n' "\$MSG"
    osascript -e "display notification \"\$MSG\" with title \"nightshift\" sound name \"Basso\"" 2>/dev/null || true
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
json.dump(d,open(p,'w'),indent=2); open(p,'a').write(chr(10))"
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

say "launching '$SLUG' in tmux session '$SESSION' (provider: $PROVIDER)"
# caffeinate -i prevents idle sleep for the whole supervised tree. Without it the
# first closed lid ends the run.
tmux new-session -d -s "$SESSION" -c "$WORKTREE" "caffeinate -i bash '$RUNNER'"
beat RUNNING

cat <<EOF

  PM '$SLUG' is running via $PROVIDER.

    watch      tmux attach -t $SESSION      (detach: ctrl-b then d)
    status     bash $SKILL_DIR/scripts/pm-status.sh
    stop       bash $SKILL_DIR/scripts/pm-launch.sh $SLUG --stop
    provider   bash $SKILL_DIR/scripts/pm-launch.sh $SLUG --provider claude|codex|cursor

  wake interval ${INTERVAL}s. it stops on its own at READY-FOR-HUMAN or DONE.

EOF
