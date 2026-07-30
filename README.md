```
   ███╗   ██╗██╗ ██████╗ ██╗  ██╗████████╗███████╗██╗  ██╗██╗███████╗████████╗
   ████╗  ██║██║██╔════╝ ██║  ██║╚══██╔══╝██╔════╝██║  ██║██║██╔════╝╚══██╔══╝
   ██╔██╗ ██║██║██║  ███╗███████║   ██║   ███████╗███████║██║█████╗     ██║
   ██║╚██╗██║██║██║   ██║██╔══██║   ██║   ╚════██║██╔══██║██║██╔══╝     ██║
   ██║ ╚████║██║╚██████╔╝██║  ██║   ██║   ███████║██║  ██║██║██║        ██║
   ╚═╝  ╚═══╝╚═╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝╚═╝        ╚═╝

        you go to bed  ·  work happens  ·  you wake up to pull requests
```

Hand a feature to an agent and walk away.

One `claude` process per git worktree takes a brief, decomposes it, dispatches its own
tiered worker agents, verifies its own work, and opens a pull request. It runs for hours
or days and asks you nothing. When it hits something it must not decide alone, it parks
that task with the exact command you would need and moves to the next one.

You get a short decision queue in the morning instead of a 3am interruption. Several run
at once on different features.

## Install

Open Claude Code in the repo you want PMs to work on and paste this. Claude does the rest.

```text
Install nightshift: run /plugin marketplace add camkeith/nightshift then
/plugin install nightshift@nightshift. Then read AGENTS.md from that plugin and add a
"nightshift" section to this repo's CLAUDE.md stating: nightshift runs autonomous feature
PMs, one claude process per git worktree; a PM's identity is its LEDGER.md, not its
session; a PM never pushes, merges, or opens a PR into the release branch; on a blocker it
parks and continues rather than halting or working around; pm-provision.sh and
pm-launch.sh need the sandbox disabled, which an agent can request; they do not need a
human's terminal, but the ! prefix is sandboxed and will not work. Finally, check whether .nightshift/repo-facts.md exists in this repo, and if it
does not, tell me it needs generating before the first PM runs.
```

Prefer to do it by hand, or want it without the plugin system:

```bash
git clone https://github.com/camkeith/nightshift.git ~/.claude/skills/nightshift-src
ln -s ~/.claude/skills/nightshift-src/skills/nightshift ~/.claude/skills/nightshift
```

## Use

Plan however you like: an OpenSpec change, a spec file, or just a conversation in Claude
Code. Then hand it off.

```
/nightshift
```

That is the whole interface. In your session, nightshift will:

1. **Take the goal** from the OpenSpec change you name, a plan file you point at, or the
   conversation you are already in. It plays the brief back in its own words rather than
   making you retype it.
2. **Check this repo's facts file** exists. If it does not, it stops and generates one,
   then asks you to read it before going further. That happens once per repo, and it is
   the one thing worth your attention: everything a PM does afterwards rests on it.
3. **Ask one confirmation.** Slug, brief, which packages to install, base branch and ship
   boundary, whether to enable workflows, and anything it already knows will block. It
   says out loud that this is the last question.
4. **Provision a worktree and launch** a supervised PM.
5. **Hand back and stop.**

Then it runs unattended, for hours or days. **It does not ask you anything else.** On a
hard stop, a missing credential, something destructive to shared state, or a production
deploy path, it parks that task with the exact command you would need to run and moves to
the next unblocked one. You get one batched decision queue instead of a 3am interruption.

Kickoff is also the only moment the sandbox matters. Package installs and tmux need it
disabled, and you are sitting there to approve that in one keystroke. Nothing after
kickoff needs you.

### Checking on it

```bash
NS=~/.claude/skills/nightshift/scripts

bash $NS/pm-top.sh                       # interactive: drill into a PM, its workers, its output
bash $NS/pm-status.sh                    # one-shot snapshot, blockers first
bash $NS/pm-launch.sh <slug> --stop      # stop one
```

