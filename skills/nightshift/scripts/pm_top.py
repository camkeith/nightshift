#!/usr/bin/env python3
"""pm-top — an interactive view of running nightshift PMs.

    ^/v      move            enter/->   open a PM
    tab      switch pane     <-/esc     back
    r        refresh         q          quit

Three panes per PM:

    LEDGER   status, blockers, decisions, wake log. The PM's own account of itself.
    WORKERS  subagents this PM dispatched, newest first, with their last line.
    OUTPUT   the live tmux pane if it is running, else the last wake's result text.

Everything here is read-only. It never writes to a ledger, a registry, or a worktree,
because a PM's ledger is its memory and an observer that mutates it is an injection
surface. See references/ledger-schema.md.
"""

import curses
import glob
import json
import os
import re
import subprocess
import time

HOME = os.path.expanduser("~")
PROJECTS = os.path.join(HOME, ".claude", "projects")
REFRESH_SECS = 5


# ---------------------------------------------------------------- data


def session_dir_for(worktree):
    """Claude stores a session under ~/.claude/projects/<path with non-alnum -> ->."""
    return os.path.join(PROJECTS, re.sub(r"[^A-Za-z0-9]", "-", worktree))


def read_ledger(worktree):
    try:
        return open(os.path.join(worktree, "LEDGER.md")).read()
    except Exception:
        return ""


