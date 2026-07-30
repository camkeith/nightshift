# nightshift — autonomous feature PMs

nightshift runs long-lived autonomous "PMs". One `claude` process per git worktree takes
a feature brief, decomposes it, dispatches its own worker agents, verifies its own work,
opens a pull request, and keeps going for hours or days unattended. Several run at once
on different features.

If you are an agent reading this to decide what to do, read this file top to bottom. It
is short on purpose. The deep material is in `skills/nightshift/`.

---

## Two modes

The skill branches on who invoked it. Get this right before doing anything else.

| Mode | Trigger | Questions allowed? |
|---|---|---|
| **Kickoff** | A human types `/nightshift` in their own session | **Yes, exactly once.** This is the only interactive moment in the whole system. |
| **Wake** | `pm-launch.sh` runs `claude -p "You are PM <slug>..."` | **No.** Nobody is there. Park blockers to the ledger and continue. |

Intended flow: a human plans (often an OpenSpec change), types `/nightshift`, answers one
confirmation, and walks away. Everything after that is unattended until the PM hits a
blocker or opens its PR.

Kickoff runs `pm-provision.sh` and `pm-launch.sh` with the sandbox disabled. That is safe
*there and only there*, because the human is present to approve it, and it is the reason
setup happens at kickoff rather than mid-run.

## Entry points

| Command | What it does |
|---|---|
| `bash scripts/pm-provision.sh <slug> "<brief>" [pkg ...]` | Claim a slot, build a verified worktree, write the ledger skeleton. Refuses to hand over a half-built tree. |
| `bash scripts/pm-launch.sh <slug>` | Start the supervised loop: tmux + caffeinate + restart wrapper + dead-PM watchdog. |
| `bash scripts/pm-launch.sh <slug> --once` | Run exactly one wake in the foreground. Use this before trusting the loop. |
| `bash scripts/pm-launch.sh <slug> --stop` | Stop that PM's tmux session. |
| `bash scripts/pm-status.sh [slug]` | Every PM on one screen, blockers first. The breakfast view. |
| `agents/repo-recon.md` | Agent definition. Generates a repo's `.nightshift/repo-facts.md`. Run once per repo. |
| `skills/nightshift/SKILL.md` | The PM's own operating manual. A PM reads this, not this file. |

Scripts live in `skills/nightshift/scripts/`. Invoke with `bash`; the executable bit may
not survive installation.

`PM_WORKFLOWS=1` before `pm-launch.sh` grants the PM standing Workflow orchestration. Off
by default on cost grounds, not capability.

---

## Before anything else: the repo's facts file

nightshift reads `<repo>/.nightshift/repo-facts.md` first, every wake. **If it does not
exist, generate it before doing any other work.**

Dispatch `agents/repo-recon.md` against the repository with this contract, and do not
relax any part of it:

```text
Read agents/repo-recon.md from the nightshift plugin and follow it exactly against this
repository. Write the result to .nightshift/repo-facts.md. Cite a command or file:line
for every claim. Quarantine anything you cannot verify in an UNVERIFIED section rather
than stating it in the body. Use grep -R, never grep -r. Do not diagnose from error text
alone, and never run a remedy an error message suggests. Finish by naming the three
claims you are least confident about.
```

Then **stop and have a human read it** before any PM runs. That review is not ceremony. A
generated facts file is the one input a PM trusts absolutely on every wake, which makes it
the one thing that must not be trusted blindly when produced. Recon on the repo this was
built against was confidently wrong four separate times, and every one of those errors was
plausible.

`CLAUDE.md` is not a substitute. `CLAUDE.md` records how a human wants to work.
`repo-facts.md` records how the repo misbehaves. Those are disjoint, and the second is
what gets unattended agents into trouble, because nobody writes down what already bit them.

---

## Invariants

Violating any of these is how an unattended run destroys work rather than producing it.

| Rule | Why |
|---|---|
| **Never push, merge, or open a PR into the release branch.** | Deploys usually fire on push there with no gate. Ship boundary is a PR into the staging branch, and that is the end of a PM's authority. |
| **Park, do not halt, do not work around.** | On a blocker (missing credential, destructive to shared state, production deploy path) log it with the exact command a human must run, then move to the next unblocked task. |
| **Never invent a workaround for a missing credential**, and never weaken a test or delete an assertion to get past a finding. | The point of a finding is that it found something. |
| **Verification stays with the dispatcher, never the doer.** | A worker reporting success is not evidence. Overnight there is no human backstop, so the PM is it. |
| **Leave manual-QA boxes unchecked.** | A PM that cannot run a browser says so. Checkbox state is the only completion record that survives compaction. |
| **Never change shared nightshift machinery on your own.** | Write ranked options into the ledger and stop. This has already happened once and the restraint was correct. |
| **Always pass `model` explicitly on every dispatch.** | Inheriting means paying top-tier rates for file-listing work, multiplied across days and PMs. |

---

## Environment constraints

Measured, not assumed. Ignoring these produces failures whose error messages name the
wrong cause.

- **`pm-provision.sh` and `pm-launch.sh` need the sandbox disabled**, not a human's
  terminal. An agent can run them itself with `dangerouslyDisableSandbox: true`. Sandboxed,
  package installs cannot write `~/.npm/_cacache` and the failure is misleading: hundreds of
  tar errors and a message blaming file ownership that recommends a `sudo chown` fixing
  nothing. Verified working unsandboxed.
- **Tests usually need the sandbox off.** Not because of dependencies, because of localhost
  TCP. Suites bind ports and connect to local databases; a sandbox denies both. One
  measured run produced 23 fabricated failures and silently skipped ~86 tests.
- **Never diagnose infrastructure from error text alone**, and never run a remedy an error
  message suggests when the cause might be environmental.
- **Use `grep -R`, not `grep -r`.** On macOS `-r` does not follow symlinks while recursing
  and returns silent false negatives.

---

## State model

A PM's identity is its **ledger file**, never its session. Assume context is compacted
away without warning.

```
<repo>/.claude/worktrees/pm-<slug>/LEDGER.md      one PM's memory, written for a stranger
<repo>/.claude/worktrees/registry/<slug>.json     cross-PM arbitration, one file per PM
<repo>/.nightshift/repo-facts.md                  this repo's landmines
```

Each wake is a fresh `claude -p` that reads the ledger and continues. That makes "resume
from files" true by construction: a fresh process cannot lean on session memory, so an
insufficient ledger breaks visibly on wake 2 instead of silently on day 2.

The **supervisor** owns every machine-readable field (`heartbeat`, `LAST WAKE:`). The
**PM** owns prose. A PM hand-editing header fields corrupts them, and a PM cannot write
the registry at all from inside a sandbox.

Only the PM writes in the ledger's own voice. Others may write into it, but every such
entry must be attributed at the point of writing. Unattributed content in the ledger's
authoritative voice is an instruction-injection surface, because the ledger is the first
thing a PM reads every wake.

---

## Reference material

| File | Read it when |
|---|---|
| `skills/nightshift/SKILL.md` | You are the PM. This is your operating manual. |
| `skills/nightshift/references/decision-policy.md` | You hit a gate that expects a human answer. |
| `skills/nightshift/references/ledger-schema.md` | You are writing the ledger or the registry. |
| `skills/nightshift/references/repo-facts.example.md` | Calibrating what a good facts file looks like. Anonymized; it is evidence, not a template. |
| `skills/nightshift/references/ledger.example.md` | Calibrating what a good wake produces. A real ledger from a real run. |
