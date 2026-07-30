#!/usr/bin/env python3
"""pm-top — live view of nightshift PMs, their workers, and their output.

Layout is a split: PM list on the left, detail on the right, aggregate header on top.

Navigation (one focus at a time — shown in the header as [PMs] / [agents] / [scroll]):

    Tab        switch focus: left PMs ↔ right pane
    ↑/↓  j/k   move in the focused region (PMs, agents, or scroll)
    n / p      next / previous PM (always, any focus)
    [ / ]      cycle LEDGER → WORKERS → OUTPUT
    Enter      open selected agent (on WORKERS); from PMs, jump to WORKERS
    Esc / ←    back: close agent → agents list → focus PMs
    →          focus the right pane
    1-9        jump to PM by number
    i msg  a attach  w wake  s stop  r refresh  q quit
    mouse      click PMs / tabs / agents; wheel scrolls (or moves PMs over the list)

Worker detail shows Claude sessionId + agentId + transcript path so you can open
the same chat from a terminal (e.g. `less <path>` or `claude --resume <sessionId>`).

WHAT IT WILL AND WILL NOT WRITE

It writes to exactly one thing: `INBOX.md`, and only when you press `i`. That file is
designed to receive outside input; the PM reads it each wake and treats every entry as a
claim to verify, not an instruction.

It never writes LEDGER.md, the registry, or any source file. The ledger is the PM's
memory and the first thing it reads on every wake, so anything that can write there can
steer days of unattended work. See references/ledger-schema.md.

WHY YOU CANNOT TYPE INTO A PM

Each wake is a fresh provider process: prompt in, result out, exit. It is non-interactive
by construction, which is what makes "resume from files" true rather than aspirational. So
`a` puts you in the supervisor's tmux session where you can watch, and `i` is how you
actually say something the PM will act on.

`a` switches the client when it is already inside tmux (the overlay case) and attaches
when it is not. From the overlay, prefix + L returns you to Claude Code.
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
        # Local wall-clock start. "running 2h" answers how long; this answers since when,
        # which is what you actually want when correlating against a deploy or a commit.
        lt = time.localtime(t0)
        today = time.localtime()
        same_day = (lt.tm_year, lt.tm_yday) == (today.tm_year, today.tm_yday)
        p["_started_local"] = time.strftime("%H:%M" if same_day else "%b %d %H:%M", lt)
    except Exception:
        p["_runtime"] = "-"
        p["_started_local"] = "-"

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


def worker_ids(path):
    """Parent chat sessionId and agentId for opening the transcript outside pm-top.

    Claude Code writes these on every jsonl line. Path fallback covers truncated files:
    ~/.claude/projects/<encoded-wt>/<sessionId>/subagents/agent-<agentId>.jsonl
    """
    session_id = agent_id = ""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for _ in range(40):
                line = fh.readline()
                if not line:
                    break
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                session_id = session_id or o.get("sessionId") or ""
                agent_id = agent_id or o.get("agentId") or ""
                if session_id and agent_id:
                    break
    except Exception:
        pass
    parts = path.split(os.sep)
    try:
        i = parts.index("subagents")
        session_id = session_id or parts[i - 1]
        base = os.path.basename(path)
        if base.startswith("agent-") and base.endswith(".jsonl"):
            agent_id = agent_id or base[len("agent-"):-len(".jsonl")]
    except ValueError:
        pass
    return session_id, agent_id


def last_text(path, limit=500):
    """Final human-readable sentence from a transcript, skipping tool-call noise."""
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



# Transcripts carry per-message `usage` and `model`, so token counts are read rather than
# estimated. Scanning is cached on (path, mtime, size): a busy worker's transcript is
# hundreds of KB and re-parsing it every 5s refresh would make the UI crawl.
_USAGE_CACHE = {}


def transcript_usage(path):
    """{model, in, cache_w, cache_r, out, msgs} for one transcript."""
    try:
        st = os.stat(path)
        key = (path, st.st_mtime, st.st_size)
    except Exception:
        return None
    if key in _USAGE_CACHE:
        return _USAGE_CACHE[key]

    agg = {"model": "", "models": [], "in": 0, "cache_w": 0, "cache_r": 0, "out": 0, "msgs": 0}
    models = {}
    order = []
    last_sm = ""
    try:
        with open(path, "r", errors="replace") as fh:
            for line in fh:
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                m = o.get("message") or {}
                u = m.get("usage") or o.get("usage")
                mdl = m.get("model") or o.get("model")
                if mdl:
                    models[mdl] = models.get(mdl, 0) + 1
                    sm = short_model(mdl)
                    if sm:
                        last_sm = sm
                        if sm not in order:
                            order.append(sm)
                if not isinstance(u, dict):
                    continue
                agg["msgs"] += 1
                agg["in"] += int(u.get("input_tokens") or 0)
                agg["cache_w"] += int(u.get("cache_creation_input_tokens") or 0)
                agg["cache_r"] += int(u.get("cache_read_input_tokens") or 0)
                agg["out"] += int(u.get("output_tokens") or 0)
    except Exception:
        pass
    if order:
        # Current = last seen; models = chronological unique (for "was …").
        agg["model"] = last_sm or order[-1]
        agg["models"] = order
    elif models:
        # strip the vendor prefix and date suffix: claude-opus-4-6-20260101 -> opus-4-6
        # skip Claude's placeholder "<synthetic>" rows
        real = {k: v for k, v in models.items() if k and k != "<synthetic>"}
        if real:
            best = max(real.items(), key=lambda kv: kv[1])[0]
            agg["model"] = re.sub(r"^claude-", "", re.sub(r"-\d{8}$", "", best))
            agg["models"] = [agg["model"]]
        else:
            agg["model"] = ""
            agg["models"] = []
    _USAGE_CACHE[key] = agg
    if len(_USAGE_CACHE) > 512:
        _USAGE_CACHE.clear()
    return agg


def fmt_tokens(n):
    if n >= 1_000_000:
        return f"{n/1_000_000:.1f}M"
    if n >= 1000:
        return f"{n/1000:.0f}K"
    return str(n)


def short_model(mdl):
    """Strip vendor/date noise. Drop Claude's placeholder '<synthetic>' rows."""
    if not mdl or mdl == "<synthetic>":
        return ""
    return re.sub(r"^claude-", "", re.sub(r"-\d{8}$", "", str(mdl)))


