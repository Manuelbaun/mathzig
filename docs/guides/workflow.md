> **Note:** Streams A/B/C are closed and documented in [`capabilities.md`](./capabilities.md) / [`quality.md`](./quality.md).  
> This guide is the multi-agent protocol for **new** programs only. Live board: [`docs/STATUS.md`](../STATUS.md).

# Specs implementation workflow

Orchestrator + subagents for a multi-task program. Every step (analyse, implement,
verify, refine) runs in a **subagent**. Progress and handoff live in **one
file** per unit: a `spec.md` (or equivalent). Agents **append** only; the orchestrator
reads the file and decides who runs next.

Related:

- Capabilities (what already shipped): [`capabilities.md`](./capabilities.md)
- Quality system: [`quality.md`](./quality.md)
- Project test protocol: root `AGENTS.md` (`bun run mz`)
- Short-term focus: `docs/FOCUS.md`

---

## Core idea: the spec is the bus

```text
                    ┌──────────────────────────────────────┐
                    │   specs/task-XX-…/spec.md            │
                    │   (append-only log of the cycle)     │
                    └──────────────────────────────────────┘
                         ▲ append          │ read
                         │                 ▼
   Analyst ──► Implementer ──► Verifier ──► (Refine loop) ──► Merge
                         ▲
                         │ spawn / resume
                    Orchestrator
                    (no product code; no long prose in chat)
```

- **Handoff = the spec file.** No separate brief documents. No “paste the
  SUMMARY in chat” as the source of truth.
- Each agent **reads the full current `spec.md`**, does its job, then
  **appends a dated section** (never rewrites another agent’s log).
- The orchestrator’s job is only: pick the unit, spawn the right agent with
  the right isolation/cwd, wait, re-read the spec, act on the latest
  verdict, merge when approved.

---

## Roles

| Role | Who | Responsibility |
|------|-----|----------------|
| **Orchestrator** | Primary agent (this session) | Pick next unit; spawn agents; read latest section in `spec.md`; enforce max refine rounds; merge per policy |
| **Analyst** | Subagent | Scope the unit; write the work plan **into `spec.md`** (in/out of scope, branch, worktree, acceptance, verify commands) |
| **Implementer** | Subagent (`isolation: "worktree"`) | Implement only what the Analysis section says; run gates; commit; **append** findings to `spec.md` |
| **Verifier** | Subagent (default: worktree `cwd`) | Diff + acceptance + gates review; **append** verdict and issues to `spec.md` |
| **Refiner** | Same implementer resumed (or new implementer on same worktree) | Fix open issues from the Verifier section; append refine report |
| **Human** | You | Merge/push policy; escalate after stuck refine loops |

Orchestrator does **not** implement product code in the main tree (except
merge conflict resolution). Subagents do **not** touch the human’s main
working tree except via orchestrator merge.

---

## Unit of work

Prefer **one `specs/task-*` per cycle** (C-chain dependency order).

Split a large task into sequential mini-cycles when needed (e.g. task-18 →
D1, D2, …). For a mini-cycle, either:

- use a dedicated section series under the same `spec.md` (e.g.
  `## Cycle: D1`), or
- a subfolder only if the parent task is huge — still one living log per
  active cycle.

Do **not** invent new historical `docs/tasks/*` items. New work lives under
`specs/task-*`. Prefer updating guides/capabilities + STATUS; avoid new historical task files.

---

## Branch and worktree convention (HARD RULE)

**Every task unit runs on its own branch inside a dedicated worktree.
Nothing for that unit is committed on `main` until the final merge after
APPROVE.**

| Do | Do not |
|----|--------|
| Create `spec/<task-id>-<slug>` from latest `main` | Commit Analysis / Implementation / Verify on `main` mid-cycle |
| Run Analyst, Implementer, Verifier, Refine **only** in that worktree | Edit product code or cycle-log sections on the human’s main checkout |
| Append cycle log on the **feature branch** | “Prep” task work onto `main` before APPROVE |
| Merge (FF preferred) **once** after APPROVE | Push to `origin` unless human asked (human owns origin sync) |

```text
branch:   spec/<task-id>-<short-slug>
worktree: dedicated path for this unit only

Examples:
  spec/task-18-d1-aot-env-alloc
  spec/task-18-d2-slice-step
  spec/task-12-standalone-budget
  spec/task-20-docs-truth
```

- **Base:** latest `main` (or previous successfully merged cycle tip) — read-only base.
- **Orchestrator opens the cycle** by creating branch + worktree (or spawning
  the first agent with `isolation: "worktree"` and fixed branch name).
