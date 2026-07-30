#!/usr/bin/env bash
# pm-version.sh — report the installed nightshift version, and whether it is behind.
#
# Usage:
#   pm-version.sh sha      print the installed commit SHA (for pinning). Empty if unknown.
#   pm-version.sh check    tell the human if an update exists. Throttled, silent on failure.
#   pm-version.sh drift <pinned-sha>   report whether the plugin moved since that SHA.
#
# WHY THIS NEVER AUTO-UPDATES:
#
#   Tools that reload on every session can safely self-update, because a human is
#   sitting there and notices a bad update in seconds. A nightshift PM wakes 24+ times
#   across days with nobody watching. An update landing between wake 4 and wake 5 means
#   the PM follows different rules mid-feature, and a broken one runs until morning.
#
#   The whole design rests on behavior being predictable across wakes, so:
#
#     - `check` runs at KICKOFF only, where a human can see it, and never pulls.
#     - `pm-provision.sh` pins the SHA into the registry. Every wake of that PM uses the
#       version it started with. New PMs pick up the update; running ones do not.
#     - `pm-teardown.sh` reports drift, which explains behavior differences between an
#       old PM and a new one.
#
#   Also: `claude` autoupdate already restarts the binary and kills running loops. A
#   second self-modifying part pointed the same way compounds a known problem.
#
# EVERYTHING HERE IS BEST-EFFORT. `git fetch` over SSH fails inside a sandbox
# ("nc: authentication method negotiation failed") and .git/config writes are denied.
# A version check that can stall a 3am run is worse than no version check, so every
# path exits 0 and says nothing useful rather than blocking.

set -uo pipefail   # deliberately not -e: this script must never abort its caller

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
THROTTLE_SECS="${PM_VERSION_THROTTLE:-3600}"

# The plugin is a git repo only when installed from one. A hand-copied skill directory
# is not, and that is fine: report nothing rather than inventing a version.
PLUGIN_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"

cmd="${1:-check}"

# ---------------------------------------------------------------------------
# sha — what is installed right now
# ---------------------------------------------------------------------------
if [ "$cmd" = "sha" ]; then
  [ -n "$PLUGIN_ROOT" ] && git -C "$PLUGIN_ROOT" rev-parse --short HEAD 2>/dev/null || true
  exit 0
fi

# ---------------------------------------------------------------------------
# drift — did the plugin move while a PM was running?
# ---------------------------------------------------------------------------
if [ "$cmd" = "drift" ]; then
  PINNED="${2:-}"
  [ -n "$PLUGIN_ROOT" ] && [ -n "$PINNED" ] || exit 0
  NOW="$(git -C "$PLUGIN_ROOT" rev-parse --short HEAD 2>/dev/null || true)"
  [ -n "$NOW" ] || exit 0
  if [ "$NOW" != "$PINNED" ]; then
    N=$(git -C "$PLUGIN_ROOT" rev-list --count "$PINNED..HEAD" 2>/dev/null || echo "?")
    printf '\033[33mnote:\033[0m nightshift moved during this run: %s -> %s (%s commit(s)).\n' \
      "$PINNED" "$NOW" "$N"
    printf '      This PM ran on %s. A new PM would behave differently.\n' "$PINNED"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# check — is an update available? Tell, never pull.
# ---------------------------------------------------------------------------
[ -n "$PLUGIN_ROOT" ] || exit 0

STAMP="$PLUGIN_ROOT/.nightshift-version-check"
if [ -f "$STAMP" ]; then
  AGE=$(( $(date +%s) - $(stat -f %m "$STAMP" 2>/dev/null || stat -c %Y "$STAMP" 2>/dev/null || echo 0) ))
  [ "$AGE" -lt "$THROTTLE_SECS" ] && exit 0
fi
touch "$STAMP" 2>/dev/null || true

# Best-effort and quiet. Failure here is expected inside a sandbox and means nothing.
git -C "$PLUGIN_ROOT" fetch --quiet origin 2>/dev/null || exit 0

BEHIND=$(git -C "$PLUGIN_ROOT" rev-list --count HEAD..origin/HEAD 2>/dev/null \
      || git -C "$PLUGIN_ROOT" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
[ "${BEHIND:-0}" -gt 0 ] 2>/dev/null || exit 0

LOCAL="$(git -C "$PLUGIN_ROOT" rev-parse --short HEAD 2>/dev/null)"
printf '\n\033[36mnightshift:\033[0m %s update(s) available (installed %s)\n' "$BEHIND" "$LOCAL"
git -C "$PLUGIN_ROOT" log --oneline "HEAD..origin/main" 2>/dev/null | head -5 | sed 's/^/    /'
cat <<EOF

    Not applied. Updating mid-flight would change the rules a running PM follows
    between wakes, so nightshift never updates itself. To take it:

      cd "$PLUGIN_ROOT" && git pull

    Running PMs keep the version they were provisioned with either way.

EOF
exit 0