def model_with_former(current, former, prefix=""):
    """Render current model, appending former ones when the model changed.

    current: bare model or provider/model
    former: list of bare models or provider/model labels
    prefix: optional 'claude/' etc. applied only to bare current/former entries
    """
    cur = (current or "").strip()
    if not cur:
        cur = "?"
    if prefix and "/" not in cur:
        cur = f"{prefix}{cur}"
    seen = {cur, cur.split("/", 1)[-1]}
    extras = []
    for raw in former or []:
        m = (raw or "").strip()
        if not m:
            continue
        label = m if "/" in m else (f"{prefix}{m}" if prefix else m)
        bare = label.split("/", 1)[-1]
        if label in seen or bare in seen or bare == cur.split("/", 1)[-1]:
            continue
        seen.add(label)
        seen.add(bare)
        extras.append(label)
    if not extras:
        return cur
    return f"{cur} · was {', '.join(extras[-3:])}"


def _toml_model(path):
    try:
        for line in open(path, encoding="utf-8", errors="replace"):
            m = re.match(r'^model\s*=\s*"([^"]+)"', line.strip())
            if m:
                return m.group(1)
    except Exception:
        pass
    return ""


def _cursor_default_model():
    path = os.path.join(HOME, ".cursor", "cli-config.json")
    try:
        d = json.load(open(path))
        m = d.get("model") or {}
        if isinstance(m, dict):
            return m.get("modelId") or m.get("model") or ""
        if isinstance(m, str):
            return m
    except Exception:
        pass
    return ""


def _codex_default_model():
    return _toml_model(os.path.join(HOME, ".codex", "config.toml"))


def _wake_json_model(worktree):
    """Best-effort model from the latest wake output (claude/cursor JSON)."""
    path = os.path.join(worktree or "", ".nightshift-wake.json")
    if not os.path.isfile(path):
        return ""
    try:
        raw = open(path, encoding="utf-8", errors="replace").read().strip()
        if not raw:
            return ""
        # Claude: JSON array/object. Codex: NDJSON without model. Cursor: often one object.
        if raw[0] in "[{":
            d = json.loads(raw)
            objs = d if isinstance(d, list) else [d]
            for o in objs:
                if not isinstance(o, dict):
                    continue
                for cand in (o.get("model"),
                             (o.get("message") or {}).get("model") if isinstance(o.get("message"), dict) else None,
                             o.get("result", {}).get("model") if isinstance(o.get("result"), dict) else None):
                    if cand:
                        return str(cand)
        for line in raw.splitlines():
            try:
                o = json.loads(line)
            except Exception:
                continue
            if not isinstance(o, dict):
                continue
            for nest in (o, o.get("item") or {}, o.get("message") or {}, o.get("info") or {}):
                if isinstance(nest, dict) and nest.get("model"):
                    return str(nest["model"])
    except Exception:
        pass
    return ""


def model_history_from_worktree(wt):
    """Chronological provider/model labels from .nightshift-model-history.jsonl.

    cursor-agent's wake JSON omits model, so this file is the durable trail for
    former cursor (and other) models across wakes.
    """
    path = os.path.join(wt or "", ".nightshift-model-history.jsonl")
    out = []
    seen = set()
    if not os.path.isfile(path):
        return out
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                prov = (o.get("provider") or "").strip() or "claude"
                mdl = short_model(o.get("model") or "")
                if not mdl:
                    continue
                label = f"{prov}/{mdl}"
                if label in seen:
                    # keep chronological unique; move to end on repeat
                    out = [x for x in out if x != label]
                else:
                    seen.add(label)
                out.append(label)
    except Exception:
        pass
    return out


def provider_model_label(p):
    """Display as provider/model, plus former models when it changed."""
    provider = (p.get("provider") or "claude").strip() or "claude"
    mdl = short_model(p.get("last_model") or "")
    if not mdl:
        mdl = short_model(_wake_json_model(p.get("worktree", "")))
    if not mdl:
        if provider == "codex":
            mdl = short_model(_codex_default_model())
        elif provider == "cursor":
            mdl = short_model(_cursor_default_model())
        else:
            for m in pm_usage(p).get("models") or []:
                sm = short_model(m)
                if sm:
                    mdl = sm
                    break
    current = f"{provider}/{mdl or '?'}"
    former = list(p.get("former_models") or [])
    # Worktree wake log (especially important for cursor-agent).
    for label in model_history_from_worktree(p.get("worktree", "")):
        if label not in former:
            former.append(label)
    # Also surface other models seen in this provider's usage (same wake history).
    for m in pm_usage(p).get("models") or []:
        sm = short_model(m)
        if sm and sm != mdl:
            label = f"{provider}/{sm}"
            if label not in former and sm not in former:
                former.append(label)
    return model_with_former(current, former)


def pm_usage(p):
    """Token totals for the PM's current provider (not leftover Claude history)."""
    provider = (p.get("provider") or "claude").strip() or "claude"
    if provider == "codex":
        return codex_usage_for_worktree(p.get("worktree", ""))
    if provider == "cursor":
        return cursor_usage_for_worktree(p.get("worktree", ""))
    return claude_usage_for_worktree(p.get("worktree", ""))


def claude_usage_for_worktree(wt):
    sd = session_dir_for(wt)
    tot = {"model": "", "in": 0, "cache_w": 0, "cache_r": 0, "out": 0, "msgs": 0}
    models = {}
    for f in glob.glob(os.path.join(sd, "*.jsonl")) + \
             glob.glob(os.path.join(sd, "**", "subagents", "*.jsonl"), recursive=True):
        u = transcript_usage(f)
        if not u:
            continue
        for k in ("in", "cache_w", "cache_r", "out", "msgs"):
            tot[k] += u[k]
        sm = short_model(u["model"])
        if sm:
            models[sm] = models.get(sm, 0) + 1
    tot["models"] = sorted(models, key=lambda m: -models[m])
    return tot