- **All agents** for the unit use `cwd` = that worktree (or
  `isolation: "worktree"` on the same branch). One branch ↔ one worktree.
- **Main tree** stays clean for the duration of the cycle. Orchestrator may
  only read main for preflight / merge.

### Cycle open (orchestrator — before any agent writes)

```bash
# from repo root on clean main
base=$(git rev-parse main)
branch=spec/<task-id>-<short-slug>
wt=/path/to/worktrees/<branch>   # outside or under a worktrees dir

git branch "$branch" "$base"
git worktree add "$wt" "$branch"
# all subagents: cwd="$wt"  (or isolation worktree targeting this branch)
```

If the Analyst chooses the final slug, orchestrator may create a provisional
branch first (`spec/task-18-d2`) and rename once, still **never** writing the
cycle onto `main`.

### Cycle close (orchestrator — only after APPROVE)

1. Record tip from the worktree:

   ```bash
   commit_sha=$(git -C <worktree_path> rev-parse HEAD)
   git fetch <worktree_path> HEAD --no-tags   # no destination refspec, no --force
   git cat-file -t "$commit_sha"             # must print "commit"
   ```

2. Tear down the worktree **before** rewriting refs on main (merge).

3. On `main`: fast-forward (preferred) or merge commit of `$commit_sha`.
   Append `### Merge` on main **only as part of that merge result** (either
   already on the feature branch tip, or one tiny post-merge docs commit if
   Meta needs MERGED — prefer Merge section committed **on the feature
   branch** by orchestrator in the worktree right before merge).

4. Never force-push `main`. No `origin` push unless human asked.

---

## Spec file structure (append-only log)

`specs/task-XX-…/spec.md` starts with the durable task description (goal,
what to do, do-not-touch, acceptance). Below that, agents append **cycle
sections** in order. Never delete or silently rewrite a previous agent’s
section; corrections go in a new append.

### Static header (already present / human-edited)

```markdown
# task-XX — …

## Goal
…

## What to do
…

## Do NOT touch
…

## How to test
…

## Outcome / acceptance
- [ ] …
```

### Appended cycle log (agents own this)

```markdown
---

## Cycle log

### Meta
- unit: task-18 / D1
- status: ANALYSING | READY_TO_IMPLEMENT | IMPLEMENTING | READY_TO_VERIFY | VERIFYING | REVISE | APPROVED | REJECTED | MERGED
- refine_round: 0
- updated: 2026-07-15T12:00:00Z
```

Orchestrator (or the agent that finishes a step) updates **only** the
`### Meta` status fields so the next spawn knows the phase. Body sections
below are append-only.

---

### Section: Analysis (Analyst appends)

Required content — this **is** the implementer’s brief:

