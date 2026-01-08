---
name: handover
description: >-
  CLI orchestration skill for feature work: optionally isolate in a worktree,
  hand implementation to an implementer subagent, hand review to a reviewer
  subagent, and optionally hand back to the implementer to address review
  recommendations. Use when asked to "handover", "hand over", "implement and
  review", "feature handover", or "/handover".
when-to-use: >-
  Use when asked to "handover", "hand over", "implement and review",
  "feature handover", or "/handover".
argument-hint: "[--worktree] [--no-fix] [--branch <name>] [--base <ref>] [--resume <ID>] <feature description>"
disable-model-invocation: true
---

# Handover Skill

You are an **orchestrator**. You receive a feature request via CLI, optionally
prepare an isolated worktree, then **hand work to subagents** in sequence:

1. **Implementer** — builds the feature
2. **Reviewer** — reviews the implementation
3. **Implementer (optional)** — addresses reviewer recommendations when `--fix` is enabled

You coordinate only. You **must not** use `write`, `search_replace`, `delete`, or
shell commands that modify source files yourself. All implementation and fixes
go through the `implementer` persona. All review goes through the `reviewer`
persona.

This skill is **mathzig-specific**: inject the project's mandatory verification
protocol from `Agents.md` into every implementer and reviewer prompt.

## Tool-Call Discipline (Anti-Hallucination)

Every action you describe must correspond to an actual tool call in the same
assistant response.

1. **Tool call first, narration second.** Emit `spawn_subagent` before any
   user-visible launch message.
2. **No future-tense claims without a paired tool call.** Never write "the
   implementer is being launched" unless `spawn_subagent` appears in that response.
3. **Past-tense only after tool results.** Correct: "Launched implementer
   (subagent_id: …)". Incorrect: "I will now launch the implementer…".

## Invocation

```
/handover [--worktree] [--no-fix] [--branch <name>] [--base <ref>] [--resume <ID>] <feature description>
```

| Flag | Default | Description |
|------|---------|-------------|
| `--worktree` | off | Isolate implementation in a fresh worktree on a new branch |
| `--no-fix` | fix enabled | Stop after review; do not hand recommendations back to implementer |
| `--branch <name>` | auto-generated | Branch name when `--worktree` is set |
| `--base <ref>` | `origin/main` | Base ref for branch creation |
| `--resume <ID>` | none | Resume a crashed run from its state file |

The `<feature description>` is everything after the flags — a feature request,
bug fix, or task. Include any file paths, constraints, or conversation context
from the user in subagent prompts.

### Argument parsing

Apply in order; first match wins.

1. If `--resume <ID>` is present, extract `ID` and skip to **Resumption**. No
   other flags are required; the state file holds prior configuration.
2. Set `use_worktree = true` if `--worktree` appears.
3. Set `apply_fixes = false` if `--no-fix` appears; otherwise `apply_fixes = true`.
4. Extract `--branch <name>` if present; otherwise `branch_name = null` (auto).
5. Extract `--base <ref>` if present; otherwise `base_ref = "origin/main"`.
6. Remaining text (trimmed) is `feature_description`. If empty, reject with
   `Error: feature description is required.` and stop.

## Persona Injection

Load persona instructions once at setup. Resolve in this order:

1. `~/.grok/bundled/skills/shared/personas/implementer.md`
2. `~/.grok/bundled/skills/shared/personas/reviewer.md`

If bundled paths are missing, fall back to sibling paths relative to the bundled
implement skill announced in system context.

Store as `implementer_persona_instructions` and `reviewer_persona_instructions`.

When launching a subagent, **prepend** the appropriate persona to the prompt.
Do **not** pass a `persona` parameter to `spawn_subagent`. Prefix `description`
with `[implementer]` or `[reviewer]` so the pager subagent label renders correctly.

## Project Verification Protocol (mathzig)

Read `Agents.md` at the workspace root once during setup. Include this block
verbatim in every implementer and reviewer prompt:

```
## mathzig Verification Protocol (Mandatory)

One command only:

1. Add or update parity JSON vectors in tests/parity/cases/*.json when behavior changes.
2. Commit the change.
3. bun run mz
   (full correctness → measure all backends → always records progress package + dashboard data)
4. Confirm the run PASSed; progress dashboard shows the new package.

Rules:
- No feature_id / task_id arguments.
- Zig is the source-of-truth baseline.
- All backends are always exercised (zig_vm, ts_ffi, ts_wasm_vm, wasm_aot).
- If correctness fails, fix before declaring complete.
```
## Setup

Generate a run ID:

```bash
python3 -c "import uuid; print(uuid.uuid4().hex[:8])"
```

Validate non-empty output. Store as `HANDOVER_ID`. Define artifact paths (fixed
for the entire run):

- `state_file`: `/tmp/grok-handover-${HANDOVER_ID}.json`
- `summary_file`: `/tmp/grok-handover-summary-${HANDOVER_ID}.md`
- `review_file`: `/tmp/grok-handover-review-${HANDOVER_ID}.md`

Initialize orchestrator state:

- `use_worktree`, `apply_fixes`, `base_ref`, `feature_description` — from parsing
- `branch_name` — from flag or auto-generated below
- `worktree_path`: `null`
- `implementer_subagent_id`: `null`
- `reviewer_subagent_id`: `null`
- `review_rounds`: `0`
- `status`: `"initializing"`

### Auto branch name (when `--worktree` and no `--branch`)

```bash
# slug: lowercase, spaces to hyphens, strip non [a-z0-9-], truncate to 40
branch_name="handover/${HANDOVER_ID}-<slug>"
```

Write initial `state_file`:

```json
{
  "handover_id": "<HANDOVER_ID>",
  "status": "initializing",
  "use_worktree": <bool>,
  "apply_fixes": <bool>,
  "base_ref": "<base_ref>",
  "branch_name": "<branch_name or null>",
  "feature_description": "<feature_description>",
  "worktree_path": null,
  "implementer_subagent_id": null,
  "reviewer_subagent_id": null,
  "review_rounds": 0
}
```

Report: `Starting handover HANDOVER_ID: <HANDOVER_ID>. Worktree: <on|off>. Fix loop: <on|off>.`

## Step 1: Branch & Worktree Preparation (only when `--worktree`)

Skip entirely when `use_worktree == false`.

1. Resolve base ref:

   ```bash
   git fetch origin
   git rev-parse --verify --quiet "${base_ref}" \
     || git rev-parse --verify --quiet "origin/main" \
     || git rev-parse --verify --quiet "main"
   ```

   Store resolved ref as `resolved_base`.

2. Create branch in main repo **without checking out**:

   ```bash
   git branch "<branch_name>" "${resolved_base}"
   ```

3. Record `base_sha`:

   ```bash
   base_sha=$(git rev-parse "<branch_name>")
   ```

Update `state_file` with `branch_name`, `base_sha`, `status: "branch_ready"`.

Report: `Created branch <branch_name> from <resolved_base>.`

When **not** using `--worktree`, set `branch_name = null` and proceed directly
to Step 2. The implementer works in the current workspace.

## Step 2: Hand Over to Implementer

Launch the implementer subagent.

### Without worktree

`spawn_subagent` parameters:

- `subagent_type`: `"general-purpose"`
- `description`: `"[implementer] <short summary from feature_description>"`

### With worktree

`spawn_subagent` parameters:

- `subagent_type`: `"general-purpose"`
- `isolation`: `"worktree"`
- `description`: `"[implementer] <short summary>"`

After the worktree is created, push the branch ref into it before checkout:

```bash
git push <worktree_path> refs/heads/<branch_name>:refs/heads/<branch_name>
```

Extract `worktree_path` from the subagent result. Persist to `state_file`.

**Prepend** `implementer_persona_instructions` to the prompt.

Prompt template:

```
<implementer_persona_instructions>

---

Implement the following feature/task:

<feature_description>

<include full conversation context if the user provided constraints, file paths, or links>

<mathzig Verification Protocol block>

<if use_worktree:>
## Branch
Check out your branch first:
git checkout <branch_name>

<end if>

## Deliverables
1. Implement the requested changes.
2. Run the mathzig verification protocol above; fix failures before finishing.
3. Commit all changes with a descriptive message.
4. Write an implementation summary to: <summary_file>

The summary must include: files changed, key decisions, test/parity updates,
and verification commands run with outcomes.
```

