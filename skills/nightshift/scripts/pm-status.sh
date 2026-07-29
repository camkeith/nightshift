#!/usr/bin/env bash
# pm-status.sh — every PM, its state, and what it needs from you, on one screen.
#
# This is the breakfast view. It answers, in order: is anything waiting on me, is
# anything dead, and did anything actually get done.
#
# Usage: pm-status.sh [slug]     (no arg = all PMs)

set -euo pipefail
# Resolve the repo from the current git worktree rather than pinning a path, so this
# works in any checkout. Run these scripts from inside the repo you want a PM to work on.
REPO="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$REPO" ] || { echo "error: not inside a git repository. cd into your repo first." >&2; exit 1; }
REGISTRY="$REPO/.claude/worktrees/registry"   # see pm-provision.sh for why it lives here
[ -d "$REGISTRY" ] || { echo "no PMs have ever been provisioned."; exit 0; }

FILTER="${1:-}"

# tmux session list up front so the renderer can tell a live PM from a stale record.
#
# Distinguish "tmux says there are no sessions" from "tmux was unreachable". Inside a
# sandbox the socket is denied outright:
#     error connecting to /private/tmp/tmux-501/default (Operation not permitted)
# A bare `|| true` swallows that and yields an empty list, so EVERY PM renders as
# NOT RUNNING whether or not it is alive. That is the same fail-closed-in-the-wrong-
# direction bug as the heartbeat one: a liveness check that reports healthy things dead
# invites you to restart a live PM onto its own branch.
if TMUX_SESSIONS=$(tmux list-sessions -F '#S' 2>/dev/null); then
  TMUX_OK=1
else
  TMUX_SESSIONS=""
  # No sessions at all also exits non-zero, so tell the two apart by re-running for stderr.
  if tmux list-sessions 2>&1 | grep -qi "no server running\|no sessions"; then
    TMUX_OK=1          # tmux answered honestly: nothing is running
  else
    TMUX_OK=0          # tmux could not be reached; liveness is UNKNOWN, not dead
  fi
fi

REGISTRY="$REGISTRY" FILTER="$FILTER" TMUX_SESSIONS="$TMUX_SESSIONS" TMUX_OK="$TMUX_OK" python3 <<'PY'
import json, os, re, glob, datetime

reg = os.environ["REGISTRY"]
filt = os.environ.get("FILTER") or None
live = set(filter(None, os.environ.get("TMUX_SESSIONS", "").split("\n")))
# False when tmux could not be reached at all (sandboxed: socket denied). In that case we
# know nothing about liveness, and must say so rather than claim everything is dead.
tmux_ok = os.environ.get("TMUX_OK") == "1"

C = {"r": "\033[31m", "y": "\033[33m", "g": "\033[32m", "c": "\033[36m",
     "d": "\033[2m", "b": "\033[1m", "x": "\033[0m"}

