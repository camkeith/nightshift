# Substituted decisions

Every skill you compose was written expecting a human to answer at certain points. You
are what answers now. This file is the pre-agreed answer for each known gate.

**Log every substituted decision in the ledger under `DECISIONS`, with the reasoning.**
That log is the only way the human can audit a night's judgment after the fact, and it is
what makes the difference between "the PM built something" and "the PM built something I
can trust". A decision you made and did not record is indistinguishable from a decision
you got lucky on.

## How to decide when this file does not cover it

Apply the human's own design pass, in order. It is in the repo CLAUDE.md and it is how he
actually thinks:

1. **Make the requirement less dumb.** Challenge anything that does not make sense, and
   note who it came from. A brief is not scripture.
2. **Delete any part you can.** Be aggressive; it can be added back.
3. **Simplify what remains.**
4. **Accelerate the cycle time.**
5. **Automate,** but only after 1 through 4.

Then apply the two standing constraints: simplest thing that works wins, and every changed
line must trace to the brief.

**The escape hatch matters as much as the policy.** If a decision is outside this file
*and* getting it wrong would be expensive or hard to reverse, that is a blocker, not a
judgment call. Park it, record the options you saw and what each would cost, and move on
to other work. Guessing on an unbounded question is exactly how a PM spends two days
building the wrong thing, and that failure is the hardest of all to spot from a ledger.

---

## The gate table

| Gate | Where it comes from | Your answer |
|---|---|---|
| **Plan conflicts with the code at pre-flight** | SDD pre-flight check | If the conflict is factual (the plan names a file or function that does not exist), fix the plan, record the correction, continue. If it is a design conflict (the plan's approach cannot work), **park**: this invalidates the premise and building on it wastes the whole run. |
| **A review finding contradicts the plan text** | SDD mid-loop | Trust the code over the plan. Plans are written before the author sees the code. Amend the plan, record why, continue. |
| **A load-bearing finding survives the fix cap** | SDD, 5 rounds then "STOP: report BLOCKED" | Park that sub-plan, record the finding verbatim, move to another. **Never resolve it by weakening a test or deleting an assertion.** Precedent: commit `810d8f52`, "drive the web scan to FAIL 0 without weakening the evidence". |
| **Merge / deploy decision** | gstack `ship`, `land-and-deploy`, `finishing-a-development-branch` | Do not call those skills unattended at all. Your ship boundary is fixed: PR into `develop`, merge it, stop. `main` is never yours. |
| **Which change to archive** | `openspec-archive-change` ("do NOT guess") | Never archive. Archiving is a human act after deployment. |
| **A task needs manual or browser QA** | tasks.md items on frontend work | Leave the box **unchecked**, tag it `NEEDS-HUMAN-QA` in the ledger, continue. Do not check a box you did not verify; that corrupts the only completion record that exists. |
| **A credential is missing or expired** | AWS SSO expiry, prod DocumentDB, Stripe live keys, PostHog scopes | Park with the exact command the human must run. **Do not fake around it** (repo CLAUDE.md is explicit). Do not run an interactive re-auth; it hangs forever. |
| **A test fails and might be pre-existing** | any suite run | Check `develop` for the same failure before touching source. If pre-existing, record it and route around; it is not your bug. See repo-facts 1.1 for why this matters more than it sounds. |
| **The feature seems to need a `main` PR** | ship boundary ambiguity | Park and ask. The base-branch question is genuinely unresolved (see repo-facts section 3). |
| **The feature needs a terraform change** | `infrastructure/terraform/**` | Write the `.tf` and include it in the PR if the feature truly requires it. **Never run `terraform apply` or `destroy` locally, even with `-target`.** Flag the PR as infra-touching. |
| **A new runtime dependency is needed** | implementation | Add it if it is well-known, actively maintained, and genuinely load-bearing. Prefer the standard library or an existing dependency. Record the addition explicitly; a surprise dependency in a PR is a bad way for the human to learn about it. |
| **A database migration or schema change** | implementation | Additive changes (new optional field, new collection) proceed. **Destructive changes (dropping, renaming, or retyping an existing field) park.** They are irreversible against shared state, which is a named hard stop. |
| **Existing behavior must change to fit the feature** | implementation | If the brief implies it, proceed and record it prominently. If it does not, park. Silently changing behavior the human did not ask about is how a feature PR becomes unreviewable. |
| **Scope is growing past the brief** | anywhere | Stop expanding. Record the extra work as a follow-up in the ledger. Delivering the brief and naming what you left out beats delivering something larger nobody asked for. |
| **The brief is ambiguous between two readings** | kickoff | If both readings cost about the same, pick the simpler one, record the assumption prominently, and continue. If they diverge materially in effort or blast radius, **park at kickoff** rather than after two days of work. Parking early is cheap; parking late is not. |

---

## Standing answers to recurring prompts

Skills in auto-choose mode (`OPENCLAW_SESSION=true`) will pick "the recommended option"
for you. Usually that is fine. These are the cases where it is not, and where you must
not let a skill decide:

- **Anything that merges, deploys, pushes to `main`, or runs terraform.** Recommended is
  not safe here, because there is no branch protection and no deploy concurrency guard to
  catch a mistake. Never delegate this to a skill's default.
- **Anything that deletes.** Prefer marking obsolete and letting the human delete. You
  cannot `rm -rf` or `reset --hard` anyway, so a deletion you commit is harder to undo
  than usual.
- **Anything touching auth, permissions, or a public surface.** The repo CLAUDE.md names
  turning on a public or no-auth surface as a hard stop. Park it, even if it looks minor,
  and especially if it looks minor.

## What "park" means, precisely

Not "stop working". Parking one task and continuing on others is the whole point of the
policy: it is what lets an eight-hour unattended run produce seven hours of useful work
plus a decision queue, instead of one hour and a stall.

To park:

1. Mark the task `BLOCKED` in `LEDGER.md` with the reason, and the exact command or
   decision needed to unblock it.
2. Record which other tasks now transitively depend on it, so the human can see the real
   cost of the blocker rather than just its existence.
3. Move to the next unblocked task.
4. If the PR into the base branch is open or merged and BLOCKERS are empty, write
   `STATUS: DONE` (keep any NEEDS-HUMAN-QA items listed). If nothing is unblocked and
   you cannot open/finish that PR, write `READY-FOR-HUMAN` at the top of the ledger and end the
   loop cleanly. Do not idle-poll a blocked ledger for hours.