A PM stops on its own when it reaches `READY-FOR-HUMAN` or `DONE`.

### Without leaving Claude Code

`/nightshift` starts a watcher for you at kickoff. Claude Code's footer is arrow-navigable
and background tasks are one of the things that populate it, so the watcher is an entry
you can reach with the keyboard:

| Key | Action |
|---|---|
| `down` | move into the footer |
| `left` / `right` | move between footer entries |
| `enter` | open the selected one and read its output |
| `esc` | back to the prompt |

It prints one line per state change, not per poll, so opening it shows a history of what
moved rather than the same three rows stamped a hundred times.

For the full view over the top of Claude Code, `pm-overlay-install.sh` binds a tmux key to
float `pm-top` above the session; Esc drops you back exactly where you were.

### Switching inference provider

Each PM defaults to Claude. When Claude is out of tokens (or you want a different host),
switch that PM manually and restart:

```bash
bash $NS/pm-launch.sh <slug> --provider codex     # or cursor, or claude
# equivalent: PM_PROVIDER=codex bash $NS/pm-launch.sh <slug>
```

The choice is persisted on the registry claim. Prefer `--once` after a switch before
leaving the supervised loop running. Codex and Cursor run the same ledger-driven loop;
they do **not** get Claude Code's `Agent` / `Workflow` tools or the nightshift skill
auto-load. Cost tracking stays accurate for Claude and is best-effort elsewhere.

### Driving it directly

`/nightshift` is a wrapper around three scripts. Run them yourself if you want more
control. They need the sandbox disabled, so either a terminal or an agent with approval.

| Command | What it does |
|---|---|
| `pm-provision.sh <slug> "<brief>" [pkg ...]` | Claim a slot, build a verified worktree, write the ledger skeleton |
| `pm-launch.sh <slug>` | Start the supervised loop: tmux + caffeinate + restart wrapper + watchdog |
| `pm-launch.sh <slug> --once` | One wake in the foreground. Do this before trusting the loop |
| `pm-launch.sh <slug> --stop` | Stop that PM |
| `pm-launch.sh <slug> --provider …` | Set/persist `claude`, `codex`, or `cursor` for that PM |
| `pm-status.sh [slug]` | Every PM on one screen, blockers first (shows `[provider]`) |
| `pm-top.sh` | Interactive. Arrow through PMs, `<-/->` panes, enter to open a worker |
| `pm-watch.sh` | One line per state change. Run it in the background to get a footer entry you can arrow into |
| `pm-overlay-install.sh` | Bind a tmux key to float `pm-top` over Claude Code; Esc returns |
| `pm-teardown.sh <slug>` | Retire a PM safely: stop, remove, prune, mark done |

`PM_WORKFLOWS=1` before `pm-launch.sh` grants the PM standing Workflow orchestration
(Claude only). Off by default on cost grounds, not capability: a PM wakes at least 24
times a day, and it already has parallel agent dispatch for ordinary fan-out.

**Agents: read [`AGENTS.md`](AGENTS.md).** Entry points, invariants, environment
constraints, and the state model, without the prose.

## Why the facts file exists

`repo-recon` does not summarize your codebase. It hunts the narrow class of facts that
produce **wrong results with no error message**: test suites that wipe a shared database,
dev proxies pinned to a literal host, linters that exit 0 regardless, deploy workflows
with nothing gating them, commands whose error messages misdiagnose the problem. It must
cite a command or `file:line` per claim and quarantine anything it could not verify.

Your `CLAUDE.md` is not a substitute. It records how you want to work. It records almost
nothing about how your repo misbehaves, because those facts are learned by failure and
nobody writes down what already bit them. That gap is what an unattended agent falls into.

On a real second repo, recon's headline finding was *"this working tree is 1411 commits
behind origin, and every local signal says it is current."* A PM would have branched from
a year-old base and produced a PR conflicting with everything, having seen nothing wrong.

## Design, in three claims