_CODEX_USAGE_CACHE = {}


def _codex_rollout_usage(path):
    """Latest cumulative total_token_usage from one Codex rollout jsonl."""
    try:
        st = os.stat(path)
        key = (path, st.st_mtime, st.st_size)
    except Exception:
        return None
    if key in _CODEX_USAGE_CACHE:
        return _CODEX_USAGE_CACHE[key]

    last = None
    msgs = 0
    model = ""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                payload = o.get("payload") or {}
                if o.get("type") == "session_meta" and isinstance(payload, dict):
                    model = model or payload.get("model") or ""
                info = payload.get("info") if isinstance(payload, dict) else None
                if isinstance(info, dict) and isinstance(info.get("total_token_usage"), dict):
                    last = info["total_token_usage"]
                if o.get("type") == "response_item":
                    msgs += 1
    except Exception:
        last = None

    if not last:
        _CODEX_USAGE_CACHE[key] = None
        return None
    agg = {
        "model": short_model(model),
        "in": int(last.get("input_tokens") or 0),
        "cache_w": 0,
        "cache_r": int(last.get("cached_input_tokens") or 0),
        "out": int(last.get("output_tokens") or 0) + int(last.get("reasoning_output_tokens") or 0),
        "msgs": msgs,
    }
    _CODEX_USAGE_CACHE[key] = agg
    if len(_CODEX_USAGE_CACHE) > 256:
        _CODEX_USAGE_CACHE.clear()
    return agg


def codex_usage_for_worktree(wt):
    tot = {"model": "", "in": 0, "cache_w": 0, "cache_r": 0, "out": 0, "msgs": 0, "models": []}
    if not wt:
        return tot
    models = {}
    root = os.path.join(HOME, ".codex", "sessions")
    for f in glob.glob(os.path.join(root, "**", "rollout-*.jsonl"), recursive=True):
        try:
            with open(f, "r", encoding="utf-8", errors="replace") as fh:
                head = fh.readline()
            o = json.loads(head)
            cwd = ((o.get("payload") or {}).get("cwd") or "")
            if cwd != wt:
                continue
        except Exception:
            continue
        u = _codex_rollout_usage(f)
        if not u:
            continue
        for k in ("in", "cache_w", "cache_r", "out", "msgs"):
            tot[k] += u[k]
        if u.get("model"):
            models[u["model"]] = models.get(u["model"], 0) + 1
    if not models:
        sm = short_model(_codex_default_model())
        if sm:
            models[sm] = 1
    tot["models"] = sorted(models, key=lambda m: -models[m])
    if tot["models"]:
        tot["model"] = tot["models"][0]
    return tot


def cursor_usage_for_worktree(wt):
    """Token totals from the latest cursor-agent wake JSON (+ model history).

    cursor-agent --output-format json uses camelCase usage keys and omits model;
    model comes from cli-config / claim / .nightshift-model-history.jsonl.
    """
    tot = {"model": "", "in": 0, "cache_w": 0, "cache_r": 0, "out": 0, "msgs": 0, "models": []}
    models = {}
    order = []

    def note_model(m):
        sm = short_model(m)
        if not sm:
            return
        models[sm] = models.get(sm, 0) + 1
        if sm not in order:
            order.append(sm)

    sm = short_model(_cursor_default_model())
    if sm:
        note_model(sm)
    for label in model_history_from_worktree(wt):
        if label.startswith("cursor/"):
            note_model(label.split("/", 1)[1])

    path = os.path.join(wt or "", ".nightshift-wake.json")
    if os.path.isfile(path):
        try:
            raw = open(path, encoding="utf-8", errors="replace").read().strip()
            objs = []
            if raw[:1] in "[{":
                d = json.loads(raw)
                objs = d if isinstance(d, list) else [d]
            else:
                for line in raw.splitlines():
                    try:
                        objs.append(json.loads(line))
                    except Exception:
                        pass
            for o in objs:
                if not isinstance(o, dict):
                    continue
                msg = o.get("message") if isinstance(o.get("message"), dict) else {}
                u = o.get("usage") or msg.get("usage")
                if not isinstance(u, dict):
                    continue
                tot["msgs"] += 1
                # cursor-agent: inputTokens; Claude-ish: input_tokens
                tot["in"] += int(u.get("inputTokens") or u.get("input_tokens")
                                 or u.get("prompt_tokens") or 0)
                tot["out"] += int(u.get("outputTokens") or u.get("output_tokens")
                                  or u.get("completion_tokens") or 0)
                tot["cache_r"] += int(u.get("cacheReadTokens") or u.get("cache_read_input_tokens")
                                      or u.get("cached_tokens") or 0)
                tot["cache_w"] += int(u.get("cacheWriteTokens") or u.get("cache_creation_input_tokens")
                                      or 0)
                note_model(o.get("model") or msg.get("model"))
        except Exception:
            pass
    tot["models"] = order or sorted(models, key=lambda m: -models[m])
    if tot["models"]:
        tot["model"] = tot["models"][-1]
    return tot


def _tool_target(name, inp):
    """The one argument that says what a tool call actually did."""
    if not isinstance(inp, dict):
        return ""
    for k in ("file_path", "path", "notebook_path"):
        if inp.get(k):
            return str(inp[k]).replace(os.path.expanduser("~"), "~")
    if inp.get("command"):
        return " ".join(str(inp["command"]).split())[:120]
    for k in ("pattern", "query", "url", "description", "prompt"):
        if inp.get(k):
            return " ".join(str(inp[k]).split())[:120]
    return ""


