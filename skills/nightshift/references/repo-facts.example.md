# acme-app: facts a PM must know

Repo root: `/path/to/acme-app`

Every claim here was verified by running the command or reading the cited line. Where a
line number is given, re-read it if something surprises you; the repo moves.

## Contents

1. Silent-corruption hazards (read this section every time)
2. Tests and lint
3. Ship boundary and CI
4. Worktree provisioning
5. Things that are denied, and the right verb instead
6. OpenSpec in this repo
7. Stale documentation and false facts

---

## 1. Silent-corruption hazards

These produce **wrong results with no error**. They are listed first because a normal
error is survivable and these are not: you will confidently build on top of them.

### 1.1 The shared test database. This is the worst one.

Nine locations in `api/src` resolve their test DB the same way:

```js
process.env.TEST_MONGODB_URI || 'mongodb://localhost/acme_test'
```

and `api/src/worker/__tests__/worker-resilience.test.js:41` runs an unconditional
`await Job.deleteMany({})` in `beforeEach` (again at :222).

So two PMs running `npm run test:unit` at the same moment share one database and one
wipes the other's fixtures mid-run.

**Always export `TEST_MONGODB_URI=mongodb://localhost/acme_test_<your-slug>`.**
`pm-provision.sh` writes this into your worktree; verify it is set before your first
test run.

The danger is not the data loss, which is bounded (no `dropDatabase` exists anywhere in
`api/src`). The danger is that **the symptom is a flaky test failure in your own feature
branch.** An autonomous PM will diagnose that as a real bug in its own code and "fix" it,
laundering a concurrency collision into a spurious source change that then gets reviewed
and merged. When a test fails unexpectedly, ask "is this mine?" before "how do I fix it?"

### 1.2 The vite proxy target is hardcoded

Three configs pin the API to one address:

- `public-client/vite.config.js:14`
- `admin-client/vite.portal.config.js:34`
- `admin-client/vite.console.config.js:33`

all `target: 'http://localhost:9090'`.

If you start a frontend on your own port, its API calls still hit **whatever process owns
9090**, which is probably the human's dev stack or another PM's. The frontend looks like
it works perfectly. Every QA conclusion is about the wrong code.

Note that the API port itself *is* overridable (`api/src/shared/config/index.js:27` reads
`parseInt(process.env.PORT, 10) || 9090`), and vite ports take `--port`. The proxy target
is the only genuinely hardcoded value, and parameterizing it means editing shipping
config in service of tooling. Do not do that as a side effect of a feature.

### 1.3 Do not run dev servers

Follows from 1.2. All five dev ports (9090, 8081, 3001, 3100, 3200) are typically bound
by the human's live stack.

**PMs run tests only.** No `npm start`, no `dev`, no `vite`, no `expo start`.

Consequence you must respect rather than route around: `client/`, `admin-client/`, and
`public-client/` have thin-to-absent test coverage, so browser QA is their only real
verification, and you cannot do browser QA. **Write the frontend code, then leave the
visual-QA task unchecked and flagged for the human.** There is precedent for exactly this
honesty in the repo: `openspec/changes/upgrade-coach-cluely-hud/tasks.md` item 6.3 is
still unchecked because it needs a live meeting room, on a change otherwise complete.
Checkbox state is the completion record; a claim of "done" is not.

### 1.4 Never run bare `docker compose` commands

The root `docker-compose.yml` uses fixed container names and fixed host ports.
`docker-compose.scan.yml` carries comments recording a real incident where operating on
it without a distinct project name **killed dev Redis three times**.

A bare `docker compose down` can kill the human's Redis and every other PM's. Redis here
is a Docker Desktop container, not brew (Mongo is brew; do not confuse the two).

### 1.5 Sandbox failures wear convincing disguises. This is the big one.

Building this skill produced **six** distinct failures across six subsystems. All six had
one cause: the sandbox. **Not one error message contained the word "sandbox."**