def age(ts):
    try:
        t = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except Exception:
        return None, "?"
    secs = (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds()
    if secs < 90:      return secs, f"{int(secs)}s ago"
    if secs < 5400:    return secs, f"{int(secs//60)}m ago"
    if secs < 172800:  return secs, f"{int(secs//3600)}h ago"
    return secs, f"{int(secs//86400)}d ago"

def section(text, header, open_only=False):
    """Pull the bullet items out of one '## HEADER' block of the ledger.

    open_only=True keeps just unchecked `- [ ]` boxes. Without it, a resolved blocker
    marked `- [x]` still renders as "blocked on 2", which is worse than cosmetic: the
    breakfast view exists to show what is actually waiting on you, and a checked box
    shown as blocking teaches you to stop trusting the count.
    """
    m = re.search(rf"^## {header}\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
    if not m:
        return []
    body = m.group(1)
    if open_only:
        return [l.rstrip() for l in body.splitlines() if l.strip().startswith("- [ ]")]
    return [l.rstrip() for l in body.splitlines()
            if l.strip().startswith(("- [", "- ")) and "(none)" not in l]

records = []
for path in sorted(glob.glob(os.path.join(reg, "*.json"))):
    try:
        d = json.load(open(path))
    except Exception:
        continue
    if filt and d.get("slug") != filt:
        continue
    wt = d.get("worktree", "")
    ledger = os.path.join(wt, "LEDGER.md")
    text = open(ledger).read() if os.path.isfile(ledger) else ""
    st = re.search(r"^STATUS:\s*(\S+)", text, re.M)
    wake = [l for l in text.splitlines() if l.strip().startswith("- ")]
    d["_ledger_status"] = st.group(1) if st else d.get("status", "?")
    d["_blockers"] = section(text, "BLOCKERS", open_only=True)
    d["_qa"] = section(text, "NEEDS-HUMAN-QA", open_only=True)
    d["_decisions"] = section(text, "DECISIONS")
    wl = section(text, "WAKE LOG")
    d["_last"] = wl[-1].lstrip("- ") if wl else "(no wakes recorded)"
    d["_alive"] = d.get("tmux_session") in live
    records.append(d)

if not records:
    print("no PMs found." if not filt else f"no PM named '{filt}'.")
    raise SystemExit(0)

# Waiting-on-you first, then dead, then running. The whole point is that the things
# needing action are never below the fold.
def rank(d):
    s = d["_ledger_status"]
    if s == "READY-FOR-HUMAN": return 0
    if d.get("status") == "CRASHED": return 1
    if not d["_alive"] and s not in ("DONE", "STOPPED"): return 2
    if s == "DONE": return 4
    return 3
records.sort(key=rank)

print()
for d in records:
    secs, ago = age(d.get("heartbeat", ""))
    s = d["_ledger_status"]

    if s == "READY-FOR-HUMAN":                    tag, col = "NEEDS YOU", C["y"]
    elif d.get("status") == "CRASHED":            tag, col = "CRASHED",   C["r"]
    elif s == "DONE":                             tag, col = "DONE",      C["g"]
    elif s == "STOPPED":                          tag, col = "STOPPED",   C["d"]
    elif not tmux_ok:                             tag, col = "liveness ?", C["d"]
    elif not d["_alive"]:                         tag, col = "NOT RUNNING", C["r"]
    elif secs is not None and secs > 7200:        tag, col = "STALLED?",  C["r"]
    else:                                         tag, col = "running",   C["c"]

    print(f"{col}{C['b']}{d['slug']:<16}{tag:<12}{C['x']}{C['d']}{ago:>10}{C['x']}  {d.get('feature','')}")
    print(f"{C['d']}{'':<16}{d.get('branch','?')}{C['x']}")

    if d["_blockers"]:
        print(f"  {C['y']}blocked on {len(d['_blockers'])}:{C['x']}")
        for b in d["_blockers"][:4]:
            print(f"    {b.strip()}")
    if d["_qa"]:
        print(f"  {C['y']}needs your QA ({len(d['_qa'])}):{C['x']}")
        for q in d["_qa"][:3]:
            print(f"    {q.strip()}")
    if d["_decisions"]:
        print(f"  {C['d']}{len(d['_decisions'])} decision(s) logged{C['x']}")
    print(f"  {C['d']}last: {d['_last']}{C['x']}")
    print()

if not tmux_ok:
    print(f"{C['d']}tmux was unreachable (sandboxed?), so liveness is unknown for every PM.{C['x']}")
    print(f"{C['d']}Run this from a real terminal for accurate running/dead state.{C['x']}\n")

needs = [d for d in records if d["_ledger_status"] == "READY-FOR-HUMAN"]
dead  = [d for d in records if d.get("status") == "CRASHED"
         or (tmux_ok and not d["_alive"]
             and d["_ledger_status"] not in ("DONE", "STOPPED", "READY-FOR-HUMAN"))]
if needs:
    print(f"{C['y']}{len(needs)} PM(s) waiting on you: {', '.join(d['slug'] for d in needs)}{C['x']}")
if dead:
    print(f"{C['r']}{len(dead)} PM(s) not running: {', '.join(d['slug'] for d in dead)}{C['x']}")
    print(f"{C['d']}  restart:  bash ~/.claude/skills/nightshift/scripts/pm-launch.sh <slug>{C['x']}")
    print(f"{C['d']}            (from a real terminal, not inside a Claude session){C['x']}")
if not needs and not dead:
    print(f"{C['g']}all PMs healthy.{C['x']}")
print()
PY