```markdown
### Analysis — <ISO-8601>

**Agent:** analyst
**Unit:** task-18 / D1

#### Goal
(1–3 sentences for this unit)

#### In scope
- files / symbols / behaviors to change

#### Out of scope / do-not-touch
- from static header + global forbidden paths
- `libs/`, hand-edited `src/bindings/generated/*`
- `tests/parity/compare.ts` tolerances
- unrelated reformatting

#### Branch
`spec/task-18-d1-aot-env-alloc`

#### Worktree
- isolation: worktree
- base: main @ <sha>
- path: (filled by orchestrator/implementer once created)

#### Acceptance (must prove)
- [ ] … → how to prove (command / artifact)

#### Verification commands
export PATH="$PWD/tools/macos-sdk-shim:$PATH"
bun run mz -- --quick   # or full if required
bun tools/testing/strict_bun_gate.ts   # if TS / bun surface touched

#### Project rules reminder
- Zig is oracle; multi-backend parity when behavior changes
- `tests/known_failures.json`: only add with reason; never loosen compare
- Agents.md feature protocol (parity JSON → mz → progress)

#### Risks / open questions
- …
```

After Analysis is complete, Meta `status` → `READY_TO_IMPLEMENT`.

---

### Section: Implementation (Implementer appends)

```markdown
### Implementation — <ISO-8601>

**Agent:** implementer
**Branch:** spec/…
**Worktree path:** …
**HEAD:** <commit_sha>

#### What changed
- file paths + short why

#### Decisions
- non-obvious choices

#### Gates run
| Command | Result |
|---------|--------|
| `bun run mz -- --quick` | PASS / FAIL (notes) |
| … | … |

#### Acceptance self-check
- [x] / [ ] each Analysis checkbox with evidence

#### Residual risk
- …

#### Ready for verify
yes | no (why)
```

After Implementation is complete (and Ready for verify = yes), Meta
`status` → `READY_TO_VERIFY`.

---

### Section: Verify (Verifier appends)

```markdown
### Verify — <ISO-8601> (round N)

**Agent:** verifier
**Reviewed HEAD:** <commit_sha>

#### Checklist
| Check | Pass? | Notes |
|-------|-------|-------|
| Scope | | Diff stays inside Analysis in-scope; no forbidden paths |
| Acceptance | | Every claimed checkbox has command + result |
| Correctness | | mz green or agreed quick path + residual documented |
| Strict bun | | 0 unexpected fail/pass if TS tests touched |
| Docs | | Spec acceptance ticks match reality |
| Hygiene | | Readable commits; no secrets |

#### Issues
1. **[bug|suggestion|nit]** …  → open | fixed | wontfix (reason)
2. …

#### Verdict
**APPROVE** | **REVISE** | **REJECT**

#### Notes for refine (if REVISE)
- numbered must-fix list (bugs first)
```

| Verdict | Next |
|---------|------|
| **APPROVE** | Meta → `APPROVED`; orchestrator merges per policy |
| **REVISE** | Meta → `REVISE`; spawn/resume implementer with “read latest Verify section” |
| **REJECT** | Meta → `REJECTED`; re-run Analyst (new Analysis section) or escalate to human |

Max refine rounds: **3**, then stop and ask the human.

---

### Section: Refine (Implementer appends, each round)

```markdown
### Refine — <ISO-8601> (round N)

**Agent:** implementer
**HEAD:** <new_commit_sha>

#### Addressed issues
- #1 fixed — how
- #2 wontfix — why

#### Gates re-run
| Command | Result |
|---------|--------|

#### Ready for verify
yes
```

Then Meta → `READY_TO_VERIFY` again; orchestrator re-spawns Verifier.

---

### Section: Merge (Orchestrator appends)

```markdown
### Merge — <ISO-8601>

**Agent:** orchestrator
**Merged:** <commit_sha> → main
**Policy:** A | B | C
**Follow-ups:** tick acceptance in static header; specs/README.md progress line; archive docs/tasks if closed
```

Meta → `MERGED`.

---

## Cycle (per unit)

```text
0. PREFLIGHT (orchestrator)
   main clean (or unrelated WIP committed). Valid base.
   Do NOT start writing the unit on main.

1. OPEN WORKTREE (orchestrator)
   Create branch spec/<task-id>-<slug> from main + worktree.
   All following steps run with cwd = that worktree only.

2. ANALYSE (subagent @ worktree)
   Read static header + AUDIT refs + README.
   Append ### Analysis (scope, touch/not-touch, branch, worktree path,
   acceptance, cmds). Commit on the feature branch.
   Meta → READY_TO_IMPLEMENT.

3. IMPLEMENT (subagent @ same worktree)
   Read ### Analysis (that is the only brief).
   Implement only that scope on the feature branch.
   Run mandatory verification.
   Commit. Append ### Implementation (findings, gates, HEAD).
   Meta → READY_TO_VERIFY.

4. VERIFY (subagent @ same worktree)
   Read Analysis + Implementation (+ prior Verify/Refine).
   Check scope · acceptance · gates · hygiene.
   Append ### Verify with verdict. Commit on feature branch.
   Meta → APPROVED | REVISE | REJECTED.

5. REFINE (if REVISE; same worktree)
   Read latest Verify issues.
   Fix; commit; append ### Refine.
   Meta → READY_TO_VERIFY → step 4 again.
   Max 3 rounds → escalate to human.

6. MERGE (if APPROVE; orchestrator)
   Prefer: append ### Merge + tick acceptance on feature branch, commit.
   Fetch tip; remove worktree; FF/merge into local main only.
   Update specs/README.md progress (post-merge on main is OK for board-only
   lines, or include on feature branch before merge).
   Never push origin unless human asked.
   Next unit → new worktree + new branch (step 1).
```

**Communication rule:** agents do not rely on chat history for handoff.
Prompt every subagent with:

1. Path to `specs/task-XX-…/spec.md` **inside the worktree**
2. Worktree path + branch name (must not be `main`)
3. Which section to append
4. “Read the entire file first; follow the latest Analysis / open issues”
5. “Commit only on this feature branch; never checkout main to write”

---

## Orchestrator only does

| Does | Does not |
|------|----------|
| Preflight clean base | Write product code on `main` |
| **Open worktree + branch per unit** | Run Analyst/Implementer/Verifier on `main` |
| Pick next queue unit | Re-do analysis “in head” without Analyst |
| Spawn agents with **cwd = that worktree** | Be the source of truth for findings |
| Read Meta + latest sections **from the worktree** | Replace append-only history |
| Enforce 3-round refine cap | Skip writing Merge section |
| **Merge feature branch → local main only after APPROVE** | Force-push main; push origin unless asked |
| Post-merge board lines (README/FOCUS) if not on branch | Commit cycle Analysis/Implementation onto main first |

---

## Subagent spawn cheat sheet

| Step | Isolation / cwd | Notes |
|------|-----------------|-------|
| Open cycle | orchestrator | `git worktree add` + branch from `main`; **no agent writes on main** |
| Analyst | **`cwd` = unit worktree** | Append Analysis; commit on feature branch only |
| Implementer | **same worktree** | Code + Implementation section; commit on feature branch |
| Verifier | **same worktree** | Append Verify; commit on feature branch |
| Refine | **same worktree** | Append Refine; commit on feature branch |
| Merge | orchestrator | Fetch tip → remove worktree → merge into **local** `main` |

All cycle commits live on the feature branch so the log travels with the
code. `main` receives them **only** at merge.

**Forbidden mid-cycle:** `git checkout main` then edit/commit task files;
committing Analysis onto `main` “so the worktree inherits it”; implementing
on the human’s main checkout.

---

## Mandatory verification (implementer)

On this machine, Zig builds may need:

```bash
export PATH="$PWD/tools/macos-sdk-shim:$PATH"
```

| When | Command |
|------|---------|
| Behavior / engine change | Update `tests/parity/cases/*.json` as needed, then `bun run mz` (full) or `bun run mz -- --quick` if Analysis allows |
| TS / bun / progress surface | `bun tools/testing/strict_bun_gate.ts` |
| Zig-only small fix | At least `zig build vm-baseline` + relevant `zig build test` filters; full `mz` preferred before merge |

Orchestrator may re-run gates on main after merge for final truth.

---

## Merge policy

Configurable per run (human sets once):

| Policy | Behavior |
|--------|----------|
| **A. Auto-merge when green** (default for speed) | Orchestrator merges to local `main` after APPROVE; push to `origin` only if asked |
| **B. Approve-only** | Stop at APPROVE + point human at Verify section; merge only on human “merge” |
| **C. PR only** | Push branch; open PR (`gh pr create`); no local main merge |

Rules regardless of policy:

- No force-push to `main`
- No merge with failing mandatory gates unless human overrides in writing
- Prefer linear history when clean FF is available
- Merge only when latest Verify verdict is **APPROVE**

---

## Preflight (dirty main)

Worktrees need a clean, known base.

If main has uncommitted WIP:

1. Commit as orchestrator prep commit(s) on `main`, **or**
2. Move WIP to `wip/orchestrator-prep` and reset main to a known tip

Do not start implementers against a dirty tree.

---

## Queue (MathZig stream C)

Serial by default (dependencies):

| Order | Unit | Notes |
|------:|------|--------|
| 0 | Land orchestrator WIP on main | Archive, task-12, round, etc. |
| 1 | task-12 residual (optional) | Standalone skip budget in parity CLI |
| 2 | **task-18** (C7 defects) | Prefer D1…D5 sequential mini-cycles |
| 3 | task-15, 17, 19 | After 18; parallel only if truly independent |
| 4 | task-13 → 14 → 16 | Dependency chain |
| 5 | **task-20** (C9 docs truth) | STATUS.md; archive remaining historical tasks |

**Concurrency:** max **1** implementer by default (VM/AOT coupling). Raise
only for independent doc/tool work. Multiple Analysts on different tasks
only if those tasks are truly independent and each has its own `spec.md`.

---

## Reviewer vs Verifier

Verifier **is** the review step: scope, correctness, gates, and code
quality issues in one pass. No separate optional reviewer unless the human
asks for an extra pass (then append `### Review — …` with the same issue
format; Verifier or Refine absorbs open items).

Disable deep code review only when human says “verify gates only” for a
tiny/doc-only unit — still append a Verify section with an explicit lighter
checklist.

---

## Program “done”

1. Specs task-12 … task-20 acceptance checked with evidence in each
   `spec.md` cycle log  
2. `docs/STATUS.md` generated (task-20) or equivalent truth document  
3. Optional open notes under `docs/tasks/` only; product truth is capabilities + STATUS  
4. `main` green: `bun run mz` and strict bun gate  

---

## Status of this workflow

- **Adopted:** 2026-07-15  
- **Revised:** 2026-07-15 — analysis + verify as subagents; **spec.md is
  the handoff bus** (append-only cycle log)  
- **First cycle after adopt:** preflight commit of WIP → next open C unit
  (task-18 D1 or task-12 residual)  
- **Human knobs:** merge policy (A/B/C), verify depth, task-18 split (one
  agent vs per-defect)