def worker_goal(path, limit=600):
    """The prompt the PM dispatched this worker with, i.e. its goal.

    It is the first user message in the transcript. Reading it from the head of the file
    rather than the tail matters: a busy worker's later turns are tool results, and the
    goal is the one thing that explains why any of them happened.
    """
    try:
        with open(path, "r", errors="replace") as fh:
            for _ in range(400):
                line = fh.readline()
                if not line:
                    break
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                if o.get("type") != "user":
                    continue
                c = (o.get("message") or {}).get("content")
                txt = ""
                if isinstance(c, str):
                    txt = c
                elif isinstance(c, list):
                    for b in c:
                        if isinstance(b, dict) and b.get("type") == "text":
                            txt += b.get("text", "")
                txt = txt.strip()
                if txt:
                    return txt[:limit]
    except Exception:
        pass
    return ""


def worker_events(path, limit=200):
    """A readable timeline for one worker.

    Returns (kind, head, body, ts) where kind is 'text' | 'tool' | 'user'.

    Consecutive calls to the same tool collapse into one row with a count, because a
    worker doing real work emits dozens of Reads in a row and rendering each as its own
    "assistant / [tool: Read]" block buries the two sentences that actually matter.
    """
    raw = []
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            fh.seek(max(0, fh.tell() - 600000))
            lines = fh.read().decode("utf-8", "replace").splitlines()
        for line in lines:
            try:
                o = json.loads(line)
            except Exception:
                continue
            role = o.get("type")
            if role not in ("user", "assistant"):
                continue
            ts = (o.get("timestamp") or "")[11:19]
            c = (o.get("message") or {}).get("content")
            if isinstance(c, str):
                if c.strip():
                    raw.append(("user" if role == "user" else "text", "", c.strip(), ts))
                continue
            if not isinstance(c, list):
                continue
            for b in c:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "text" and b.get("text", "").strip():
                    raw.append(("text", "", b["text"].strip(), ts))
                elif b.get("type") == "tool_use":
                    raw.append(("tool", b.get("name", "?"), _tool_target(b.get("name"), b.get("input")), ts))
    except Exception:
        pass

    out = []
    for kind, head, body, ts in raw:
        if kind == "tool" and out and out[-1][0] == "tool" and out[-1][1] == head:
            prev = out[-1]
            targets = prev[2] if isinstance(prev[2], list) else [prev[2]]
            out[-1] = ("tool", head, targets + [body], prev[3])
        else:
            out.append((kind, head, [body] if kind == "tool" else body, ts))
    return out[-limit:]


def tmux_session(p):
    return p.get("tmux_session") or f"pm-{p.get('slug')}"


def output_for(p):
    try:
        r = subprocess.run(["tmux", "capture-pane", "-p", "-t", tmux_session(p)],
                           capture_output=True, text=True, timeout=3)
        if r.returncode == 0 and r.stdout.strip():
            lines = r.stdout.splitlines()
            # Drop Codex models-cache spam so the pane stays readable.
            filtered = [l for l in lines
                        if "supports_reasoning_summaries" not in l
                        and "codex_models_manager" not in l]
            return ["live tmux pane", ""] + filtered[-300:]
    except Exception:
        pass
    wake = os.path.join(p.get("worktree", ""), ".nightshift-wake.json")
    try:
        raw = open(wake, encoding="utf-8", errors="replace").read().strip()
        if not raw:
            raise ValueError("empty")
        # Claude: JSON array with type=result. Codex: NDJSON agent_message items.
        try:
            d = json.loads(raw)
        except Exception:
            d = None
        if isinstance(d, list):
            res = next((o for o in d if isinstance(o, dict) and o.get("type") == "result"), None)
            if res:
                return [f"last wake · ${float(res.get('total_cost_usd') or 0):.2f} · "
                        f"{res.get('num_turns')} turns · {int((res.get('duration_ms') or 0)/1000)}s",
                        ""] + (res.get("result") or "").splitlines()
        msgs = []
        for line in raw.splitlines():
            try:
                o = json.loads(line)
            except Exception:
                continue
            item = o.get("item") if isinstance(o, dict) else None
            if isinstance(item, dict) and item.get("type") == "agent_message" and item.get("text"):
                msgs.append(item["text"])
        if msgs:
            return ["last wake · codex", ""] + "\n\n".join(msgs).splitlines()[-300:]
    except Exception:
        pass
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
    """Read one line at the bottom of the screen. Returns None if the user pressed esc.

    Hand-rolled rather than curses.getstr, which has no notion of cancelling: it swallows
    esc and returns only on enter, so a half-typed message to a PM could not be abandoned
    once started. esc means "back out" everywhere else in this UI and it should here too.
    """
    h, w = stdscr.getmaxyx()
    try:
        # ncurses waits a full second after esc to see if an escape SEQUENCE is arriving,
        # which reads as a frozen key. Arrows still work: keypad() resolves those to
        # KEY_* codes well inside this window.
        curses.set_escdelay(25)
    except (AttributeError, curses.error):
        pass
    curses.curs_set(1)
    stdscr.nodelay(False)
    buf = ""
    x = min(len(label) + 1, max(0, w - 4))
    room = max(1, w - x - 2)
    try:
        while True:
            stdscr.addstr(h - 1, 0, " " * (w - 1))
            stdscr.addstr(h - 1, 0, label[: w - 2], curses.color_pair(C_AMBER) | curses.A_BOLD)
            tail = buf[-room:]                      # scroll the field, keep the caret visible
            stdscr.addstr(h - 1, x, tail)
            stdscr.move(h - 1, min(w - 2, x + len(tail)))
            stdscr.refresh()
            k = stdscr.getch()
            if k == 27:
                buf = None
                break
            if k in (curses.KEY_ENTER, 10, 13):
                break
            if k in (curses.KEY_BACKSPACE, 127, 8):
                buf = buf[:-1]
            elif k == 21:                           # ctrl-u, clear the line
                buf = ""
            elif 32 <= k < 127 and len(buf) < 2000:
                buf += chr(k)
    except Exception:
        buf = None
    finally:
        curses.curs_set(0)
        stdscr.nodelay(True)
    return None if buf is None else buf.strip()


