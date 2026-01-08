# Testing & parity

**Daily entrypoint (one way only):**

```bash
bun run mz
```

Agent contract: [`AGENTS.md`](../../AGENTS.md) · short invariants: [`docs/memory/testing.md`](../memory/testing.md) · CLI reference: [`docs/COMMANDS.md`](../COMMANDS.md)

This guide is the **full** testing how-to (pipeline stages, parity schema, comparison policy). It is not an alternate gate.

---

## What `bun run mz` always does

| Step | What it measures | Artifacts |
|------|------------------|-----------|
| **1. Correctness** | Right answers | logs under `tests/artifacts/runs/<sha>/` |
| → zig baseline + zig tests | Native VM / parser / types (source of truth) | step logs |
| → boundary TS tests | Host FFI / WASM ABI glue | step logs |
| → parity all backends | Same JSON cases on zig_vm, ts_ffi, ts_wasm_vm, wasm_aot | `tests/artifacts/parity/<tag>_*.csv` |
| **2. Measure** | Speed (ops/s), only if correctness green | `performance_log.csv` + snapshot JSON |
| **3. Record** | Always | progress package + dashboard data |

**Automatic tag:** `{branch}__{UTC_time}__{short_sha}[__dirty]`  
Example: `main__20260710T121506Z__8e2bed8`

That tag labels run artifacts and the progress package (`meta.feature_id` + `meta.label`). It is **not** a git release tag.

```bash
bun run mz                     # full
bun run mz -- --quick          # parity quick set (still records)
bun run mz -- --skip-measure   # correctness + package only
bun run mz -- --samples 7
bun run mz where               # artifact paths
```

| Question | Stage | Output |
|----------|-------|--------|
| Is it correct? | Correctness | Pass/fail steps + parity CSVs |
| How fast? | Measure | ops/s + snapshot |
| Did we regress/progress? | Record + dashboard | packages over time |

Correctness failure → measure skipped; package still written (`fail`).  
Perf issues are soft (`partial`); exit code follows correctness.

Implementation: `tools/testing/pipeline.ts` · CLI: `tools/mz/cli.ts`

---

## When implementing a change

1. **Add/update parity** in `tests/parity/cases/*.json` if behavior changes.
2. **Implement** in Zig first (source of truth).
3. **Commit** (user-managed; agents do not commit unless asked).
4. **Run:**
   ```bash
   bun run mz
   # while iterating:
   bun run mz -- --quick
   bun run mz -- --skip-measure
   ```
5. **Inspect:** `cd apps/progress && bun run dev`
   - Regressions → `latest_compare.json`
   - Trends / Versions → package history

---

## Backends

| Backend | Path |
|---------|------|
| `zig_vm` | Native VM via parity adapter (reference) |
| `ts_ffi` | TS → FFI → native lib |
| `ts_wasm_vm` | TS → WASM interpreter module |
| `wasm_aot` | Compile expr → AOT wasm → run |

Zig is the source-of-truth baseline. New cross-backend behavior **must** add/update JSON under `tests/parity/cases/`.

---

## Required layout

```text
tests/
  parity/
    cases/                 # Canonical JSON vectors
    backends/              # zig_vm, ts_ffi, ts_wasm_vm, wasm_aot
    compare.ts             # Single comparison policy
    cli.ts                 # Canonical parity runner (used by mz)
  ts/parity/               # Supplemental harness tests (not JSON vectors)
  zig/                     # Domain-organized Zig tests
  performance/             # Perf runners / record helpers
  artifacts/               # Generated (gitignored)
    runs/<sha>/
    parity/
    performance/
    progress/packages/
```

Notes:

- `tests/zig/core/vm_baseline_test.zig` is the must-pass core Zig gate (`zig build vm-baseline`).
- `tests/parity/cases/vm_baseline.json` mirrors baseline expressions across non-Zig backends.
- Supplemental TS under `tests/ts/parity/` is for harness/backend behavior that JSON cannot express. Do **not** put new cross-backend coverage only there.

---

## Test vector schema (JSON)

Each case file is an array of vectors:

```json
[
  {
    "id": "core_add_01",
    "expr": "1 + 2 * 3",
    "vars": {},
    "expected": { "tag": "number" },
    "tolerance": 1e-12
  },
  {
    "id": "matrix_mul_01",
    "expr": "[1,2;3,4] * [2,0;1,2]",
    "vars": {},
    "expected": { "tag": "matrix", "shape": [2, 2] },
    "tolerance": 1e-9
  }
]
```

| Field | Meaning |
|-------|---------|
| `id` | Stable identifier |
| `expr` | MathZig expression |
| `vars` | Variables to set before evaluation |
| `expected.tag` | `number`, `matrix`, `record`, `series`, `unit`, `complex`, `undefined`, `error`, … |
| `expected.shape` | Matrix/series shape when applicable |
| `tolerance` | Numeric epsilon |
| `skip` | Optional backend names to skip (e.g. `["wasm_aot"]`) |
| `setup` | Optional setup expressions (stateful; some backends skip) |

---

## Backend adapter contract

```ts
export interface ParityBackend {
  name: string;
  init(): Promise<void> | void;
  evaluate(expr: string, vars: Record<string, number>): Promise<any> | any;
  dispose(): Promise<void> | void;
}
```

Adapters live in `tests/parity/backends/`.

---

## Comparison policy

All results compare through `tests/parity/compare.ts`:

- **Numbers:** absolute diff ≤ epsilon
- **NaN:** NaN == NaN
- **Undefined/Null:** exact match
- **Matrix:** shape + element-wise tolerance
- **Record:** key set + recursive value compare
- **Series:** length + timestamps + values
- **Errors:** type/value must match

Do not loosen `compare.ts` tolerances to green a failing case.

---

## Progress dashboard (after every `mz`)

| Path | Role |
|------|------|
| `tests/artifacts/progress/packages/<version_id>/` | Append-only package (+ compare vs previous) |
| `tests/artifacts/progress/index.json` | Registry |
| `apps/progress/public/data/index.json` | Package list |
| `apps/progress/public/data/packages.json` | Slim packages for UI |
| `apps/progress/public/data/series.json` | Perf trends |
| `apps/progress/public/data/latest_compare.json` | **Auto** latest vs previous |

```bash
bun run mz
cd apps/progress && bun run dev
```

Need two full runs (with measure) before a compare pair exists.

---

## Optional scopes (not daily `mz`)

| Scope | Command | Purpose |
|-------|---------|---------|
| `adversarial_deep` | `bun tools/testing/adversarial_deep.ts` | Nightly deep fuzz: rotating seed + large count + deadlines |

Default-seed adversarial fuzzers under `tests/adversarial/` run inside mandatory `mz` test steps.

---

## Maintainer escapes (not daily)

```bash
export PATH="$PWD/tools/macos-sdk-shim:$PATH"   # macOS if needed

zig build vm-baseline --summary all
zig build test --summary all
bun tests/parity/cli.ts --quick
bun tests/parity/cli.ts --full
bun tools/status_report.ts
```

Legacy `tools/testing/feature_gate.ts` and hub tools are **not** the product surface.

---

## What is gone from the daily path

- Passing `feature_id` / `task_id` on the CLI
- `feature_gate` as the recommended entry
- Separate “remember to package / refresh app data” steps
- Multiple equal “ways to test”

## Enforcement

A feature/bugfix without:

- a parity case when cross-backend behavior changed, and
- a green (or deliberately recorded) `mz` run

is incomplete.
