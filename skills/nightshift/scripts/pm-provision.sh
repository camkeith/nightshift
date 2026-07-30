#!/usr/bin/env bash
# pm-provision.sh — claim a PM slot and build a working worktree for it.
#
# Usage:
#   pm-provision.sh <slug> "<feature brief>" [package ...]
#
#   <slug>      short kebab identifier, e.g. billing
#   <brief>     one line describing the feature
#   [package]   packages to npm install. Default: api
#               valid: api client public-client admin-client root
#
# Example:
#   pm-provision.sh billing "per-seat billing for institutions" api client
#
# Idempotent: re-running for an existing slug re-verifies and repairs the worktree
# rather than failing, so it is safe to run again after a crash.

set -euo pipefail

# Resolve the repo from the current git worktree rather than pinning a path, so this
# works in any checkout. Run these scripts from inside the repo you want a PM to work on.
REPO="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$REPO" ] || { echo "error: not inside a git repository. cd into your repo first." >&2; exit 1; }

# Worktrees live INSIDE the repo, under .claude/worktrees/.
#
# Not an aesthetic choice. A sandboxed Claude session can only write within its cwd
# (the repo) and $TMPDIR. `~/.claude-worktrees` fails with "Operation not permitted",
# which is what killed the first smoke test at its very first mkdir. $TMPDIR is worse:
# it is purged on reboot, and five stale worktrees are already stranded there.
#
# .claude/ is gitignored (.gitignore:204) and .claude/worktrees is already an existing
# convention in this repo, so this adds nothing new to reason about.
WT_ROOT="$REPO/.claude/worktrees"
REGISTRY="$WT_ROOT/registry"
# ---------------------------------------------------------------------------
# PER-REPO CONFIG. Edit this block for your repository.
#
# Everything from here to the end of ENV_FILES is repo-specific. `repo-recon` tells
# you exactly what belongs here: run it first and read the "Worktree provisioning"
# and "Ship boundary" sections of the repo-facts.md it produces.
#
# Not yet auto-derived. That is the main known limitation of v0.1.0, and it is a
# deliberate one: guessing a repo's gitignored-but-required files wrong produces a
# worktree that looks fine and cannot run anything, which is worse than asking.
# ---------------------------------------------------------------------------
BASE_BRANCH="develop"

# The four gitignored files a fresh worktree does NOT inherit. Provisioning that
# skips these produces a worktree that looks fine and cannot run anything.
ENV_FILES=(
  "api/.env"
  "client/.env"
  "public-client/.env"
  "admin-client/.env.local"
)

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }

[ $# -ge 2 ] || die "usage: pm-provision.sh <slug> \"<feature brief>\" [package ...]"

SLUG="$1"; shift
BRIEF="$1"; shift
PACKAGES=("$@")
[ ${#PACKAGES[@]} -gt 0 ] || PACKAGES=("api")

[[ "$SLUG" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "slug must be lowercase kebab: got '$SLUG'"

BRANCH="feat/$SLUG"
WORKTREE="$WT_ROOT/pm-$SLUG"
TEST_DB="acme_test_$SLUG"
CLAIM="$REGISTRY/$SLUG.json"

mkdir -p "$REGISTRY"

# ---------------------------------------------------------------------------
# 1. Claim the slug atomically.
#
# Creating the file IS the claim. `set -C` (noclobber) makes this atomic without
# a lock file, which matters because a crashed PM holding a lock would deadlock
# every other PM with no way to tell a live holder from a dead one.
# ---------------------------------------------------------------------------
if [ -e "$CLAIM" ]; then
  EXISTING_STATUS=$(python3 -c "import json;print(json.load(open('$CLAIM')).get('status','?'))" 2>/dev/null || echo "?")
  warn "slug '$SLUG' already claimed (status=$EXISTING_STATUS); re-verifying instead of re-claiming"
else
  say "claiming slug '$SLUG'"
  if ! ( set -C; : > "$CLAIM" ) 2>/dev/null; then
    die "lost a race claiming '$SLUG'; another PM took it. pick a different slug."
  fi
fi

# ---------------------------------------------------------------------------
# 2. Worktree hygiene.
#
# ORDER MATTERS, and getting it backwards strands disk permanently.
#
# `git worktree remove` is the only cleanup verb an agent has when `rm -rf` is denied
# by policy, and remove only works on a REGISTERED worktree. `prune` deregisters any
# whose tree looks invalid, which includes one whose removal failed partway. That is
# exactly what happens when a sandbox cannot delete every file inside it. Once pruned,
# remove refuses with "is not a working tree" and nothing an agent can run reclaims
# the space.
#
# So for TEARDOWN always `remove` THEN `prune`, never the reverse. This cost 450M once
# on the repo this skill was built against: a failed remove followed by a prune left an
# orphan only a human could clear.
#
# Provisioning only prunes, which is safe by itself, but it then checks for directories
# that prune orphaned so a silent leak becomes a visible warning carrying the exact
# command a human needs. None of this may abort provisioning.
# ---------------------------------------------------------------------------
say "worktree hygiene"

registered() {
  git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}'
}

git -C "$REPO" worktree prune 2>/dev/null || true
REGISTERED=$(registered)
say "  $(printf '%s\n' "$REGISTERED" | grep -c . || true) worktrees registered after prune"

# Anything on disk under WT_ROOT that git no longer tracks is orphaned space.
ORPHANS=0
if [ -d "$WT_ROOT" ]; then
  for d in "$WT_ROOT"/*/; do
    [ -d "$d" ] || continue
    dir="${d%/}"
    [ "$(basename "$dir")" = "registry" ] && continue
    if ! printf '%s\n' "$REGISTERED" | grep -qxF "$dir"; then
      ORPHANS=$((ORPHANS + 1))
      warn "orphaned worktree, git does not track it: $dir ($(du -sh "$dir" 2>/dev/null | cut -f1))"
      warn "  no agent can reclaim this. a human must run:  rm -rf \"$dir\""
    fi
  done
fi
[ "$ORPHANS" -eq 0 ] || warn "$ORPHANS orphaned worktree(s) above; provisioning continues"

# ---------------------------------------------------------------------------
# 3. Create the worktree, serialized.
#
# `git worktree add` writes the shared .git index, so two concurrent adds contend
# on index.lock. A short mkdir-based mutex is enough; it is held for seconds, not
# for the life of the PM, so a crash here is cheap to recover from.
# ---------------------------------------------------------------------------
GIT_LOCK="$WT_ROOT/.worktree-add.lock"
if [ -d "$WORKTREE" ]; then
  say "worktree already exists at $WORKTREE"
else
  say "creating worktree $WORKTREE on $BRANCH (from $BASE_BRANCH)"
  for _ in $(seq 1 60); do
    if mkdir "$GIT_LOCK" 2>/dev/null; then
      trap 'rmdir "$GIT_LOCK" 2>/dev/null || true' EXIT
      break
    fi
    sleep 1
  done
  [ -d "$GIT_LOCK" ] || die "could not acquire worktree lock after 60s"

  # Fetch is best-effort. The remote is SSH and the sandbox proxy cannot negotiate it
  # ("nc: authentication method negotiation failed"), so inside a sandbox this always
  # fails. Branching from the local base is correct fallback behavior, not degraded.
  if git -C "$REPO" fetch origin "$BASE_BRANCH" --quiet 2>/dev/null; then
    say "  fetched origin/$BASE_BRANCH"
  else
    warn "  fetch failed (SSH is unreachable from a sandbox); using local $BASE_BRANCH"
  fi

  # Resolve a base ref that definitely exists BEFORE calling worktree add.
  # Do not chain `add -b ... || add -b ...`: the first attempt creates the branch even
  # when it then fails, so the fallback dies on "a branch named X already exists" and
  # leaves a stray branch behind. That is a real bug this script shipped with once.
  if git -C "$REPO" show-ref --verify --quiet "refs/remotes/origin/$BASE_BRANCH"; then
    BASE_REF="origin/$BASE_BRANCH"
  elif git -C "$REPO" show-ref --verify --quiet "refs/heads/$BASE_BRANCH"; then
    BASE_REF="$BASE_BRANCH"
  else
    die "no base branch '$BASE_BRANCH' found locally or on origin"
  fi

  # Create the branch separately, with --no-track, THEN attach a worktree to it.
  #
  # `worktree add -b X <path> origin/develop` auto-configures upstream tracking, which
  # writes .git/config, which the sandbox denies ("could not lock config file"). The
  # whole command then exits non-zero having already created the branch. Splitting the
  # two steps and passing --no-track avoids the config write entirely, and keeps branch
  # creation and worktree attachment independently retryable.
  #
  # Losing upstream tracking costs nothing here: this skill requires an explicit
  # `git push origin <branch>` anyway, precisely so work never drifts to the personal
  # backup remote some branches in this repo are configured against.
  if ! git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    say "  branching $BRANCH from $BASE_REF (no upstream tracking)"
    git -C "$REPO" branch --no-track "$BRANCH" "$BASE_REF"
  else
    say "  branch $BRANCH already exists, reusing it"
  fi
  # Attach the worktree WITHOUT checking out .claude/.
  #
  # The sandbox denies writes to .claude/commands and .claude/hooks anywhere inside the
  # repo tree, at any depth. Git tracks exactly three files there (commands/commit.md,
  # commands/commit-merge.md, hooks/notify.sh), so a plain checkout dies with
  # "unable to create file .claude/commands/commit.md: Operation not permitted" and
  # leaves a half-built worktree behind.
  #
  # Excluding those three costs a PM nothing: they are the human's slash commands and a
  # desktop-notification hook, none of which a PM invokes. Everything else checks out
  # normally.
  say "  attaching worktree (sparse: excluding .claude/)"
  git -C "$REPO" worktree add --no-checkout "$WORKTREE" "$BRANCH"
  if git -C "$WORKTREE" sparse-checkout set --no-cone '/*' '!/.claude/' 2>/dev/null; then
    git -C "$WORKTREE" checkout 2>&1 | tail -2
  else
    warn "  sparse-checkout unavailable; falling back to full checkout"
    git -C "$WORKTREE" checkout || die "checkout failed. If this is a sandbox denial, run this script from a normal terminal outside Claude Code."
  fi

  rmdir "$GIT_LOCK" 2>/dev/null || true
  trap - EXIT
fi

# ---------------------------------------------------------------------------
# 4. Copy the gitignored env files.
#
# Real failure this prevents: ~/.claude-worktrees/acme-app/priceless-cohen has
# sat since January with no node_modules, because provisioning silently never
# finished and nothing checked.
# ---------------------------------------------------------------------------
say "copying gitignored env files"
MISSING_ENV=0
for f in "${ENV_FILES[@]}"; do
  if [ -f "$REPO/$f" ]; then
    mkdir -p "$WORKTREE/$(dirname "$f")"
    cp "$REPO/$f" "$WORKTREE/$f"
    printf '     %s\n' "$f"
  else
    warn "  source missing, skipped: $f"
    MISSING_ENV=$((MISSING_ENV + 1))
  fi
done

# ---------------------------------------------------------------------------
# 5. Pin this PM's test database.
#
# THE most important line in this script. Nine test files in api/src default to
# the same 'acme_test' DB, and worker-resilience.test.js runs an
# unconditional Job.deleteMany({}) in beforeEach. Two PMs without this setting
# wipe each other's fixtures, and the symptom is a flaky failure in your own
# branch that you will "fix" in source.
# ---------------------------------------------------------------------------
say "pinning TEST_MONGODB_URI to $TEST_DB"
if [ -f "$WORKTREE/api/.env" ]; then
  # Remove any inherited value, then append ours. Last assignment wins in dotenv.
  grep -v '^TEST_MONGODB_URI=' "$WORKTREE/api/.env" > "$WORKTREE/api/.env.tmp" || true
  mv "$WORKTREE/api/.env.tmp" "$WORKTREE/api/.env"
  printf '\nTEST_MONGODB_URI=mongodb://localhost/%s\n' "$TEST_DB" >> "$WORKTREE/api/.env"
  # And the DEV database, which matters now that PMs may run their own API for QA.
  # Without this every PM's dev server writes to the human's real dev data and to each
  # other's. Port isolation alone does not help: separate processes, one database.
  grep -v '^MONGODB_URI=' "$WORKTREE/api/.env" > "$WORKTREE/api/.env.tmp" 2>/dev/null || true
  mv "$WORKTREE/api/.env.tmp" "$WORKTREE/api/.env" 2>/dev/null || true
  printf 'MONGODB_URI="mongodb://localhost:27017/%s_dev"\n' "$TEST_DB" >> "$WORKTREE/api/.env"
  say "  dev DB pinned to ${TEST_DB}_dev"
else
  mkdir -p "$WORKTREE/api"
  printf 'TEST_MONGODB_URI=mongodb://localhost/%s\n' "$TEST_DB" > "$WORKTREE/api/.env"
  warn "api/.env did not exist; created one with only TEST_MONGODB_URI"
fi

# ---------------------------------------------------------------------------
# 5b. Allocate a private port block, and generate per-PM vite configs.
#
# This is what makes browser QA possible with several PMs running.
#
# The three vite configs hardcode `target: http://localhost:9090` with no env read,
# so a PM starting a frontend on its own port would still have its API calls land on
# whatever owns 9090 (the human's stack, or another PM's). The frontend looks
# perfect and every QA conclusion is about the wrong code.
#
# The fix is not to edit shipping config. b2b-client already runs
# `vite --config <file>`, so we generate a PM-private config that imports the base
# and overrides ONLY server.port and the /api proxy target. Shipping config is
# untouched, the generated file is excluded from git, and each PM's browser talks to
# its own API.
#
# Ports are deterministic per PM so two PMs can never collide, and the block starts
# well above the human's stack (9090, 8081, 3001, 3100, 3200).
# ---------------------------------------------------------------------------
PORT_BASE=$(REG="$REGISTRY" SLUG="$SLUG" python3 -c '
import glob, json, os
reg, slug = os.environ["REG"], os.environ["SLUG"]
taken = {}
for p in glob.glob(os.path.join(reg, "*.json")):
    try: d = json.load(open(p))
    except Exception: continue
    if d.get("port_base"): taken[d["slug"]] = d["port_base"]
if slug in taken:
    print(taken[slug])
else:
    b = 9200
    while b in taken.values(): b += 20
    print(b)
')
API_PORT=$((PORT_BASE + 0))
say "port block $PORT_BASE-$((PORT_BASE + 19))  (api=$API_PORT)"

gen_vite_config() {
  pkg="$1"; base_cfg="$2"; fe_port="$3"
  [ -f "$WORKTREE/$pkg/$base_cfg" ] || return 0
  {
    echo "// Generated by nightshift for PM \"$SLUG\". Do NOT commit; it is git-excluded."
    echo "// Imports the repo's real config and overrides only the dev server, so this PM's"
    echo "// browser talks to this PM's API instead of whatever owns the shared port."
    echo "import base from './$base_cfg';"
    echo ""
    echo "const server = base.server || {};"
    echo "const proxy = server.proxy || {};"
    echo "const api = proxy['/api'] || {};"
    echo ""
    echo "export default {"
    echo "  ...base,"
    echo "  server: {"
    echo "    ...server,"
    echo "    port: $fe_port,"
    echo "    strictPort: true,"
    echo "    proxy: { ...proxy, '/api': { ...api, target: 'http://localhost:$API_PORT' } },"
    echo "  },"
    echo "};"
  } > "$WORKTREE/$pkg/vite.pm.config.js"
  printf '     %s/vite.pm.config.js -> :%s, api :%s\n' "$pkg" "$fe_port" "$API_PORT"
}

say "generating PM-private vite configs"
gen_vite_config booking-client vite.config.js         $((PORT_BASE + 1))
gen_vite_config b2b-client     vite.portal.config.js  $((PORT_BASE + 2))
gen_vite_config b2b-client     vite.console.config.js $((PORT_BASE + 3))

# Keep generated configs out of every diff, without touching the repo's .gitignore.
EXCL="$WORKTREE/.git/info/exclude"
[ -f "$EXCL" ] || EXCL="$(git -C "$WORKTREE" rev-parse --git-path info/exclude 2>/dev/null)"
if [ -n "$EXCL" ]; then
  mkdir -p "$(dirname "$EXCL")" 2>/dev/null || true
  grep -q "vite.pm.config.js" "$EXCL" 2>/dev/null || \
    printf '\n# nightshift per-PM dev-server configs\n**/vite.pm.config.js\n' >> "$EXCL" 2>/dev/null || true
fi

# A PM running its own API must not collide on the API port either.
if [ -f "$WORKTREE/api/.env" ]; then
  grep -v '^PORT=' "$WORKTREE/api/.env" > "$WORKTREE/api/.env.tmp" 2>/dev/null || true
  mv "$WORKTREE/api/.env.tmp" "$WORKTREE/api/.env" 2>/dev/null || true
  printf 'PORT=%s\n' "$API_PORT" >> "$WORKTREE/api/.env"
  say "  api/.env PORT=$API_PORT"
fi

# ---------------------------------------------------------------------------
# 6. Install only the blast radius.
#
# Not an npm workspace, no hoisting. A full install is ~1.75G; an api-only
# feature installing only api/ is roughly a 3x saving on disk and wall clock.
# ---------------------------------------------------------------------------
for pkg in "${PACKAGES[@]}"; do
  case "$pkg" in
    root) dir="$WORKTREE" ;;
    api|client|public-client|admin-client) dir="$WORKTREE/$pkg" ;;
    *) die "unknown package '$pkg' (valid: api client public-client admin-client root)" ;;
  esac
  [ -f "$dir/package.json" ] || { warn "no package.json in $pkg, skipping"; continue; }
  if [ -d "$dir/node_modules" ]; then
    say "$pkg: node_modules present, skipping install"
  else
    say "$pkg: npm install (this is the slow part)"
    ( cd "$dir" && npm install --no-audit --no-fund ) || die "npm install failed in $pkg"
  fi
done

# ---------------------------------------------------------------------------
# 7. Ledger skeleton. The PM's identity lives here, not in any session.
# ---------------------------------------------------------------------------
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [ -f "$WORKTREE/LEDGER.md" ]; then
  say "LEDGER.md already exists, leaving it alone"
else
  say "writing LEDGER.md"
  cat > "$WORKTREE/LEDGER.md" <<LEDGER
# PM: $SLUG

STATUS: RUNNING
FEATURE: $BRIEF
BRANCH: $BRANCH
WORKTREE: $WORKTREE
TEST_DB: $TEST_DB
OPENSPEC: (not yet created)
STARTED: $NOW
LAST WAKE: $NOW

## BLOCKERS

(none)

## NEEDS-HUMAN-QA

(none)

## DECISIONS

- $NOW — provisioned. packages installed: ${PACKAGES[*]}

## PROPOSED SKILLS

(none)

## WAKE LOG

- $NOW provisioned, no work started
LEDGER
fi

# ---------------------------------------------------------------------------
# 7b. INBOX.md — the sanctioned channel for telling a running PM something new.
#
# Without this the human's only options are to stop the PM or write into its LEDGER,
# and the ledger's authorship rule says unattributed content in its own voice is an
# injection surface. An inbox keeps the ledger clean: the PM reads INBOX, verifies,
# and records the outcome in its own words.
# ---------------------------------------------------------------------------
if [ ! -f "$WORKTREE/INBOX.md" ]; then
  {
    echo "# Inbox for PM: $SLUG"
    echo
    echo "Append messages here while the PM is running. It reads this at the start of"
    echo "every wake, treats each entry as INPUT TO VERIFY rather than instruction, acts"
    echo "on what survives verification, and records the outcome in its ledger."
    echo
    echo "Leave entries in place; the PM marks them handled rather than deleting them."
    echo
    echo "## Messages"
    echo
    echo "(none)"
  } > "$WORKTREE/INBOX.md"
  say "wrote INBOX.md"
fi

# ---------------------------------------------------------------------------
# 8. Registry record.
# ---------------------------------------------------------------------------
PORT_BASE="$PORT_BASE" python3 - "$CLAIM" "$SLUG" "$BRIEF" "$BRANCH" "$WORKTREE" "$TEST_DB" "$NOW" "${PACKAGES[@]}" <<'PY'
import json, os, sys
claim, slug, brief, branch, wt, db, now, *pkgs = sys.argv[1:]
json.dump({
    "slug": slug, "feature": brief, "branch": branch, "worktree": wt,
    "port_base": int(os.environ.get("PORT_BASE", "0")) or None,
    "test_db": db, "packages": pkgs, "tmux_session": f"pm-{slug}",
    "started": now, "heartbeat": now, "status": "RUNNING",
}, open(claim, "w"), indent=2)
open(claim, "a").write("\n")
PY

# ---------------------------------------------------------------------------
# 9. Verify, loudly. Silent half-provisioning is the documented failure here.
# ---------------------------------------------------------------------------
echo
say "verification"
FAIL=0
check() { if eval "$2"; then printf '     ok    %s\n' "$1"; else printf '\033[31m     FAIL  %s\033[0m\n' "$1"; FAIL=$((FAIL+1)); fi; }

check "worktree exists"        "[ -d '$WORKTREE/.git' ] || [ -f '$WORKTREE/.git' ]"
check "on branch $BRANCH"      "[ \"\$(git -C '$WORKTREE' rev-parse --abbrev-ref HEAD)\" = '$BRANCH' ]"
check "api/.env present"       "[ -f '$WORKTREE/api/.env' ]"
check "TEST_MONGODB_URI set"   "grep -q 'TEST_MONGODB_URI=mongodb://localhost/$TEST_DB' '$WORKTREE/api/.env'"
check "dev DB isolated"        "grep -q 'MONGODB_URI=\"mongodb://localhost:27017/${TEST_DB}_dev\"' '$WORKTREE/api/.env'"
check "LEDGER.md present"      "[ -f '$WORKTREE/LEDGER.md' ]"
check "registry claim written" "[ -s '$CLAIM' ]"
for pkg in "${PACKAGES[@]}"; do
  case "$pkg" in root) d="$WORKTREE" ;; *) d="$WORKTREE/$pkg" ;; esac
  check "$pkg node_modules"    "[ -d '$d/node_modules' ]"
done

echo
if [ "$FAIL" -ne 0 ]; then
  die "$FAIL check(s) failed. Do NOT launch this PM until they pass."
fi
[ "$MISSING_ENV" -eq 0 ] || warn "$MISSING_ENV env file(s) were missing at source; frontend work may not run"

say "provisioned '$SLUG'"
printf '\n  next:  bash %s/pm-launch.sh %s\n\n' "$(dirname "$0")" "$SLUG"