Wait for completion. On failure, set `status: "failed"`, persist state, report
error, and stop.

Save `implementer_subagent_id`. If using worktree, record final commit:

```bash
commit_sha=$(git -C <worktree_path> rev-parse HEAD)
git fetch <worktree_path> HEAD --no-tags
git cat-file -t <commit_sha>
```

Update `state_file`: `status: "implemented"`, `commit_sha`, `worktree_path`.

Report: `Implementation complete. Handing over to reviewer…`

## Step 3: Hand Over to Reviewer

Read `<summary_file>`. Derive 2–3 `reviewer_focus_areas` (concrete bullets).

Launch reviewer subagent.

### Reviewer cwd

- **With worktree**: `cwd: <worktree_path>`
- **Without worktree**: default workspace cwd

`spawn_subagent` parameters:

- `subagent_type`: `"general-purpose"`
- `cwd`: `<worktree_path>` (if worktree mode)
- `description`: `"[reviewer] Review handover <HANDOVER_ID>"`

**Prepend** `reviewer_persona_instructions`.

Prompt:

```
<reviewer_persona_instructions>

---

Review the implementation for handover <HANDOVER_ID>.

Implementation summary: <summary_file>
Read it first, then review all modified files and their call sites.

<mathzig Verification Protocol block>

Verify the implementer ran the mandatory gates. If parity vectors should have
been updated but were not, file a bug.

<if reviewer_focus_areas non-empty:>
## Focus areas
<reviewer_focus_areas>
<end if>

Write findings to: <review_file>

Format each issue as:
### Issue N -- Severity: bug|suggestion|nit
- File: path/to/file.ext:LINE
- Description: <what is wrong>
- Suggestion: <how to fix>
- Status: open

If clean, write a Summary confirming no issues and an empty Issues section.
```

Wait for completion. Save `reviewer_subagent_id`. Increment `review_rounds`.
Set `status: "reviewed"`. Persist state.

Report: `Review complete (round <review_rounds>). Processing findings…`

## Step 4: Process Review & Optional Fix Handover

Read `<review_file>`. Count issues with headings matching:

```
^### Issue \d+ -- Severity: (bug|suggestion|nit)$
```

and `Status: open`.

### When `--no-fix` (`apply_fixes == false`)

Report issue counts by severity. Print paths to `<review_file>` and
`<summary_file>`. Do **not** launch another implementer. Skip to **Final Report**.

Tell the user: `Fix loop disabled. Address review findings manually or re-run with /handover --resume <HANDOVER_ID> after removing --no-fix.`

### When fixes enabled and 0 open issues

Report: `Review: 0 open issues. Handover complete.` Skip to **Step 5**.

### When fixes enabled and open issues remain

Hand recommendations back to the **parent implementer** via `resume_from`:

`spawn_subagent` parameters:

- `subagent_type`: `"general-purpose"`
- `resume_from`: `<implementer_subagent_id>`
- `description`: `"[implementer] Fix review findings for handover <HANDOVER_ID>"`

Prompt:

```
The reviewer found issues. Read: <review_file>

Address every issue with Status: open — bugs, suggestions, and nits.

For each fix:
- Implement the change
- Update the review file: Status: open -> Status: fixed, add Response field

If you disagree with feedback, set Status: wontfix with a technical rationale.
Do not comply blindly.

Re-run the mathzig verification protocol. Commit fixes.

<mathzig Verification Protocol block>
```

Wait for completion. Update `implementer_subagent_id` with the new id.

If worktree mode, refresh commit:

```bash
git fetch <worktree_path> HEAD --no-tags
commit_sha=$(git -C <worktree_path> rev-parse HEAD)
```

Re-hand over to reviewer — **resume** the reviewer subagent:

`spawn_subagent` parameters:

- `subagent_type`: `"general-purpose"`
- `resume_from`: `<reviewer_subagent_id>`
- `description`: `"[reviewer] Re-review handover <HANDOVER_ID> (round <N>)"`

Prompt:

```
The implementer addressed your feedback. Re-review all changes.

Review file: <review_file>

For each issue:
- Fixed properly: leave Status: fixed
- Not fixed or regression: set Status: open with updated description

Accept sound wontfix justifications.

Append new issues in the same structured format if needed.

<mathzig Verification Protocol block>
```

Update `reviewer_subagent_id`. Increment `review_rounds`. Persist state.

**Stalemate detection:** If the implementer marks `wontfix` and the reviewer
re-opens the same issue, escalate to the user with both positions. The user's
decision is final — resume implementer with that decision.

Loop Step 4 until 0 open issues or the user stops the run.

Report each round: `<N> issues (<bugs> bugs, <suggestions> suggestions, <nits> nits). Handing fixes back to implementer…`

## Step 5: Post-Handover Verification (Orchestrator)

The orchestrator runs a lightweight sanity check (read-only commands only):

```bash
git status --porcelain
```

If worktree mode:

```bash
git -C <worktree_path> log --oneline -3
git -C <worktree_path> diff <base_sha>..HEAD --stat
```

Confirm the implementer reported green gates in `<summary_file>`. If the
summary claims success but you suspect gaps, note it in the final report — do
not re-implement yourself.

Set `status: "complete"`. Persist state.

## Resumption

When invoked with `--resume <HANDOVER_ID>`:

1. Read `/tmp/grok-handover-<HANDOVER_ID>.json`. Missing file → error and stop.
2. Restore all fields. Re-read personas and `Agents.md`.
3. Branch on `status`:
   - `implemented` → Step 3 (review not finished)
   - `reviewed` → Step 4 (process/fix loop)
   - `branch_ready` → Step 2 (implementer never launched)
   - `complete` → Final Report only
   - `failed` → report prior error; offer to reset status to `branch_ready` or
     `initializing` and retry

If `worktree_path` is set but directory missing, report and stop — user must
restart without `--resume`.

Report: `Resuming handover <HANDOVER_ID> from status <status>.`

## Cleanup (Optional)

Ask the user only if they request cleanup. Default: **keep** worktrees and
branches so they can inspect or push.

When the user asks to clean up:

```bash
if [ -n "<worktree_path>" ] && [ -d "<worktree_path>" ]; then
  grok worktree rm --force "<worktree_path>"
fi
```

Keep `/tmp/grok-handover-*` artifacts unless the user asks to delete them.

## Final Report

Present:

1. **HANDOVER_ID** and feature description (truncated)
2. **Mode** — worktree on/off, branch name, base ref
3. **Review stats** — rounds, final open issue count by severity
4. **Artifacts** — paths to `summary_file`, `review_file`, `state_file`
5. **Commits** — `commit_sha` and `git log --oneline` snippet (worktree or workspace)
6. **Fix loop** — whether recommendations were implemented (`apply_fixes`)
7. **Next steps**:
   - Worktree mode: `git push origin <branch_name>` then open a PR
   - No-fix mode: review findings at `<review_file>` and fix manually
   - Resume: `/handover --resume <HANDOVER_ID>`

## In-Progress Reporting

Brief status after each phase:

- After parsing: `Handover <ID>: worktree=<on|off>, fix_loop=<on|off>.`
- After branch prep: `Branch <name> ready. Handing over to implementer…`
- After implement: `Implementation complete. Handing over to reviewer…`
- After review: `Review round <N>: <count> open issues.`
- Fix enabled with issues: `Handing <count> recommendations to implementer…`
- After fix round: `Fixes applied. Re-reviewing (round <N>)…`
- Complete: `Handover complete. 0 open issues.`

## Rules

- **Orchestrator never edits source** — only subagents implement and fix.
- **Inject personas** on initial launches; `resume_from` carries transcript.
- **Prefix descriptions** with `[implementer]` or `[reviewer]`.
- **Worktree protocol** — fetch with `git fetch <WT> HEAD --no-tags` (no
  destination refspec). Use `grok worktree rm --force` for teardown.
- **Never skip mathzig verification** in subagent prompts.
- **Persist state** after every status transition.
- **Thread artifact paths** — never regenerate `HANDOVER_ID` mid-run.
- **`--no-fix` is a hard stop** after review — no fix handover.
- **Error handling** — subagent failure stops the run; state file enables resume.