def section(text, header, open_only=False):
    m = re.search(rf"^## {header}\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
    if not m:
        return []
    body = m.group(1)
    if open_only:
        return [l.rstrip() for l in body.splitlines() if l.strip().startswith("- [ ]")]
    return [l.rstrip() for l in body.splitlines()
            if l.strip().startswith(("- [", "- ")) and "(none)" not in l]


def age(ts):
    try:
        t = time.mktime(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")) - time.timezone
    except Exception:
        return "?"
    s = time.time() - t
    if s < 90:
        return f"{int(s)}s"
    if s < 5400:
        return f"{int(s // 60)}m"
    if s < 172800:
        return f"{int(s // 3600)}h"
    return f"{int(s // 86400)}d"


def tmux_alive(session):
    try:
        out = subprocess.run(["tmux", "list-sessions", "-F", "#S"],
                             capture_output=True, text=True, timeout=3).stdout
        return session in out.split()
    except Exception:
        return None            # unknown, not dead. Sandboxes deny the tmux socket.


def load_pms(repo):
    reg = os.path.join(repo, ".claude", "worktrees", "registry")
    pms = []
    for p in sorted(glob.glob(os.path.join(reg, "*.json"))):
        try:
            d = json.load(open(p))
        except Exception:
            continue
        wt = d.get("worktree", "")
        led = read_ledger(wt)
        m = re.search(r"^STATUS:\s*(\S+)", led, re.M)
        d["_ledger_status"] = m.group(1) if m else (d.get("status") or "?")
        d["_ledger"] = led
        d["_blockers"] = section(led, "BLOCKERS", True)
        d["_qa"] = section(led, "NEEDS-HUMAN-QA", True)
        d["_decisions"] = section(led, "DECISIONS")
        d["_wakelog"] = section(led, "WAKE LOG")
        d["_exists"] = bool(wt) and os.path.isdir(wt)
        pms.append(d)
    # anything wanting a human first, then trouble, then the rest
    def rank(d):
        if d["_ledger_status"] == "READY-FOR-HUMAN":
            return 0
        if (d.get("status") or "").upper() == "CRASHED":
            return 1
        if d["_ledger_status"] in ("DONE", "STOPPED"):
            return 3
        return 2
    pms.sort(key=rank)
    return pms


def workers_for(pm):
    """Subagent transcripts this PM dispatched, newest first."""
    sd = session_dir_for(pm.get("worktree", ""))
    out = []
    for f in glob.glob(os.path.join(sd, "**", "subagents", "*.jsonl"), recursive=True):
        try:
            st = os.stat(f)
        except Exception:
            continue
        out.append((st.st_mtime, st.st_size, f))
    out.sort(reverse=True)
    return out


def last_line_of(path, limit=400):
    """Final assistant text in a transcript, without loading the whole file."""
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            end = fh.tell()
            fh.seek(max(0, end - 60000))
            tail = fh.read().decode("utf-8", "replace").splitlines()
        for line in reversed(tail):
            try:
                o = json.loads(line)
            except Exception:
                continue
            c = (o.get("message") or {}).get("content")
            if isinstance(c, str) and c.strip():
                return c.strip()[:limit]
            if isinstance(c, list):
                for b in c:
                    if isinstance(b, dict) and b.get("type") == "text" and b.get("text", "").strip():
                        return b["text"].strip()[:limit]
    except Exception:
        pass
    return "(no text yet)"


def output_for(pm):
    """Live tmux pane if running, else the last wake's own result text."""
    sess = pm.get("tmux_session") or f"pm-{pm.get('slug')}"
    try:
        r = subprocess.run(["tmux", "capture-pane", "-p", "-t", sess],
                           capture_output=True, text=True, timeout=3)
        if r.returncode == 0 and r.stdout.strip():
            return ["[live tmux pane]", ""] + r.stdout.splitlines()[-200:]
    except Exception:
        pass
    wj = os.path.join(pm.get("worktree", ""), ".nightshift-wake.json")
    try:
        d = json.load(open(wj))
        res = next(o for o in d if o.get("type") == "result")
        head = [f"[last wake]  ${float(res.get('total_cost_usd') or 0):.2f}  "
                f"{res.get('num_turns')} turns  {int((res.get('duration_ms') or 0)/1000)}s", ""]
        return head + (res.get("result") or "").splitlines()
    except Exception:
        return ["(no tmux pane and no recorded wake output yet)"]


# ---------------------------------------------------------------- ui


def draw(stdscr, state):
    stdscr.erase()
    h, w = stdscr.getmaxyx()
    pms, sel, view, pane, scroll = (state[k] for k in
                                    ("pms", "sel", "view", "pane", "scroll"))

    A_DIM, A_B = curses.A_DIM, curses.A_BOLD
    def C(n): return curses.color_pair(n)

    if not pms:
        stdscr.addstr(0, 0, "no PMs provisioned in this repo", A_DIM)
        stdscr.addstr(2, 0, "q to quit", A_DIM)
        stdscr.refresh()
        return

    if view == "list":
        stdscr.addstr(0, 0, f"nightshift  {len(pms)} PM(s)".ljust(w - 1)[:w - 1], A_B)
        stdscr.addstr(1, 0, "^/v select   enter open   r refresh   q quit"[:w - 1], A_DIM)
        row = 3
        for i, p in enumerate(pms):
            if row >= h - 1:
                break
            st = p["_ledger_status"]
            if st == "READY-FOR-HUMAN":
                tag, col = "NEEDS YOU", 2
            elif (p.get("status") or "").upper() == "CRASHED":
                tag, col = "CRASHED", 1
            elif st == "DONE":
                tag, col = "DONE", 3
            elif not p["_exists"]:
                tag, col = "NO WORKTREE", 1
            else:
                tag, col = "running", 4
            mark = "> " if i == sel else "  "
            cost = p.get("cost_usd")
            meta = f"{age(p.get('heartbeat','')):>4}  {p.get('wakes',0):>3}w"
            if cost:
                meta += f"  ${cost:.2f}"
            line = f"{mark}{p.get('slug','?'):<18}{tag:<12}{meta}"
            stdscr.addstr(row, 0, line[:w - 1],
                          (A_B if i == sel else 0) | C(col))
            row += 1
            feat = (p.get("feature") or "")[:w - 6]
            if feat:
                stdscr.addstr(row, 4, feat, A_DIM)
                row += 1
            bits = []
            if p["_blockers"]:
                bits.append(f"{len(p['_blockers'])} blocker(s)")
            if p["_qa"]:
                bits.append(f"{len(p['_qa'])} need QA")
            if bits:
                stdscr.addstr(row, 4, " · ".join(bits)[:w - 6], C(2))
                row += 1
            row += 1
        stdscr.refresh()
        return

    # ---- detail ----
    p = pms[sel]
    panes = ["LEDGER", "WORKERS", "OUTPUT"]
    stdscr.addstr(0, 0, f"{p.get('slug','?')}  {p['_ledger_status']}".ljust(w - 1)[:w - 1], A_B)
    tabs = "  ".join(f"[{n}]" if i == pane else f" {n} " for i, n in enumerate(panes))
    stdscr.addstr(1, 0, tabs[:w - 1], A_DIM)
    stdscr.addstr(2, 0, "tab pane   ^/v scroll   <-/esc back   q quit"[:w - 1], A_DIM)

    if pane == 0:
        body = []
        for head, items, colr in (("BLOCKERS", p["_blockers"], 2),
                                  ("NEEDS-HUMAN-QA", p["_qa"], 2),
                                  ("DECISIONS", p["_decisions"], 0),
                                  ("WAKE LOG", p["_wakelog"], 0)):
            body.append((head, A_B, 0))
            body += [("  " + i.lstrip("- ").strip(), 0, colr) for i in items] or [("  (none)", A_DIM, 0)]
            body.append(("", 0, 0))
    elif pane == 1:
        ws = workers_for(p)
        if not ws:
            body = [("no workers dispatched yet", A_DIM, 0),
                    ("", 0, 0),
                    ("A PM only spawns subagents once it starts implementing.", A_DIM, 0)]
        else:
            body = [(f"{len(ws)} worker transcript(s), newest first", A_B, 0), ("", 0, 0)]
            for mt, sz, f in ws[:40]:
                body.append((f"{time.strftime('%H:%M:%S', time.localtime(mt))}  "
                             f"{sz//1024:>5}K  {os.path.basename(f)[:40]}", A_B, 0))
                body.append(("    " + last_line_of(f, 300).replace("\n", " ")[:w - 8], A_DIM, 0))
                body.append(("", 0, 0))
    else:
        body = [(l, 0, 0) for l in output_for(p)]

    view_h = h - 4
    scroll = max(0, min(scroll, max(0, len(body) - view_h)))
    state["scroll"] = scroll
    for i, item in enumerate(body[scroll:scroll + view_h]):
        text, attr, colr = item
        try:
            stdscr.addstr(4 + i, 0, text[:w - 1], attr | C(colr))
        except curses.error:
            pass
    stdscr.refresh()


def main(stdscr, repo):
    curses.curs_set(0)
    stdscr.nodelay(True)
    curses.start_color()
    curses.use_default_colors()
    for i, c in enumerate((curses.COLOR_RED, curses.COLOR_YELLOW,
                           curses.COLOR_GREEN, curses.COLOR_CYAN), start=1):
        curses.init_pair(i, c, -1)

    state = {"pms": load_pms(repo), "sel": 0, "view": "list", "pane": 0,
             "scroll": 0, "last": 0.0}

    while True:
        if time.time() - state["last"] > REFRESH_SECS:
            state["pms"] = load_pms(repo)
            state["last"] = time.time()
            if state["sel"] >= len(state["pms"]):
                state["sel"] = max(0, len(state["pms"]) - 1)

        draw(stdscr, state)
        try:
            k = stdscr.getch()
        except Exception:
            k = -1
        if k == -1:
            time.sleep(0.08)
            continue

        if k in (ord("q"), ord("Q")):
            return
        if k in (ord("r"), ord("R")):
            state["last"] = 0
        elif state["view"] == "list":
            if k in (curses.KEY_DOWN, ord("j")):
                state["sel"] = min(state["sel"] + 1, max(0, len(state["pms"]) - 1))
            elif k in (curses.KEY_UP, ord("k")):
                state["sel"] = max(state["sel"] - 1, 0)
            elif k in (curses.KEY_RIGHT, curses.KEY_ENTER, 10, 13):
                if state["pms"]:
                    state["view"], state["pane"], state["scroll"] = "detail", 0, 0
        else:
            if k in (27, curses.KEY_LEFT):
                state["view"], state["scroll"] = "list", 0
            elif k == 9:
                state["pane"] = (state["pane"] + 1) % 3
                state["scroll"] = 0
            elif k in (curses.KEY_DOWN, ord("j")):
                state["scroll"] += 1
            elif k in (curses.KEY_UP, ord("k")):
                state["scroll"] = max(0, state["scroll"] - 1)
            elif k == curses.KEY_NPAGE:
                state["scroll"] += 20
            elif k == curses.KEY_PPAGE:
                state["scroll"] = max(0, state["scroll"] - 20)


if __name__ == "__main__":
    import sys
    repo = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    try:
        curses.wrapper(main, repo)
    except KeyboardInterrupt:
        pass
