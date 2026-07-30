#!/usr/bin/env bash
# pm-config.sh — derive this repo's nightshift config from evidence, never from guesses.
#
# Usage:
#   pm-config.sh derive     inspect the repo and write .nightshift/config.json as a PROPOSAL
#   pm-config.sh show       print the active config
#   pm-config.sh validate   exit 0 if the config exists and is confirmed, non-zero otherwise
#
# WHY THIS EXISTS:
#   pm-provision.sh used to carry a hand-edited PER-REPO CONFIG block: base branch, the
#   gitignored env files a fresh worktree does not inherit, valid package names. Editing
#   a shell script per repo is the main thing that stopped nightshift being portable.
#
# WHY IT PROPOSES RATHER THAN APPLIES:
#   Getting the env-file list wrong produces a worktree that looks completely fine and
#   cannot run anything, which is worse than asking. So derivation writes a file marked
#   "confirmed": false, provisioning refuses to run against it, and a human flips the
#   flag after reading. One-time cost per repo, paid where someone is watching.
#
# EVERY FIELD IS DERIVED FROM SOMETHING CHECKABLE:
#   env_files   files that EXIST locally and are IGNORED by git. That is precisely the
#               set a fresh worktree will not have. Not a pattern match on names.
#   packages    directories containing a package.json, excluding node_modules.
#   frontends   vite config files actually present in those packages.
#   base_branch the branch this repo is on, unless a conventional staging branch exists.
#   db prefixes read out of the test files' own connection-string defaults.

set -uo pipefail

REPO="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$REPO" ] || { echo "error: not inside a git repository." >&2; exit 1; }
CFG="$REPO/.nightshift/config.json"

say()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }

cmd="${1:-show}"

if [ "$cmd" = "show" ]; then
  [ -f "$CFG" ] && cat "$CFG" || echo "no config at $CFG (run: pm-config.sh derive)"
  exit 0
fi

if [ "$cmd" = "validate" ]; then
  [ -f "$CFG" ] || { echo "missing $CFG — run: pm-config.sh derive" >&2; exit 1; }
  python3 -c "
import json,sys
d=json.load(open('$CFG'))
if not d.get('confirmed'):
    sys.stderr.write('$CFG is not confirmed.\n')
    sys.stderr.write('A human must read it and set \"confirmed\": true.\n')
    sys.stderr.write('Getting env_files wrong yields a worktree that looks fine and cannot run.\n')
    sys.exit(1)
for k in ('base_branch','env_files','packages'):
    if k not in d:
        sys.stderr.write(f'missing required key: {k}\n'); sys.exit(1)
" || exit 1
  exit 0
fi

[ "$cmd" = "derive" ] || { echo "usage: pm-config.sh [derive|show|validate]" >&2; exit 1; }

say "deriving nightshift config for $(basename "$REPO")"
mkdir -p "$REPO/.nightshift"

REPO="$REPO" CFG="$CFG" python3 <<'PY'
import json, os, re, subprocess, sys

repo = os.environ["REPO"]
cfg  = os.environ["CFG"]

def sh(*a):
    try:
        return subprocess.run(a, cwd=repo, capture_output=True, text=True, timeout=60).stdout
    except Exception:
        return ""

# --- env files: EXIST locally AND ignored by git. Exactly what a worktree will lack. ---
ignored = sh("git", "status", "--ignored=matching", "--porcelain").splitlines()
env_files = sorted({
    line[3:].strip() for line in ignored
    if line.startswith("!!") and re.search(r"(^|/)\.env(\.|$)", line[3:].strip())
       and os.path.isfile(os.path.join(repo, line[3:].strip()))
})

# --- packages: directories with a package.json (depth 2), node_modules excluded ---
packages = []
if os.path.isfile(os.path.join(repo, "package.json")):
    packages.append("root")
for name in sorted(os.listdir(repo)):
    p = os.path.join(repo, name)
    if name.startswith(".") or name == "node_modules" or not os.path.isdir(p):
        continue
    if os.path.isfile(os.path.join(p, "package.json")):
        packages.append(name)

# --- frontends: vite configs actually present ---
frontends = []
for pkg in packages:
    d = repo if pkg == "root" else os.path.join(repo, pkg)
    for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if re.fullmatch(r"vite(\.[a-z0-9-]+)?\.config\.(js|ts|mjs)", f):
            frontends.append({"package": pkg, "vite_config": f})

# --- base branch: prefer a conventional staging branch that actually exists ---
branches = {b.strip().lstrip("* ").strip() for b in sh("git", "branch", "--format=%(refname:short)").splitlines()}
current  = sh("git", "rev-parse", "--abbrev-ref", "HEAD").strip()
base = next((b for b in ("develop", "development", "staging") if b in branches), current or "main")

# --- db prefixes: read the test files' own defaults rather than inventing a name ---
def find_db_names():
    """All localhost DB names appearing in source, in order."""
    out = sh("git", "grep", "-hoE", r"mongodb://localhost[:0-9]*/[A-Za-z0-9_-]+", "--", "*.js", "*.ts")
    return re.findall(r"localhost[:/][0-9]*/?([A-Za-z0-9_-]+)", out)

# Prefer a name that looks like a TEST database. Taking the first match blindly picks up
# the dev connection string, which appears earlier in most repos, and would then have
# every PM's "isolated" test DB named after the shared dev one. Caught on the first real
# derivation: it returned coffee_chats (dev) rather than coffeechats_test.
names = find_db_names()
test_db = next((n for n in names if "test" in n.lower()), None) \
       or (names[0] + "_test" if names else os.path.basename(repo) + "_test")
test_db = re.sub(r"[^A-Za-z0-9_]", "_", test_db)

conf = {
    "_comment": "Derived by pm-config.sh from evidence in this repo. READ IT, then set confirmed: true.",
    "confirmed": False,
    "base_branch": base,
    "env_files": env_files,
    "packages": packages,
    "frontends": frontends,
    "test_db_prefix": test_db,
    "port_base_start": 9200,
    "_derivation": {
        "env_files": "files that exist locally AND are git-ignored (git status --ignored)",
        "packages": "directories containing package.json, node_modules excluded",
        "frontends": "vite*.config.* files present in those packages",
        "base_branch": f"conventional staging branch if present, else current branch ({current})",
        "test_db_prefix": "first localhost DB name containing 'test'; else the first name + _test",
    },
}
json.dump(conf, open(cfg, "w"), indent=2)
open(cfg, "a").write("\n")

print(f"\n  base_branch : {base}")
print(f"  packages    : {', '.join(packages) or '(none found)'}")
print(f"  env_files   : {len(env_files)} found")
for e in env_files:
    print(f"                {e}")
print(f"  frontends   : {len(frontends)}")
for f in frontends:
    print(f"                {f['package']}/{f['vite_config']}")
print(f"  test_db     : {test_db}_<slug>")
if not env_files:
    print("\n  NOTE: no gitignored .env files found. If this repo needs any, add them by hand;")
    print("        a missing one produces a worktree that looks fine and cannot run.")
PY

cat <<EOF

  Written to $CFG marked "confirmed": false.

  Read it. The list that matters is env_files: a missing entry produces a worktree that
  looks completely fine and cannot run anything, and you will not find out until a PM is
  three hours into a feature.

  Then set "confirmed": true and provisioning will proceed.

EOF