def run_detached(args):
    try:
        subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except Exception:
        return False


# ---------------------------------------------------------------- navigation helpers

def focus_label(S):
    """What ↑/↓ will move right now."""
    if S.get("focus") == "list":
        return "PMs"
    if S.get("wopen") is not None:
        return "scroll"
    if S.get("pane") == 1 and S.get("_ws"):
        return "agents"
    return "scroll"


def move_pm(S, delta):
    pms = S.get("pms") or []
    if not pms:
        return
    S["sel"] = max(0, min(len(pms) - 1, S.get("sel", 0) + delta))
    S["scroll"] = 0
    S["wsel"] = 0
    S["wopen"] = None


def move_worker(S, delta):
    ws = S.get("_ws") or []
    if not ws:
        return
    S["wsel"] = max(0, min(len(ws) - 1, S.get("wsel", 0) + delta))


def nav_vertical(S, delta):
    """↑/↓: always move the focused region."""
    if S.get("focus") == "list":
        move_pm(S, delta)
        return
    if S.get("wopen") is not None:
        S["scroll"] = max(0, S.get("scroll", 0) + delta)
        return
    if S.get("pane") == 1 and S.get("_ws"):
        move_worker(S, delta)
        return
    S["scroll"] = max(0, S.get("scroll", 0) + delta)


def nav_back(S):
    """Esc/←: close agent → focus PMs."""
    if S.get("wopen") is not None:
        S["wopen"], S["scroll"] = None, 0
        S["focus"] = "detail"
        return True
    if S.get("focus") != "list":
        S["focus"] = "list"
        return True
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
    """Wrap (text, attr, col[, tag]) rows. Optional tag is preserved for mouse hit-testing."""
    out = []
    for row in items:
        text, attr, col = row[0], row[1], row[2]
        tag = row[3] if len(row) > 3 else None
        if not text:
            out.append(("", attr, col, tag)); continue
        indent = len(text) - len(text.lstrip())
        for i, seg in enumerate(textwrap.wrap(text.strip(), max(10, width)) or [""]):
            out.append((" " * indent + ("" if i == 0 else "  ") + seg, attr, col, tag))
    return out


