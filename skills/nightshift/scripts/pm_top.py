#!/usr/bin/env python3
"""pm-top — live view of nightshift PMs, their workers, and their output.

Layout is a split: PM list on the left, detail on the right, aggregate header on top.

    ^/v  select        tab   cycle pane      enter  focus detail
    i    message PM    a     attach (tmux)   w      wake now
    s    stop PM       r     refresh         q      quit

WHAT IT WILL AND WILL NOT WRITE

It writes to exactly one thing: `INBOX.md`, and only when you press `i`. That file is
designed to receive outside input; the PM reads it each wake and treats every entry as a
claim to verify, not an instruction.

It never writes LEDGER.md, the registry, or any source file. The ledger is the PM's
memory and the first thing it reads on every wake, so anything that can write there can
steer days of unattended work. See references/ledger-schema.md.

WHY YOU CANNOT TYPE INTO A PM

Each wake is a fresh `claude -p`: prompt in, result out, exit. It is non-interactive by
construction, which is what makes "resume from files" true rather than aspirational. So
`a` attaches you to the supervisor's tmux pane where you can watch, and `i` is how you
actually say something the PM will act on.
"""

import curses
import glob
import json
import os
import re
import subprocess
import textwrap
import time

HOME = os.path.expanduser("~")
PROJECTS = os.path.join(HOME, ".claude", "projects")
REFRESH_SECS = 5
PANES = ("LEDGER", "WORKERS", "OUTPUT")

# colour pair ids
C_RED, C_AMBER, C_GREEN, C_CYAN, C_MUTED, C_HEAD = 1, 2, 3, 4, 5, 6


# ---------------------------------------------------------------- data

def session_dir_for(worktree):
    return os.path.join(PROJECTS, re.sub(r"[^A-Za-z0-9]", "-", worktree))


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
    s = max(0, time.time() - t)
    if s < 90:      return f"{int(s)}s"
    if s < 5400:    return f"{int(s//60)}m"
    if s < 172800:  return f"{int(s//3600)}h"
    return f"{int(s//86400)}d"