| what was attempted | what the error said | what it looked like |
|---|---|---|
| `chmod +x` under `~/.claude/skills` | `Operation not permitted` | file ownership |
| `gh api` | `x509: OSStatus -26276` | TLS / network |
| `gh auth status` | `The token in keyring is invalid` | expired credentials |
| `mkdir ~/.claude-worktrees/...` | `Operation not permitted` | directory permissions |
| `git worktree add -b X ... origin/develop` | `could not lock config file .git/config` | a stale git lock |
| `git checkout` of `.claude/commands/*` | `unable to create file ...` | a corrupt worktree |
| `npm install` | `EPERM ... your cache folder contains root-owned files` | a broken npm cache |

The last one is the most dangerous, because npm's message does not just misdiagnose, it
**prescribes a harmful fix**: `sudo chown -R 501:20 "$HOME/.npm"`. The cache is not
root-owned. An agent that trusted that message would run a pointless recursive `sudo
chown` across a home directory, or park on a credentials problem that does not exist.

Two rules follow, and they matter more than any other line in this file:

1. **Never diagnose infrastructure from error text.** If a tool that should work doesn't,
   suspect the environment before the credential, the file mode, or the lock.
2. **Never run a remedy an error message suggests** when the failure could be
   environmental. No `sudo chown`, no `gh auth login` (it hangs forever unattended), no
   deleting a lock file, no reinstalling a cache.