**A PM is a top-level `claude` process, not a subagent.** Measured, not assumed: a
subagent cannot dispatch background or named workers (`"In-process teammates cannot spawn
background agents"`) and has no `Workflow` tool. A PM built as a subagent serializes every
worker onto its own clock.

**Durability comes from the OS, not the harness.** Nothing in Claude Code survives a
closed laptop lid; `/loop` wakeups live in memory. So `pm-launch.sh` is `caffeinate` plus
tmux plus a restart wrapper plus a dead-PM watchdog. Claude supplies pacing; the
supervisor supplies survival.

**A PM's identity is its ledger file, not its session.** Each wake is a fresh provider
process (`claude -p`, `codex exec`, or `cursor-agent -p`)
that reads `LEDGER.md` and continues. That makes "resume from files" true by construction
rather than by discipline: a fresh process cannot lean on session memory, so an
insufficient ledger breaks visibly on wake 2 instead of silently on day 2 after a
compaction.

## What it will not do

By design, and these are the interesting parts:

- **It never touches your release branch.** Ship boundary is a PR into your staging branch.
- **It parks rather than halts.** On a blocker (missing credential, destructive to shared
  state, production deploy path) it logs the blocker with the exact command you need to
  run, then moves to the next unblocked task. You wake to progress plus a decision queue,
  not an eight-hour stall.
- **It never invents a workaround for a missing credential**, and never weakens a test or
  deletes an assertion to get past a finding.
- **It leaves manual-QA boxes unchecked.** A PM that cannot run a browser says so instead
  of checking a box it did not verify.
- **It does not change shared machinery on its own.** When it finds a defect in nightshift
  itself, it writes ranked options and stops. That happened on the first real run.

## Contents

```
AGENTS.md           START HERE if you are an agent: entry points, invariants,
                    environment constraints, state model. No prose.
.claude-plugin/     plugin + marketplace manifests
agents/
  repo-recon.md     generates a repo's facts file, with a verification contract
skills/nightshift/
  SKILL.md          the policy and the loop. A PM reads this, not AGENTS.md
  references/
    decision-policy.md      what to answer at each substituted human gate
    ledger-schema.md        LEDGER.md and the cross-PM registry
    repo-facts.example.md   a real facts file from a production repo, anonymized
    ledger.example.md       a real ledger from a real wake, anonymized
  scripts/
    pm-provision.sh   claim a slot, build a verified worktree
    pm-launch.sh      tmux + caffeinate + restart wrapper + watchdog
    pm-status.sh      every PM on one screen, blockers first
```

Two audiences, deliberately separated. `AGENTS.md` is for an agent deciding what to do
with nightshift. `skills/nightshift/SKILL.md` is for the PM itself while it runs. An agent
evaluating the tool does not need the wake loop, and a running PM does not need install
instructions.

Both `.example.md` files are real artifacts, not illustrations. The ledger is from the
first live run, in which the PM found six defects in nightshift itself, including one
where the watchdog would have restarted healthy PMs onto their own branches. It reported
them and declined to fix them. That is the behavior the whole design is for.

## License

MIT. See [LICENSE](LICENSE).

## Status

Version 0.1.0. Working but young, and the gap between those two matters here.

**Exercised against real repos:** provisioning, single wakes, the supervised loop, the
status view, and `repo-recon` against a second unfamiliar codebase (a Python plus Node
plus Terraform project sharing no stack with the one nightshift was built on).

**Not yet done: no feature has gone brief to pull request.** Everything proven so far is
infrastructure. The central claim, that a PM can take a brief, write code, verify it, and
open a PR unattended, has not been demonstrated end to end.

**Per-repo setup is derived, not hand-edited.** `pm-config.sh derive` inspects the repo
and writes `.nightshift/config.json` from evidence: env files are those that exist locally
and are git-ignored (exactly what a fresh worktree lacks), packages are directories with a
`package.json`, frontends are vite configs actually present. It is written
`"confirmed": false` and provisioning refuses until you read it, because a missing env
file yields a worktree that looks fine and cannot run anything.