def draw(stdscr, S):
    stdscr.erase()
    # Rebuilt every frame so hit-testing can never drift from what is on screen.
    S["hits"] = {"pms": [], "tabs": [], "keys": [], "workers": [], "detail": None, "back": None, "list": None}
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
    fl = focus_label(S)
    focus_chip = f"[{fl}]"
    put(stdscr, 0, max(len(title) + 2 + len(stats) + 2, w - len(focus_chip) - 10),
        focus_chip, C(C_CYAN) | BOLD)
    put(stdscr, 0, w - 10, S.get("flash", "")[:8], C(C_GREEN) | BOLD)
    hline(stdscr, 1, 0, w, "─", C(C_MUTED))

    if not pms:
        put(stdscr, 3, 2, "no PMs provisioned in this repo", DIM)
        put(stdscr, 5, 2, "q quit", DIM)
        stdscr.refresh(); return

    LW = max(26, min(38, w // 3))
    body_top, body_bot = 2, h - 2
    list_focused = focus == "list"

    # ---- left: PM list ----
    y = body_top
    put(stdscr, y, 2, "PMs" + (" ◀" if list_focused else ""),
        (C(C_CYAN) | BOLD) if list_focused else C(C_MUTED))
    y += 1
    for i, p in enumerate(pms):
        if y >= body_bot - 1:
            break
        tag, col = badge(p)
        cur = i == sel
        marker = "▶" if cur and list_focused else ("▐" if cur else " ")
        attr = (BOLD if cur else 0) | C(col)
        if cur and not list_focused:
            attr = C(col)  # selected but not focused: still visible, less loud
        put(stdscr, y, 0, marker, C(C_CYAN) | BOLD if cur else 0)
        num = f"{i+1}." if i < 9 else "  "
        put(stdscr, y, 2, f"{num}{p.get('slug','?')[:LW-14]:<{LW-14}}", attr)
        put(stdscr, y, LW - 9, f"{age(p.get('heartbeat','')):>4}", C(C_MUTED))
        y1 = y
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
        S["hits"]["pms"].append((y1, y, 0, LW - 1, i))  # both lines, left pane only
        y += 2

    div = "┃" if list_focused else "│"
    for yy in range(body_top, body_bot):
        put(stdscr, yy, LW, div, C(C_CYAN) if list_focused else C(C_MUTED))
    S["hits"]["list"] = (body_top, body_bot - 1, 0, LW - 1)
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
    left = [("started", p.get("_started_local", "-")),
            ("running", p.get("_runtime", "-")),
            ("wakes", f"{p.get('wakes', 0)}"),
            ("spend", f"${float(p.get('cost_usd') or 0):.2f}")]
    right = [("branch", p.get("branch", "-")),
             ("commits", f"{p.get('_commits', 0)}"),
             ("diff", f"+{ins} -{dele} in {files}f" if files else "none yet")]
    if tasks:
        right.append(("tasks", f"{tasks[0]}/{tasks[1]}"))
    left.append(("workers", str(len(workers_for(p)))))
    model_lbl = provider_model_label(p)
    u = pm_usage(p)
    if u.get("in") or u.get("out") or u.get("msgs") or u.get("cache_r"):
        # cache reads are the bulk of token traffic for both Claude and Codex.
        right.append(("tokens", f"in {fmt_tokens(u['in'])} · out {fmt_tokens(u['out'])}"))
        right.append(("cache", f"w {fmt_tokens(u['cache_w'])} · r {fmt_tokens(u['cache_r'])}"))
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
    # Full-width so "current · was former…" is not clipped by the two-column grid.
    if fy < body_bot - 4:
        put(stdscr, fy, RX, "model   ", C(C_MUTED))
        put(stdscr, fy, RX + 8, model_lbl[:RW - 9], C(C_CYAN))
        fy += 1
    ty = fy + 1
    x = RX
    detail_focused = not list_focused
    for i, nm in enumerate(PANES):
        on = i == pane
        # Right-side focus marker on the active tab.
        label = f" {nm} "
        if on and detail_focused:
            label = f" {nm} ◀"
        put(stdscr, ty, x, label,
            (C(C_CYAN) | BOLD) if on else C(C_MUTED))
        S["hits"]["tabs"].append((ty, x, x + len(label), i))
        x += len(label) + 1
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
        S["_ws"] = ws
        if not ws:
            items = [("no workers dispatched yet", DIM, 0), ("", 0, 0),
                     ("A PM spawns subagents once it starts implementing.", DIM, 0),
                     ("This pane fills in as soon as it does.", DIM, 0)]
        elif S.get("wopen") is not None and S["wopen"] < len(ws):
            # drilled into one worker: its whole conversation, newest last
            mt, sz, f = ws[S["wopen"]]
            u = transcript_usage(f) or {}
            sid, aid = worker_ids(f)
            items = [(f"worker {S['wopen']+1}/{len(ws)}  ·  {os.path.basename(f)[:40]}", BOLD, C_HEAD),
                     (f"model {model_with_former(u.get('model') or '?', u.get('models') or [], prefix='claude/')}   "
                      f"{u.get('msgs',0)} message(s)   "
                      f"last active {time.strftime('%H:%M:%S', time.localtime(mt))}", DIM, 0),
                     (f"tokens  in {fmt_tokens(u.get('in',0))}   "
                      f"out {fmt_tokens(u.get('out',0))}   "
                      f"cache write {fmt_tokens(u.get('cache_w',0))}   "
                      f"cache read {fmt_tokens(u.get('cache_r',0))}", 0, C_GREEN),
                     (f"session  {sid or '?'}", 0, C_CYAN),
                     (f"agent    {aid or '?'}", 0, C_CYAN),
                     (f"path     {f}", DIM, 0),
                     ("↑↓ scroll   esc/← back to agents   tab PMs", DIM, 0),
                     ("", 0, 0)]
            g = worker_goal(f)
            if g:
                items.append(("GOAL FROM THE PM", BOLD, C_HEAD))
                items += [("  " + l, 0, 0) for l in g.splitlines()[:12]]
                items.append(("", 0, 0))
            for kind, head, body, ts in worker_events(f):
                if kind == "tool":
                    targets = [b for b in body if b]
                    n = len(body)
                    label = f"{head} x{n}" if n > 1 else head
                    items.append((f"{ts or '--:--:--'}  {label}", BOLD, C_AMBER))
                    for tgt in targets[:6]:
                        items.append(("            " + tgt, DIM, 0))
                    if len(targets) > 6:
                        items.append((f"            ... {len(targets)-6} more", DIM, 0))
                elif kind == "user":
                    items.append((f"{ts or '--:--:--'}  prompt", BOLD, C_HEAD))
                    items += [("            " + l, DIM, 0) for l in body.splitlines()[:6]]
                else:
                    items.append((f"{ts or '--:--:--'}  says", BOLD, C_CYAN))
                    items += [("            " + l, 0, 0) for l in body.splitlines()[:40]]
                items.append(("", 0, 0))
        else:
            wsel = S.get("wsel", 0)
            items = [(f"{len(ws)} agent(s), newest first"
                      "     ↑↓ select   enter open   tab PMs", BOLD, C_HEAD, None),
                     ("", 0, 0, None)]
            for i, (mt, sz, f) in enumerate(ws[:40]):
                cur = i == wsel
                mark = "> " if cur else "  "
                u = transcript_usage(f) or {}
                sid, aid = worker_ids(f)
                meta = f"{model_with_former(u.get('model') or '?', u.get('models') or [], prefix='claude/')}  " \
                       f"in {fmt_tokens(u.get('in',0))}" \
                       f" out {fmt_tokens(u.get('out',0))}" \
                       f" cache {fmt_tokens(u.get('cache_r',0))}"
                items.append((f"{mark}{time.strftime('%H:%M:%S', time.localtime(mt))}  "
                              f"{os.path.basename(f)[:26]}",
                              BOLD if cur else 0, C_CYAN if cur else C_MUTED, i))
                items.append(("    " + meta, DIM, C_GREEN if cur else 0, i))
                id_line = "    "
                if sid:
                    id_line += f"session {sid[:8]}…  " if len(sid) > 12 else f"session {sid}  "
                if aid:
                    id_line += f"agent {aid}"
                if sid or aid:
                    items.append((id_line.rstrip(), DIM, C_CYAN if cur else 0, i))
                g = worker_goal(f, 160).replace("\n", " ")
                if g:
                    items.append(("    goal: " + g, DIM, C_HEAD, i))
                items.append(("    last: " + last_text(f, 180).replace("\n", " "), DIM, 0, i))
                items.append(("", 0, 0, i))
    else:
        items = [(l, 0, 0, None) for l in output_for(p)]

    # Tag ledger/worker-detail rows as None (scroll-only); worker list rows carry widx.
    if pane == 0 or (pane == 1 and S.get("wopen") is not None):
        items = [(*row[:3], None) if len(row) == 3 else row for row in items]

    wrapped = wrap(items, RW)
    view_h = body_bot - (ty + 2)
    # Keep the selected worker row on screen. Without this, ^/v moves wsel into
    # rows below the fold and the arrows look dead.
    if pane == 1 and S.get("wopen") is None and S.get("_ws"):
        for i, row in enumerate(wrapped):
            text = row[0]
            if text.startswith("> "):
                if i < scroll:
                    scroll = i
                elif i >= scroll + max(1, view_h):
                    scroll = i - view_h + 1
                break
    scroll = max(0, min(scroll, max(0, len(wrapped) - view_h)))
    S["scroll"] = scroll
    detail_top = ty + 2
    detail_bot = body_bot - 1
    S["hits"]["detail"] = (detail_top, detail_bot, RX, w - 1)
    # Title line is a clickable "back" when drilled into a worker.
    if pane == 1 and S.get("wopen") is not None:
        S["hits"]["back"] = (detail_top, detail_top, RX, w - 1)

    for i, row in enumerate(wrapped[scroll:scroll + view_h]):
        text, attr, c = row[0], row[1], row[2]
        tag = row[3] if len(row) > 3 else None
        sy = detail_top + i
        put(stdscr, sy, RX, text, attr | (C(c) if c else 0), RW)
        if tag is not None and pane == 1 and S.get("wopen") is None:
            S["hits"]["workers"].append((sy, sy, RX, w - 1, tag))

    if len(wrapped) > view_h:
        pct = int(100 * scroll / max(1, len(wrapped) - view_h))
        put(stdscr, body_bot - 1, w - 6, f"{pct:>3}%", C(C_MUTED))

    # ---- footer ----
    hline(stdscr, h - 2, 0, w, "─", C(C_MUTED))
    fl = focus_label(S)
    keys = [("↑↓", fl), ("tab", "side"), ("n/p", "pm"), ("[/]", "pane"),
            ("ret", "open"), ("esc", "back"),
            ("i", "msg"), ("a", "attach"), ("w", "wake"), ("q", "quit")]
    x = 1
    for k, lbl in keys:
        if x + len(k) + len(lbl) + 3 >= w:
            break
        start = x
        put(stdscr, h - 1, x, k, C(C_CYAN) | BOLD); x += len(k) + 1
        put(stdscr, h - 1, x, lbl, C(C_MUTED));     x += len(lbl) + 2
        # Only single-letter actions are clickable via ungetch.
        if len(k) == 1:
            S["hits"]["keys"].append((h - 1, start, x - 2, k))
    stdscr.refresh()
# ---------------------------------------------------------------- main

def _in_box(my, mx, box):
    """box is (y0, y1, x0, x1) inclusive."""
    if not box:
        return False
    y0, y1, x0, x1 = box
    return y0 <= my <= y1 and x0 <= mx <= x1


def main(stdscr, repo, skill_dir):
    curses.curs_set(0)
    stdscr.nodelay(True)
    # Mouse: click PMs / tabs / workers / footer; wheel scrolls the detail pane.
    # BUTTON5 is wheel-down on most terminals but is absent from some curses builds, so
    # it is resolved defensively rather than referenced directly.
    try:
        curses.mousemask(curses.ALL_MOUSE_EVENTS | curses.REPORT_MOUSE_POSITION)
        curses.mouseinterval(200)
        # 1000=click, 1002=button-event (better wheel), 1006=SGR, 1007=alternate scroll
        print("\033[?1003l\033[?1000h\033[?1002h\033[?1006h\033[?1007h", end="", flush=True)
    except Exception:
        pass
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
         "focus": "list", "last": 0.0, "flash": "", "flash_at": 0.0,
         "hits": {"pms": [], "tabs": [], "keys": [], "workers": [], "detail": None, "back": None},
         "wsel": 0, "wopen": None, "_ws": [], "_mclick": None}
    WHEEL_DOWN = getattr(curses, "BUTTON5_PRESSED", 0x200000)
    BTN1 = (curses.BUTTON1_PRESSED | curses.BUTTON1_CLICKED
            | getattr(curses, "BUTTON1_DOUBLE_CLICKED", 0)
            | getattr(curses, "BUTTON1_TRIPLE_CLICKED", 0))

    try:
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

        if k == curses.KEY_MOUSE:
            try:
                _, mx, my, _, bst = curses.getmouse()
            except Exception:
                continue
            detail = S["hits"].get("detail")
            over_detail = _in_box(my, mx, detail)
            over_list = _in_box(my, mx, S["hits"].get("list"))

            if bst & curses.BUTTON4_PRESSED:          # wheel up
                if over_list:
                    move_pm(S, -1)
                    S["focus"] = "list"
                else:
                    # On agents list, wheel moves selection; otherwise scroll.
                    if (S.get("pane") == 1 and S.get("wopen") is None and S.get("_ws")
                            and S.get("focus") != "list"):
                        move_worker(S, -1)
                    else:
                        S["scroll"] = max(0, S["scroll"] - 3)
                    S["focus"] = "detail"
                continue
            if bst & WHEEL_DOWN:                      # wheel down
                if over_list:
                    move_pm(S, 1)
                    S["focus"] = "list"
                else:
                    if (S.get("pane") == 1 and S.get("wopen") is None and S.get("_ws")
                            and S.get("focus") != "list"):
                        move_worker(S, 1)
                    else:
                        S["scroll"] += 3
                    S["focus"] = "detail"
                continue
            if not (bst & BTN1):
                continue

            # Footer keys first (ungetch into the normal key path)
            handled = False
            for ky, x0, x1, key in S["hits"].get("keys") or []:
                if my == ky and x0 <= mx <= x1:
                    curses.ungetch(ord(key[0]))
                    handled = True
                    break
            if handled:
                continue

            # PM list (left pane)
            for y0, y1, x0, x1, idx in S["hits"].get("pms") or []:
                if y0 <= my <= y1 and x0 <= mx <= x1:
                    S["sel"], S["scroll"], S["focus"] = idx, 0, "list"
                    S["wsel"], S["wopen"] = 0, None
                    handled = True
                    break
            if handled:
                continue

            # Pane tabs
            for ty_, x0, x1, idx in S["hits"].get("tabs") or []:
                if my == ty_ and x0 <= mx <= x1:
                    S["pane"], S["scroll"] = idx, 0
                    S["wopen"] = None
                    S["focus"] = "detail"
                    handled = True
                    break
            if handled:
                continue

            # Back to worker list (title line when drilled in)
            if _in_box(my, mx, S["hits"].get("back")):
                S["wopen"], S["scroll"] = None, 0
                S["focus"] = "detail"
                continue

            # Worker rows: click selects; click again / double-click opens
            for y0, y1, x0, x1, widx in S["hits"].get("workers") or []:
                if not (y0 <= my <= y1 and x0 <= mx <= x1):
                    continue
                dbl_flag = bool(bst & getattr(curses, "BUTTON1_DOUBLE_CLICKED", 0))
                open_it = dbl_flag or (S.get("wsel") == widx)
                S["_mclick"] = (widx, time.time())
                S["wsel"] = widx
                S["focus"] = "detail"
                S["pane"] = 1
                if open_it:
                    S["wopen"] = widx
                    S["scroll"] = 0
                handled = True
                break
            if handled:
                continue

            # Click in detail pane focuses it for keyboard nav
            if over_detail:
                S["focus"] = "detail"
            elif over_list:
                S["focus"] = "list"
            continue

        if k in (ord("q"), ord("Q")):
            return
        elif k in (ord("r"), ord("R")):
            S["last"] = 0
        elif k == 9:  # Tab: switch side
            S["focus"] = "detail" if S.get("focus") == "list" else "list"
        elif k in (ord("["),):
            if S.get("wopen") is not None:
                S["wopen"], S["scroll"] = None, 0
            else:
                S["pane"] = (S["pane"] - 1) % 3
                S["scroll"], S["wsel"], S["wopen"] = 0, 0, None
                S["focus"] = "detail"
        elif k in (ord("]"),):
            S["pane"] = (S["pane"] + 1) % 3
            S["scroll"], S["wsel"], S["wopen"] = 0, 0, None
            S["focus"] = "detail"
        elif k in (curses.KEY_RIGHT, ord("l")):
            S["focus"] = "detail"
        elif k in (curses.KEY_LEFT, ord("h")):
            nav_back(S)
        elif k == 27:  # Esc
            if not nav_back(S):
                S["focus"] = "list"
        elif k in (ord("n"), ord("N")):
            move_pm(S, 1)
            S["focus"] = "list"
        elif k in (ord("p"), ord("P")):
            # p = previous PM; capital-P was unused. (lowercase p also = prev)
            move_pm(S, -1)
            S["focus"] = "list"
        elif ord("1") <= k <= ord("9"):
            idx = k - ord("1")
            if idx < len(pms):
                S["sel"], S["scroll"] = idx, 0
                S["wsel"], S["wopen"] = 0, None
                S["focus"] = "list"
        elif k in (curses.KEY_DOWN, ord("j")):
            nav_vertical(S, 1)
        elif k in (curses.KEY_UP, ord("k")):
            nav_vertical(S, -1)
        elif k in (curses.KEY_ENTER, 10, 13):
            if S.get("focus") == "list":
                # Jump into this PM's agents pane.
                S["pane"], S["scroll"], S["focus"] = 1, 0, "detail"
                S["wopen"] = None
            elif S["pane"] == 1 and S.get("_ws"):
                if S.get("wopen") is None:
                    S["wopen"] = S.get("wsel", 0)
                else:
                    S["wopen"] = None
                S["scroll"] = 0
            else:
                S["focus"] = "detail"
        elif k == curses.KEY_NPAGE:
            if S.get("focus") == "list":
                move_pm(S, 5)
            else:
                S["scroll"] += 20
        elif k == curses.KEY_PPAGE:
            if S.get("focus") == "list":
                move_pm(S, -5)
            else:
                S["scroll"] = max(0, S["scroll"] - 20)
        elif k == curses.KEY_HOME:
            if S.get("focus") == "list":
                S["sel"], S["scroll"], S["wsel"], S["wopen"] = 0, 0, 0, None
            else:
                S["scroll"] = 0
        elif k == curses.KEY_END:
            if S.get("focus") == "list" and pms:
                S["sel"] = len(pms) - 1
                S["scroll"], S["wsel"], S["wopen"] = 0, 0, None
            else:
                S["scroll"] = 10**9   # draw clamps to the bottom

        elif k == ord("i") and p:
            msg = prompt(stdscr, f"message to {p['slug']} (esc cancels):")
            if msg is None:
                S["flash"], S["flash_at"] = "cancelled", time.time()
            elif msg:
                ok, why = append_inbox(p, msg)
                S["flash"], S["flash_at"] = ("queued" if ok else "failed"), time.time()
                S["last"] = 0
        elif k == ord("a") and p:
            sess = tmux_session(p)
            if os.environ.get("TMUX"):
                # Already inside tmux, which is always true when pm-top is running in the
                # overlay popup. `tmux attach` refuses to nest, so switch the client
                # instead and then fall out of the loop: the popup was opened with -E, so
                # exiting closes it and drops the user straight into the PM's session.
                # prefix + L gets them back to Claude Code.
                subprocess.run(["tmux", "switch-client", "-t", sess], capture_output=True)
                return
            curses.endwin()
            os.execvp("tmux", ["tmux", "attach", "-t", sess])
        elif k == ord("w") and p:
            run_detached(["bash", os.path.join(skill_dir, "scripts", "pm-launch.sh"),
                          p["slug"], "--once"])
            S["flash"], S["flash_at"] = "waking", time.time()
        elif k == ord("s") and p:
            ans = prompt(stdscr, f"stop {p['slug']}? type yes (esc cancels):")
            if ans == "yes":
                subprocess.run(["bash", os.path.join(skill_dir, "scripts", "pm-launch.sh"),
                                p["slug"], "--stop"], capture_output=True)
                S["flash"], S["flash_at"] = "stopped", time.time()
                S["last"] = 0
            elif ans is None:
                S["flash"], S["flash_at"] = "cancelled", time.time()
    finally:
        try:
            print("\033[?1007l\033[?1006l\033[?1002l\033[?1000l", end="", flush=True)
        except Exception:
            pass


if __name__ == "__main__":
    import sys
    repo = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    skill = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    try:
        curses.wrapper(main, repo, skill)
    except KeyboardInterrupt:
        pass