A capable agent applying the *correct* documented heuristic ("does this look like a
sandbox failure?") examined the `gh` keyring error and concluded it was not sandboxed. It
was. Generic heuristics lose to specific local knowledge, which is the entire reason this
file exists.

#### What actually works, measured

- Writes are permitted only within the repo (cwd) and `$TMPDIR`. `~/.claude-worktrees`
  and `~/.claude/skills` are denied.
- Inside the repo, `.claude/commands` and `.claude/hooks` are denied **at any depth**,
  which is why worktrees use sparse-checkout to exclude `.claude/`. Git tracks only three
  files there and a PM needs none of them.
- `~/.npm/_logs` is writable but `~/.npm/_cacache` is not, so **`npm install` cannot run
  inside a sandboxed session at all.**
- `git fetch` over SSH cannot work sandboxed (`nc: authentication method negotiation
  failed`). Branch from the local base instead; that is correct behavior, not degraded.
- `.git/config` writes are denied, so never use `git push -u` or anything else that sets
  upstream tracking. Name the remote explicitly instead.
- `gh` works, because `api.github.com` is allowlisted and `enableWeakerNetworkIsolation`
  is on in `~/.claude/settings.json`.

#### Therefore: provisioning is a human step, run outside Claude

`pm-provision.sh` must run from a real terminal. Not from inside a Claude session, and
**not via the `!` prefix**, which is sandboxed too and fails silently in a way that looks
like nothing happened at all. Once provisioned, a PM operating in its worktree is fine:
it runs tests against existing `node_modules` and never needs the npm cache.

### 1.6 `grep -r` lies about `~/.claude/skills`

Every gstack `SKILL.md` there is a symlink into `~/Desktop/CS Projects/Claude/Skills/`.
BSD `grep -r` does not follow symlinks while recursing, so it reports **zero** matches
across the whole suite. Measured: `-r` found 0 files, `-R` found 112.

**Use `grep -R` for that tree.** Never conclude "this feature does not exist" from a `-r`
miss.

---

## 2. Tests and lint

| what | command | notes |
|---|---|---|
| api unit tests | `npm run test:unit:ci` in `api/` | mocha, `--reporter min --timeout 60000`. Needs live Mongo. |
| api unit (verbose) | `npm run test:unit` in `api/` | same suite, full reporter |
| client-ish tests | `npm run test:client` in `api/` | mocha over `../client/**/__tests__` |
| lint | `npx eslint .` **run from `api/`** | the local binary resolves from there |

**`npm test` is NOT the unit suite.** In `api/package.json` it is `cypress run`. Anything
claiming `npm test` runs Jest is stale; see section 7.

### Run tests with the sandbox OFF. This is settled policy.

Ratified 2026-07-29 after measurement. Same commit, same suite:

| run | result | wall clock |
|---|---|---|
| sandboxed | 5790 passing, 32 pending, **23 failing** | 9m |
| unsandboxed | 5876 passing, 3 pending, **0 failing** | 3m |

Every one of those 23 failures was fabricated by the sandbox. Worse, ~86 tests never ran
at all: a dead `before all` hook strands its entire suite, so a sandboxed run silently
under-reports the total as well as inventing failures. The 3x wall clock is each blocked
hook burning its full 10-15s timeout.

```bash
cd api && export TEST_MONGODB_URI=mongodb://localhost/acme_test_<slug>
npm run test:unit:ci        # with dangerouslyDisableSandbox: true
```

Scope it to test execution against your own test DB. Nothing else gets a blanket
sandbox-off pass. With the sandbox off, the global deny list (`rm -rf`, `git push
--force`, `git reset --hard`, `git clean -f`, `git checkout .`, `git restore .`) is the
real boundary, so treat it as load-bearing rather than as a formality.

Two operational traps, both found the hard way:

- **`$TMPDIR` differs between sandboxed and unsandboxed runs.** A log written to
  `"$TMPDIR/x.log"` unsandboxed is unreadable from a later sandboxed command, and looks
  exactly like the run produced nothing. Redirect to an absolute path under `/tmp/claude/`,
  which both modes reach.
- **Bound every unsandboxed mocha run with `timeout N`.** A multi-file run hung past five
  minutes, was SIGTERM'd, and left no recoverable partial log, costing the whole probe.

### Read the summary line, in both directions

`repo-facts` used to warn only that this suite exits 0 unreliably, so watch for false
green. Measurement found the opposite hazard fires harder: a **false red of 23 fabricated
failures**, with an honest exit code (23, matching the count) both times.

That inversion matters because the two demand opposite reflexes. A false green teaches
"distrust success and dig". A false red on your own branch teaches "I broke something",
which is the reflex that gets a PM editing working source at 3am. Guard both. Read the
summary line, never pipe through `tail` (it masks exit status), and settle authorship
structurally before interpreting anything:

```bash
git merge-base --is-ancestor HEAD develop && echo "no unique commits: no failure can be mine"
```

The subtlest case is worth naming: among the 23, three presented as clean product bugs
(`expected '' to equal 'https://example.com/img/...'`) with no `EPERM` or `Timeout`
anywhere. The empty string was a blocked fetch. **Nothing distinguished those from a real
regression except running them outside the sandbox.**

**Lint debt is contagious.** CI lints changed files, so a one-line edit to a file drags
that file's entire existing ESLint debt into your PR. Budget for it or keep the edit out
of that file.

Neither client is meaningfully linted (eslint exits 0 there). Do not read that as clean.

---

## 3. Ship boundary and CI

### You never touch `main`

Measured, not assumed:

- `main` has zero branch protection (branch protection is unavailable on this account's plan).
- Zero workflows use `environment:` protection (`grep -n "environment:" .github/workflows/*.yml` finds nothing).
- All five `deploy-*.yml` fire on push to `main` with **no `concurrency:` guard**, so two
  deploys interleave.
- `the terraform-apply workflow` runs `terraform apply -auto-approve` against state shared across
  demo and every env.

The repo's own CLAUDE.md says to push to `main` without waiting for approval. **This
skill overrides that instruction**, because it was written for a supervised foreground
agent and for you a push to `main` is always a production deploy.

### What you do instead

```bash
git push -u origin <branch>     # explicit remote; never a bare `git push`
gh pr create --base develop ...
gh pr merge ...
```

Use `-u origin` explicitly: several branches here are configured against a personal
`personal-backup` remote, and an implicit push can send your work somewhere CI never
sees it.

**Base branch: settled.** Always `develop`. Confirmed by the human 2026-07-29:
*"i ship releases into main so thats why i stage everything on develop."*

So the pattern is two-tier. Feature work stages on `develop`; a separate release PR
promotes `develop` into `main`. That explains why recent PRs (#82, #83, #84) show
`baseRefName: main` without contradicting anything: those are releases, not features.

**Releases are the human's, always.** A PM never opens or merges a PR into `main`, and
never proposes one. If a feature appears to need `main` directly, that is a blocker, not
a judgment call: park it and ask.

CI reality: `ci-api.yml` only runs on PRs touching `api/**`. The three frontends get no CI
signal at all. `develop` was green as of the last check.

---

## 4. Worktree provisioning

Standard location: `<repo>/.claude/worktrees/pm-<slug>`, with the registry alongside at
`<repo>/.claude/worktrees/registry/<slug>.json`.

Inside the repo, not under `~`, because a sandboxed session can only write within its cwd
and `$TMPDIR`. See 1.5. `.claude/` is gitignored (`.gitignore:204`) and `.claude/worktrees`
was already an existing convention here. Note the deny list covers `.claude/settings.json`,
`.claude/hooks`, `.claude/skills`, and `.claude/commands`, but **not** the `worktrees`
subtree, so a PM writing files in its own worktree is unaffected.

There are already 20 worktrees across six conventions, twelve of them `prunable`, several
in `/private/tmp` (purged on reboot). **`git worktree prune` before allocating**, and do
not invent a seventh convention.

A fresh worktree does **not** get these four gitignored files. Copy them explicitly:

```
api/.env
client/.env
public-client/.env
admin-client/.env.local
```

Real failure mode, not hypothetical: `~/.claude-worktrees/acme-app/priceless-cohen`
has sat since January with no `node_modules` in `api/` or `client/`. Provisioning
silently never happened and nobody noticed.

**Install only the packages in your feature's blast radius.** This is not an npm
workspace and there is no hoisting, so a full install is about 1.75G (api 530M, client
757M, public-client 247M, admin-client 195M, root 21M). An api-only feature installing
only `api/` saves roughly 3x on disk and time.

`git worktree add` touches the one shared `.git`, so two simultaneous adds contend on
`index.lock`. `pm-provision.sh` serializes this behind a lock.

---

## 5. Denied commands, and the right verb instead

These are hard denies in the human's global settings. Hitting one stalls you:

`git push --force`, `git push -f`, `git reset --hard`, `git clean -f`, `git clean -fd`,
`rm -rf`, `git checkout .`, `git restore .`

Consequences you must plan around:

- **Clean up worktrees with `git worktree remove` / `git worktree prune`, never `rm -rf`.**
- You cannot force-push, so never create a situation that needs one. Prefer a fresh
  branch over rewriting a pushed one.
- You cannot `reset --hard` your way out of a mess. Commit early and often so every state
  is recoverable by checkout.

`npm run worker:*` is also denied, correctly: **importing a worker boots it and sends real
email.** Verify worker code through the mocha suite only.

Never run `npm audit fix --force` on either client.

---

## 6. OpenSpec in this repo

It is real and load-bearing: 91 active change directories, 64 archived, 66 specs.
`tasks.md` is a git-committed, checkbox-granular ledger that already survives everything
compaction can do to you. Do not invent a parallel format.

**91 open changes means `openspec/changes/` is as much a graveyard as a queue.** The
existence of a change directory is weak evidence that the work is live. Check git history
on it before assuming anything is in flight.

---

## 7. Stale documentation and known-false facts

- **`openspec/project.md` is provably wrong.** It claims Jest and `npm test` from `/api`.
  Reality is mocha via `test:unit:ci`, and `npm test` runs Cypress. Read `changes/` and
  `specs/` directly instead.
- **Redis is Docker Desktop**, not brew, and not necessarily the service described in the
  root `docker-compose.yml`. Mongo is the brew one, on 27017.
- **Prod DB is a managed cloud database and VPC-only**, unreachable from this laptop. Any task needing
  prod data is a credentials blocker, not a puzzle to solve.
- The `interactive: true` frontmatter flag is not a reliable signal of whether a skill
  will block. Only four skills declare it, but `review`, `qa`, `ship`, `browse`,
  `investigate`, and `autoplan` all call `AskUserQuestion` between 11 and 40 times each.
  Gate on the `OPENCLAW_SESSION` lever, not on the flag.