def _git(wt, *args, timeout=4):
    try:
        r = subprocess.run(["git", "-C", wt, *args], capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        return ""


def base_branch_for(repo):
    try:
        d = json.load(open(os.path.join(repo, ".nightshift", "config.json")))
        if d.get("base_branch"):
            return d["base_branch"]
    except Exception:
        pass
    return "develop"


def collect_stats(p, base):
    """Cheap per-PM facts for the header. Every call is bounded; failures render as '-'."""
    wt = p.get("worktree", "")
    if not wt or not os.path.isdir(wt):
        return

    # elapsed since provisioning
    try:
        t0 = time.mktime(time.strptime(p.get("started", ""), "%Y-%m-%dT%H:%M:%SZ")) - time.timezone
        s = max(0, time.time() - t0)
        p["_runtime"] = (f"{int(s//86400)}d {int((s%86400)//3600)}h" if s >= 86400
                         else f"{int(s//3600)}h {int((s%3600)//60)}m" if s >= 3600
                         else f"{int(s//60)}m")
    except Exception:
        p["_runtime"] = "-"

    # committed work vs the base branch, plus anything uncommitted
    ref = ""
    for cand in (f"origin/{base}", base, "origin/main", "main"):
        if _git(wt, "rev-parse", "--verify", "--quiet", cand):
            ref = cand
            break
    p["_commits"] = len([l for l in _git(wt, "log", "--oneline", f"{ref}..HEAD").splitlines() if l]) if ref else 0
    stat = _git(wt, "diff", "--shortstat", f"{ref}...HEAD") if ref else ""
    dirty = _git(wt, "diff", "--shortstat")
    files = ins = dele = 0
    for s_ in (stat, dirty):
        m = re.search(r"(\d+) files? changed", s_ or "");        files += int(m.group(1)) if m else 0
        m = re.search(r"(\d+) insertions?", s_ or "");            ins   += int(m.group(1)) if m else 0
        m = re.search(r"(\d+) deletions?", s_ or "");             dele  += int(m.group(1)) if m else 0
    p["_diff"] = (files, ins, dele)

    # OpenSpec task progress, if this PM was handed a change
    p["_tasks"] = None
    m = re.search(r"^OPENSPEC:\s*(\S+)", p.get("_ledgertext", ""), re.M)
    if m and m.group(1).startswith("openspec/"):
        tf = os.path.join(wt, m.group(1).rstrip("/"), "tasks.md")
        try:
            txt = open(tf).read()
            done = len(re.findall(r"^\s*- \[x\]", txt, re.M | re.I))
            tot = done + len(re.findall(r"^\s*- \[ \]", txt, re.M))
            p["_tasks"] = (done, tot)
        except Exception:
            pass


def load_pms(repo):
    reg = os.path.join(repo, ".claude", "worktrees", "registry")
    base = base_branch_for(repo)
    pms = []
    for p in sorted(glob.glob(os.path.join(reg, "*.json"))):
        try:
            d = json.load(open(p))
        except Exception:
            continue
        wt = d.get("worktree", "")
        try:
            led = open(os.path.join(wt, "LEDGER.md")).read()
        except Exception:
            led = ""
        m = re.search(r"^STATUS:\s*(\S+)", led, re.M)
        d["_status"] = m.group(1) if m else (d.get("status") or "?")
        d["_ledgertext"] = led
        d["_blockers"] = section(led, "BLOCKERS", True)
        d["_qa"] = section(led, "NEEDS-HUMAN-QA", True)
        d["_decisions"] = section(led, "DECISIONS")
        d["_wakelog"] = section(led, "WAKE LOG")
        d["_findings"] = section(led, "FINDINGS")
        d["_exists"] = bool(wt) and os.path.isdir(wt)
        try:
            ib = open(os.path.join(wt, "INBOX.md")).read()
            d["_inbox"] = len([l for l in ib.splitlines() if l.strip().startswith("- [ ]")])
        except Exception:
            d["_inbox"] = 0
        collect_stats(d, base)
        pms.append(d)

    def rank(d):
        if d["_status"] == "READY-FOR-HUMAN":            return 0
        if (d.get("status") or "").upper() == "CRASHED": return 1
        if d["_status"] in ("DONE", "STOPPED"):          return 3
        return 2
    pms.sort(key=rank)
    return pms


def badge(p):
    st = p["_status"]
    if st == "READY-FOR-HUMAN":                     return "NEEDS YOU", C_AMBER
    if (p.get("status") or "").upper() == "CRASHED": return "CRASHED", C_RED
    if st == "DONE":                                 return "DONE", C_GREEN
    if st == "STOPPED":                              return "STOPPED", C_MUTED
    if not p["_exists"]:                             return "NO TREE", C_RED
    return "running", C_CYAN


def workers_for(p):
    sd = session_dir_for(p.get("worktree", ""))
    out = []
    for f in glob.glob(os.path.join(sd, "**", "subagents", "*.jsonl"), recursive=True):
        try:
            st = os.stat(f)
        except Exception:
            continue
        out.append((st.st_mtime, st.st_size, f))
    out.sort(reverse=True)
    return out


def last_text(path, limit=500):
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            fh.seek(max(0, fh.tell() - 80000))
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


def tmux_session(p):
    return p.get("tmux_session") or f"pm-{p.get('slug')}"


def output_for(p):
    try:
        r = subprocess.run(["tmux", "capture-pane", "-p", "-t", tmux_session(p)],
                           capture_output=True, text=True, timeout=3)
        if r.returncode == 0 and r.stdout.strip():
            return ["live tmux pane", ""] + r.stdout.splitlines()[-300:]
    except Exception:
        pass
    try:
        d = json.load(open(os.path.join(p.get("worktree", ""), ".nightshift-wake.json")))
        res = next(o for o in d if o.get("type") == "result")
        return [f"last wake · ${float(res.get('total_cost_usd') or 0):.2f} · "
                f"{res.get('num_turns')} turns · {int((res.get('duration_ms') or 0)/1000)}s",
                ""] + (res.get("result") or "").splitlines()
    except Exception:
        return ["no live pane and no recorded wake output yet"]


# ---------------------------------------------------------------- actions

def append_inbox(p, msg):
    """The ONE thing this tool writes. Attributed, appended, never overwriting."""
    path = os.path.join(p.get("worktree", ""), "INBOX.md")
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    entry = f"\n- [ ] **{stamp} — from the human (via pm-top)**\n      {msg.strip()}\n"
    try:
        with open(path, "a") as f:
            f.write(entry)
        return True, "queued for the next wake"
    except Exception as e:
        return False, str(e)


def prompt(stdscr, label):
    h, w = stdscr.getmaxyx()
    curses.echo(); curses.curs_set(1); stdscr.nodelay(False)
    stdscr.addstr(h - 1, 0, " " * (w - 1))
    stdscr.addstr(h - 1, 0, label[: w - 2], curses.color_pair(C_AMBER) | curses.A_BOLD)
    try:
        s = stdscr.getstr(h - 1, len(label) + 1, w - len(label) - 3).decode("utf-8", "replace")
    except Exception:
        s = ""
    curses.noecho(); curses.curs_set(0); stdscr.nodelay(True)
    return s.strip()


def run_detached(args):
    try:
        subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except Exception:
        return False


# ---------------------------------------------------------------- drawing

def hline(scr, y, x, n, ch="─", attr=0):
    try:
        scr.addstr(y, x, ch * max(0, n), attr)
    except curses.error:
        pass


def put(scr, y, x, text, attr=0, maxw=None):
    if maxw is not None:
        text = text[:max(0, maxw)]
    try:
        scr.addstr(y, x, text, attr)
    except curses.error:
        pass


def wrap(items, width):
    out = []
    for text, attr, col in items:
        if not text:
            out.append(("", attr, col)); continue
        indent = len(text) - len(text.lstrip())
        for i, seg in enumerate(textwrap.wrap(text.strip(), max(10, width)) or [""]):
            out.append((" " * indent + ("" if i == 0 else "  ") + seg, attr, col))
    return out


def draw(stdscr, S):
    stdscr.erase()
    h, w = stdscr.getmaxyx()
    pms, sel, pane, scroll, focus = (S[k] for k in ("pms", "sel", "pane", "scroll", "focus"))
    C = curses.color_pair
    BOLD, DIM = curses.A_BOLD, curses.A_DIM

    # ---- header ----
    n_need = sum(1 for p in pms if p["_status"] == "READY-FOR-HUMAN")
    n_run = sum(1 for p in pms if badge(p)[0] == "running")
    cost = sum(float(p.get("cost_usd") or 0) for p in pms)
    title = "  nightshift"
    put(stdscr, 0, 0, title, C(C_HEAD) | BOLD)
    stats = f"{n_run} running"
    if n_need: stats += f"  ·  {n_need} need you"
    if cost:   stats += f"  ·  ${cost:.2f}"
    put(stdscr, 0, len(title) + 2, stats, C(C_MUTED))
    put(stdscr, 0, w - 10, S.get("flash", "")[:8], C(C_GREEN) | BOLD)
    hline(stdscr, 1, 0, w, "─", C(C_MUTED))

    if not pms:
        put(stdscr, 3, 2, "no PMs provisioned in this repo", DIM)
        put(stdscr, 5, 2, "q quit", DIM)
        stdscr.refresh(); return

    LW = max(26, min(38, w // 3))
    body_top, body_bot = 2, h - 2

    # ---- left: PM list ----
    y = body_top
    for i, p in enumerate(pms):
        if y >= body_bot - 1:
            break
        tag, col = badge(p)
        cur = i == sel
        marker = "▐" if cur else " "
        attr = (BOLD if cur else 0) | C(col)
        put(stdscr, y, 0, marker, C(C_CYAN) | BOLD if cur else 0)
        put(stdscr, y, 2, f"{p.get('slug','?')[:LW-12]:<{LW-12}}", attr)
        put(stdscr, y, LW - 9, f"{age(p.get('heartbeat','')):>4}", C(C_MUTED))
        y += 1
        put(stdscr, y, 2, tag, C(col))
        extra = []
        if p["_blockers"]: extra.append(f"!{len(p['_blockers'])}")
        if p["_qa"]:       extra.append(f"qa{len(p['_qa'])}")
        if p["_inbox"]:    extra.append(f"in{p['_inbox']}")
        if extra:
            put(stdscr, y, 2 + len(tag) + 1, " ".join(extra), C(C_AMBER))
        c = p.get("cost_usd")
        if c: put(stdscr, y, LW - 9, f"${c:>6.2f}", C(C_MUTED))
        y += 2

    for yy in range(body_top, body_bot):
        put(stdscr, yy, LW, "│", C(C_MUTED))

    # ---- right: detail ----
    p = pms[sel]
    RX = LW + 2
    RW = w - RX - 1
    tag, col = badge(p)
    put(stdscr, body_top, RX, p.get("slug", "?"), C(col) | BOLD)
    put(stdscr, body_top, RX + len(p.get("slug", "?")) + 2, tag, C(col))
    feat = (p.get("feature") or "")
    fy = body_top + 1
    if feat:
        put(stdscr, fy, RX, "goal", C(C_MUTED) | BOLD)
        for i, l in enumerate(textwrap.wrap(feat, RW - 6)[:3]):
            put(stdscr, fy + i, RX + 6, l, 0)
        fy += min(3, len(textwrap.wrap(feat, RW - 6)))

    # compact stat grid: two columns of label/value pairs
    files, ins, dele = p.get("_diff", (0, 0, 0))
    tasks = p.get("_tasks")
    left = [("running", p.get("_runtime", "-")),
            ("wakes", f"{p.get('wakes', 0)}"),
            ("spend", f"${float(p.get('cost_usd') or 0):.2f}")]
    right = [("branch", p.get("branch", "-")),
             ("commits", f"{p.get('_commits', 0)}"),
             ("diff", f"+{ins} -{dele} in {files}f" if files else "none yet")]
    if tasks:
        right.append(("tasks", f"{tasks[0]}/{tasks[1]}"))
    left.append(("workers", str(len(workers_for(p)))))
    if p.get("port_base"):
        left.append(("ports", f"{p['port_base']}+"))

    fy += 1
    colw = max(18, (RW - 2) // 2)
    for i in range(max(len(left), len(right))):
        if fy + i >= body_bot - 4:
            break
        if i < len(left):
            k, v = left[i]
            put(stdscr, fy + i, RX, f"{k:<8}", C(C_MUTED))
            put(stdscr, fy + i, RX + 8, v[:colw - 9], C(C_CYAN))
        if i < len(right):
            k, v = right[i]
            put(stdscr, fy + i, RX + colw, f"{k:<8}", C(C_MUTED))
            put(stdscr, fy + i, RX + colw + 8, v[:RW - colw - 9], C(C_CYAN))
    fy += max(len(left), len(right))

    ty = fy + 1
    x = RX
    for i, nm in enumerate(PANES):
        on = i == pane
        put(stdscr, ty, x, f" {nm} ", (C(C_CYAN) | BOLD) if on else C(C_MUTED))
        x += len(nm) + 3
    hline(stdscr, ty + 1, RX, RW, "─", C(C_MUTED))

    if pane == 0:
        items = []
        for head, vals, c in (("BLOCKERS", p["_blockers"], C_AMBER),
                              ("NEEDS-HUMAN-QA", p["_qa"], C_AMBER),
                              ("FINDINGS", p["_findings"], 0),
                              ("DECISIONS", p["_decisions"], 0),
                              ("WAKE LOG", p["_wakelog"], 0)):
            if not vals and head in ("FINDINGS",):
                continue
            items.append((head, BOLD, C_HEAD))
            items += [("  " + v.lstrip("- ").lstrip("[ ]x").strip(), 0, c) for v in vals] \
                     or [("  none", DIM, 0)]
            items.append(("", 0, 0))
    elif pane == 1:
        ws = workers_for(p)
        if not ws:
            items = [("no workers dispatched yet", DIM, 0), ("", 0, 0),
                     ("A PM spawns subagents once it starts implementing.", DIM, 0)]
        else:
            items = [(f"{len(ws)} worker(s), newest first", BOLD, C_HEAD), ("", 0, 0)]
            for mt, sz, f in ws[:30]:
                items.append((f"{time.strftime('%H:%M:%S', time.localtime(mt))}  "
                              f"{sz//1024:>5}K  {os.path.basename(f)[:34]}", BOLD, C_CYAN))
                items.append(("  " + last_text(f, 400).replace("\n", " "), 0, 0))
                items.append(("", 0, 0))
    else:
        items = [(l, 0, 0) for l in output_for(p)]

    wrapped = wrap(items, RW)
    view_h = body_bot - (ty + 2)
    scroll = max(0, min(scroll, max(0, len(wrapped) - view_h)))
    S["scroll"] = scroll
    for i, (text, attr, c) in enumerate(wrapped[scroll:scroll + view_h]):
        put(stdscr, ty + 2 + i, RX, text, attr | (C(c) if c else 0), RW)

    if len(wrapped) > view_h:
        pct = int(100 * scroll / max(1, len(wrapped) - view_h))
        put(stdscr, body_bot - 1, w - 6, f"{pct:>3}%", C(C_MUTED))

    # ---- footer ----
    hline(stdscr, h - 2, 0, w, "─", C(C_MUTED))
    keys = [("^/v", "select"), ("tab", "pane"), ("i", "message"),
            ("a", "attach"), ("w", "wake"), ("s", "stop"), ("q", "quit")]
    x = 1
    for k, lbl in keys:
        put(stdscr, h - 1, x, k, C(C_CYAN) | BOLD); x += len(k) + 1
        put(stdscr, h - 1, x, lbl, C(C_MUTED));     x += len(lbl) + 3
    stdscr.refresh()


# ---------------------------------------------------------------- main

def main(stdscr, repo, skill_dir):
    curses.curs_set(0)
    stdscr.nodelay(True)
    curses.start_color()
    curses.use_default_colors()
    for pid, c in ((C_RED, curses.COLOR_RED), (C_AMBER, curses.COLOR_YELLOW),
                   (C_GREEN, curses.COLOR_GREEN), (C_CYAN, curses.COLOR_CYAN),
                   (C_MUTED, 8), (C_HEAD, curses.COLOR_MAGENTA)):
        try:
            curses.init_pair(pid, c, -1)
        except Exception:
            curses.init_pair(pid, curses.COLOR_WHITE, -1)

    S = {"pms": load_pms(repo), "sel": 0, "pane": 0, "scroll": 0,
         "focus": "list", "last": 0.0, "flash": "", "flash_at": 0.0}

    while True:
        if time.time() - S["last"] > REFRESH_SECS:
            S["pms"] = load_pms(repo)
            S["last"] = time.time()
            S["sel"] = min(S["sel"], max(0, len(S["pms"]) - 1))
        if S["flash"] and time.time() - S["flash_at"] > 3:
            S["flash"] = ""

        draw(stdscr, S)
        k = stdscr.getch()
        if k == -1:
            time.sleep(0.06); continue

        pms, sel = S["pms"], S["sel"]
        p = pms[sel] if pms else None

        if k in (ord("q"), ord("Q")):
            return
        elif k in (ord("r"), ord("R")):
            S["last"] = 0
        elif k in (curses.KEY_DOWN, ord("j")):
            if S["focus"] == "list":
                S["sel"] = min(sel + 1, max(0, len(pms) - 1)); S["scroll"] = 0
            else:
                S["scroll"] += 1
        elif k in (curses.KEY_UP, ord("k")):
            if S["focus"] == "list":
                S["sel"] = max(sel - 1, 0); S["scroll"] = 0
            else:
                S["scroll"] = max(0, S["scroll"] - 1)
        elif k == 9:
            S["pane"] = (S["pane"] + 1) % 3; S["scroll"] = 0
        elif k in (curses.KEY_ENTER, 10, 13, curses.KEY_RIGHT):
            S["focus"] = "detail"
        elif k in (27, curses.KEY_LEFT):
            S["focus"] = "list"
        elif k == curses.KEY_NPAGE:
            S["scroll"] += 20
        elif k == curses.KEY_PPAGE:
            S["scroll"] = max(0, S["scroll"] - 20)

        elif k == ord("i") and p:
            msg = prompt(stdscr, f"message to {p['slug']}:")
            if msg:
                ok, why = append_inbox(p, msg)
                S["flash"], S["flash_at"] = ("queued" if ok else "failed"), time.time()
                S["last"] = 0
        elif k == ord("a") and p:
            curses.endwin()
            os.execvp("tmux", ["tmux", "attach", "-t", tmux_session(p)])
        elif k == ord("w") and p:
            run_detached(["bash", os.path.join(skill_dir, "scripts", "pm-launch.sh"),
                          p["slug"], "--once"])
            S["flash"], S["flash_at"] = "waking", time.time()
        elif k == ord("s") and p:
            if prompt(stdscr, f"stop {p['slug']}? type yes:") == "yes":
                subprocess.run(["bash", os.path.join(skill_dir, "scripts", "pm-launch.sh"),
                                p["slug"], "--stop"], capture_output=True)
                S["flash"], S["flash_at"] = "stopped", time.time()
                S["last"] = 0


if __name__ == "__main__":
    import sys
    repo = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    skill = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    try:
        curses.wrapper(main, repo, skill)
    except KeyboardInterrupt:
        pass
