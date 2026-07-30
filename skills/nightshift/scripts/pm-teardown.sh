#!/usr/bin/env bash
# pm-teardown.sh — retire a PM cleanly, in the one order that works.
#
# Usage:
#   pm-teardown.sh <slug>            stop it, remove the worktree, keep the branch
#   pm-teardown.sh <slug> --branch   also delete the local branch (refuses if unmerged)
#
# WHY THIS SCRIPT EXISTS:
#   Teardown has an ordering trap that costs disk permanently, and it is not obvious.
#
#   `git worktree remove` is the only cleanup verb an agent has where `rm -rf` is denied
#   by policy, and it only works on a REGISTERED worktree. `git worktree prune`
#   deregisters any worktree whose tree looks invalid, including one whose removal
#   failed partway (exactly what happens when a sandbox cannot delete every file).
#
#   So `prune` before `remove` strands the directory: remove then answers "is not a
#   working tree", and the only remaining verb is the denied one. Measured cost of
#   getting this wrong once: 450M that needed a human to clear.
#
#   Correct order, which this script enforces:
#     1. stop the supervisor            (nothing should be writing)
#     2. git worktree remove            (reclaims the disk)
#     3. git worktree prune             (tidies registrations)
#     4. mark the registry DONE         (keeps the record; never delete it)

set -euo pipefail

REPO="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$REPO" ] || { echo "error: not inside a git repository." >&2; exit 1; }
WT_ROOT="$REPO/.claude/worktrees"
REGISTRY="$WT_ROOT/registry"
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
say()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }

[ $# -ge 1 ] || die "usage: pm-teardown.sh <slug> [--branch]"
SLUG="$1"; DROP_BRANCH="${2:-}"

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
[ -f "$CLAIM" ] || die "no registry claim for '$SLUG'"

WORKTREE=$(load_claim worktree)
BRANCH=$(load_claim branch)

# ---------------------------------------------------------------------------
# Refuse to destroy unreviewed work. A PM's whole output is its branch.
# ---------------------------------------------------------------------------
if [ -d "$WORKTREE" ]; then
  # nightshift writes LEDGER.md, INBOX.md, vite.pm.config.js and a wake-result file into
  # every worktree. They are the tool's own state, never the human's work, so they must not
  # count as "uncommitted changes". Without this exclusion teardown refuses on every PM.
  NS_ARTIFACTS='LEDGER\.md|INBOX\.md|vite\.pm\.config\.js|\.nightshift-wake\.json'
  DIRTY=$(git -C "$WORKTREE" status --porcelain 2>/dev/null | grep -Ev "$NS_ARTIFACTS" | wc -l | tr -d ' ')
  if [ "$DIRTY" -gt 0 ]; then
    warn "$SLUG has $DIRTY uncommitted path(s):"
    git -C "$WORKTREE" status --short 2>/dev/null | grep -Ev "$NS_ARTIFACTS" | head -10 | sed 's/^/    /'
    die "refusing to tear down. commit, stash, or discard first."
  fi
  UNPUSHED=$(git -C "$WORKTREE" log --oneline "@{u}..HEAD" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  [ "$UNPUSHED" = "0" ] || warn "$UNPUSHED commit(s) not pushed; the branch is kept so nothing is lost"
fi

# ---------------------------------------------------------------------------
# 1. Stop the supervisor first, so nothing is mid-write during removal.
# ---------------------------------------------------------------------------
say "stopping supervisor"
bash "$SKILL_DIR/scripts/pm-launch.sh" "$SLUG" --stop >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 2. remove, THEN 3. prune. Order is the whole point of this script.
# ---------------------------------------------------------------------------
if [ -d "$WORKTREE" ]; then
  SIZE=$(du -sh "$WORKTREE" 2>/dev/null | cut -f1)
  say "removing worktree ($SIZE)"
  if git -C "$REPO" worktree remove --force "$WORKTREE" 2>&1 | sed 's/^/    /'; then
    say "  removed"
  else
    warn "  remove failed. NOT pruning: pruning now would strand $WORKTREE"
    warn "  where no agent could reclaim it. Fix the removal, then re-run."
    exit 1
  fi
else
  say "no worktree directory to remove"
fi

say "pruning registrations"
git -C "$REPO" worktree prune 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Branch and registry.
# ---------------------------------------------------------------------------
if [ "$DROP_BRANCH" = "--branch" ] && [ -n "$BRANCH" ]; then
  if git -C "$REPO" branch -d "$BRANCH" 2>&1 | sed 's/^/    /'; then
    say "deleted branch $BRANCH"
  else
    warn "branch $BRANCH not deleted (likely unmerged). Left in place on purpose."
  fi
elif [ -n "$BRANCH" ]; then
  say "branch $BRANCH kept (pass --branch to delete it)"
fi

# Keep the record. It is how the human finds the PR later, and how a future PM knows
# that slug's branch already exists.
python3 - "$CLAIM" <<'PY'
import json, sys, datetime
p = sys.argv[1]
try:
    d = json.load(open(p))
except Exception:
    d = {}          # empty or malformed claim: still record the outcome
d["status"] = "DONE"
d["torn_down"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(d, open(p, "w"), indent=2); open(p, "a").write("\n")
PY
say "registry marked DONE (kept on purpose)"

# If nightshift moved during the run, say so. It explains why an old PM and a
# new one behave differently, which is otherwise a confusing thing to discover.
PINNED=$(load_claim plugin_sha)
[ -n "$PINNED" ] && bash "$SKILL_DIR/scripts/pm-version.sh" drift "$PINNED" || true

COST=$(load_claim cost_usd)
WAKES=$(load_claim wakes)
printf '\n  %s torn down.  %s wakes,  $%s total\n\n' "$SLUG" "$WAKES" "$COST"
