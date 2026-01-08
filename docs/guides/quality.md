# Quality system — how & why

Daily gate, parity, quarantine, and progress recording.  
Short agent rules: [`AGENTS.md`](../../AGENTS.md) · full testing how-to: [`testing.md`](./testing.md).

---

## Why this system exists

Historical failure mode: multiple test entrypoints, task-id perf scripts, and prose status that disagreed with CI. The current system optimizes for:

1. **One command** humans and agents trust  
2. **Visible debt** (quarantine / skip budgets) instead of hidden skips  
3. **History** (progress packages) without manual packaging  

---

## Daily path

```bash
bun run mz
```

| Stage | Why |
|-------|-----|
| **Correctness** | Wrong answers must fail the exit code |
| **Measure** | Perf is soft — don’t block correctness packages on flaky benches |
| **Record** | Always write a package so red runs still show up in the dashboard |

Auto tag: `{branch}__{UTC_time}__{short_sha}[__dirty]` — no feature_id required.

Implementation: `tools/testing/pipeline.ts`, `tools/mz/cli.ts`.

---

## Parity harness

| Piece | Role |
|-------|------|
| `tests/parity/cases/*.json` | Canonical vectors |
| `tests/parity/backends/*` | zig_vm, ts_ffi, ts_wasm_vm, wasm_aot |
| `tests/parity/compare.ts` | **Only** comparison policy |
| `tests/parity/cli.ts` | Runner used by mz |

**Why JSON catalog:** new behavior is reviewable data, not buried in harness code.  
**Why one compare:** backends cannot invent private NaN/matrix rules.

---

## Strict bun gate & quarantine

- Tool: `tools/testing/strict_bun_gate.ts`
- List: `tests/known_failures.json`
- Unexpected fail **or** unexpected pass → gate fail

**Why quarantine:** MathJS/rocket/capacity cases can remain tracked without lying that the suite is fully green. Removing a fixed case without deleting the quarantine entry fails as unexpected pass.

---

## Standalone skip budget

- Tool: `tools/testing/standalone_skip_budget.ts`
- Enforced when `wasm_aot_standalone` runs under full mz/parity

**Why:** standalone is a product promise. Allowing skips to grow would reintroduce “works on my host imports” as the only path.

---

## Graph goldens & tripwire

- Goldens: `tests/graph/goldens/`
- Tripwire: `tools/testing/graph_perf_tripwire.ts` vs [`docs/reference/graph_tick_baseline.md`](../reference/graph_tick_baseline.md)
- Full protocol only (excluded from `--quick`)

**Why:** graph multi-module optimizations (tick plan, runBatch) must not regress silently.

---

## Adversarial & soak

- Default adversarial corpora run inside mz’s zig/bun steps (`tests/adversarial/`)
- Deep nightly-style: `bun tools/testing/adversarial_deep.ts`
- Soak: `tests/soak/`

**Why:** parity cases are curated; fuzz finds parser/VM edges; soak finds leaks under repetition.

---

## Progress dashboard

After every mz:

- Packages: `tests/artifacts/progress/packages/`
- UI data: `apps/progress/public/data/` including `latest_compare.json`

**Why a product app:** CSV logs alone don’t show regressions over time for humans.

---

## Status truth

```bash
bun tools/status_report.ts
bun tools/status_report.ts --check
```

Writes [`docs/STATUS.md`](../STATUS.md) from inventory + artifacts.

**Why generated:** hand-edited status bitrots. Criterion claims must point at measurable artifacts.
