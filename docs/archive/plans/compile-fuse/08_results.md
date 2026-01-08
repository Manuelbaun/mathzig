# Spec 08 — Performance gate results (multi vs fused)

Measured with:

```bash
bun tools/bench/graph_tick.ts --ticks 100000 --batches 7 --runtime both --mode both --mono
```

Harness: `tools/bench/graph_tick.ts`  
Date: **2026-07-10** (UTC `2026-07-10T16:02:35.435Z`)  
**Fairness:** multi uses hot `GraphRunner.run()` (no `runProfiled` per-node timers).  
Earlier Spec 08 draft numbers that routed multi through `run→runProfiled` are **superseded** (see [Methodology](#methodology-fairness)).

## Machine

| Field | Value |
|-------|-------|
| CPU | Apple M1 Pro |
| Cores | 10 |
| OS | Darwin 25.4.0 |
| Arch | arm64 |
| Bun | 1.3.14 |
| Node (Bun's) | v24.3.0 |
| uname | `Darwin … 25.4.0 Darwin Kernel Version 25.4.0: Thu Mar 19 19:30:44 PDT 2026; root:xnu-12377.101.15~1/RELEASE_ARM64_T6000 arm64` |

## Method

| Item | Choice |
|------|--------|
| Multi path | `GraphRunner.run()` — tick-plan hot path (no profiling tax) |
| Fused path | `compileFused(…, { outMode: "table" })` + `FusedGraphRunner.run()` — **Stage B** single `tick` |
| Ticks | 100 000 per timed batch |
| Batches | 7; **median** ns/tick |
| Warmup | Excluded from median (`min(ticks, 2000)` scalar; 500 matrix) |
| Compile/load | Reported separately from steady-state ticks |
| Mono (optional) | Same scalar math as one AOT `eval(x)` — residual host-cost sanity check only |
| Multi load | Scalar: env only; matrix: `AotHostEnv` (matches task-10) |

**Compile/load labeling**

- **multi `compileMs`**: full `GraphRunner.load` wall time (per-node AOT + instantiate). `loadMs` = 0.
- **fused `compileMs`**: `compileFused` → `mathzig compile-graph` (table).
- **fused `loadMs`**: `FusedGraphRunner.load` (instantiate + manifest).

**Correctness before publish**

```text
bun test tests/ts/graph
→ 114 pass, 0 fail
```

## Methodology fairness

| Path | What is timed | Notes |
|------|---------------|-------|
| multi `run` | Hot `GraphRunner.run()` | No `performance.now` / per-node timing arrays |
| multi `runProfiled` | **Not** used in this gate | UI profiling only; roughly ~2× multi `run` if misused as bench |
| fused `run` | Stage B table `tick` + host pack/decode | Fair product path |

### vs task-10 after-opt multi baseline

`docs/tasks/archive/specs/task-10-b4-performance/results.md` (same machine family):

| Case | task-10 multi run | Spec 08 multi run | task-10 multi batch | Spec 08 multi batch |
|------|------------------:|------------------:|--------------------:|--------------------:|
| scalar_3 | 50.8 | **50.4** | 44.0 | **42.1** |
| scalar_10 | 548.5 | **541.5** | 462.1 | **462.8** |
| scalar_50 | 2563.3 | **2509.1** | 2241.0 | **2213.3** |
| matrix_edge | 725.6 | **726.6** | n/a | n/a |

Multi `run` / `runBatch` match task-10 ballpark after restoring hot `run()` (commit split from always-on `runProfiled`). **No multi batch regression.**

Prior inflated Spec 08 multi run (~294 / 1161 / 5422) came from `run()` delegating to `runProfiled` — that product bug is fixed; those ratios are void.

## Steady-state: `run()` median ns/tick (fair)

| Case | Nodes | multi run | fused run | multi/fused | Winner |
|------|------:|----------:|----------:|------------:|:-------|
| scalar_3 | 3 | **50.4** | 97.0 | 0.52× | **multi** |
| scalar_10 | 10 | 541.5 | **99.8** | **5.43×** | **fused** |
| scalar_50 | 50 | 2509.1 | **127.3** | **19.7×** | **fused** |
| multi_out | 2 | **48.0** | 110.2 | 0.44× | **multi** |
| matrix_edge | 2 | 726.6 | **335.9** | **2.16×** | **fused** |

ratio = multi/fused; **>1 means fused faster**.

### Optional mono upper bound (sanity only)

| Case | mono run ns/tick | fused run | Note |
|------|-----------------:|----------:|------|
| scalar_3 | ~10.4 | 97.0 | order-of-magnitude residual |
| scalar_10 | ~6.2 | 99.8 | mono depths are **noisy** (JIT); not a ranked ladder |
| scalar_50 | ~18.6 | 127.3 | fused still ~7× mono host residual |

Mono is an upper-bound check for residual fused host pack/table-decode cost, **not** a ranked comparison across chain depths.

## Steady-state: `runBatch` median ns/tick

| Case | multi batch | fused batch | Note |
|------|------------:|------------:|------|
| scalar_3 | **42.1** | 101.9 | multi specialized scalar batch |
| scalar_10 | 462.8 | **103.6** | fused faster |
| scalar_50 | 2213.3 | **134.7** | fused faster |
| multi_out | **92.1** | 131.7 | multi wins short multi-out |
| matrix_edge | n/a | n/a | non-scalar; batch API N/A |

**Fused `runBatch` is a host loop over `run()`** (Spec 07), not a wasm `tick_batch`. Do not claim fused batch is universally faster.

## Compile / load (one-shot, not in tick medians)

| Case | multi load wall (ms) | fused compile (ms) | fused load (ms) |
|------|---------------------:|-------------------:|----------------:|
| scalar_3 | 3.3 | 5.7 | 2.3 |
| scalar_10 | 8.9 | 4.9 | 1.6 |
| scalar_50 | 43.4 | 6.1 | 1.8 |
| multi_out | 1.4 | 4.8 | 2.0 |
| matrix_edge | 24.2 | 4.5 | 2.0 |

Fuse compile scales better with node count than multi per-node AOT on long chains (scalar_50).

## Conclusion (T3 / “fastest execution” goal)

**Honest verdict under fair multi `run()`:**

| Claim | Verdict |
|-------|---------|
| Fused Stage B `run` &lt; multi `run` on **every** case | **No** — multi wins **scalar_3** and **multi_out** |
| Fused faster on long chains | **Yes** — scalar_10 ~5.4×, **scalar_50 ~19.7×** |
| T3 scalar_50 direction (fused &lt; multi) | **Pass** (~20× on fair multi) |
| Fused batch always best | **No** — multi specialized batch wins short chains |
| Close to mono single-expr | **No** — fused still has ~7–15× residual host pack/decode vs mono |
| Multi `runBatch` regressed | **No** — within task-10 ballpark |
| Multi `run` vs task-10 | Restored hot path; matches task-10 after-opt (~50 / 540 / 2500) |

### When fuse wins on hot ticks

- **Long pure-scalar chains** (tens of nodes): multi pays per-module JS call; Stage B one `tick` wins big.
- **Matrix edges**: in-module edge avoids host mid-tick copy (~2×).
- **Short chains / multi_out**: multi tick-plan + specialized batch remains competitive or faster; fuse host pack/table decode is not free.

### Residual / follow-ups (measured gaps only)

1. **Fused host `run` overhead** vs mono (~100 ns residual) — pack args, table read, JS wrapper.
2. **Short-graph fuse**: optional lighter scalar path (named f64 return without table) if product needs sub-50 ns multi-out.
3. **Fused `runBatch`**: still host loop; true `tick_batch` only if multi-out number lanes matter more than multi’s scalar batch on short graphs.

## Raw JSON

```json
{
  "machine": {
    "platform": "darwin",
    "arch": "arm64",
    "os": "Darwin 25.4.0",
    "cpu": "Apple M1 Pro",
    "cores": 10,
    "bun": "1.3.14",
    "node": "v24.3.0",
    "date": "2026-07-10T16:02:35.435Z"
  },
  "ticks": 100000,
  "batches": 7,
  "mode": "both",
  "runtime": "both",
  "mono": true,
  "fairness": "multi GraphRunner.run hot path (no runProfiled)",
  "rows": [
    { "case": "scalar_3", "nodes": 3, "runtime": "multi", "compileMs": 3.30925, "loadMs": 0, "runNs": 50.35625, "batchNs": 42.0525 },
    { "case": "scalar_3", "nodes": 3, "runtime": "fused", "compileMs": 5.678209, "loadMs": 2.314917, "runNs": 96.9575, "batchNs": 101.8525 },
    { "case": "scalar_3", "nodes": 1, "runtime": "mono", "compileMs": 1.070416, "loadMs": 0.901125, "runNs": 10.42958, "batchNs": null },
    { "case": "scalar_10", "nodes": 10, "runtime": "multi", "compileMs": 8.933166, "loadMs": 0, "runNs": 541.52375, "batchNs": 462.77958 },
    { "case": "scalar_10", "nodes": 10, "runtime": "fused", "compileMs": 4.9035, "loadMs": 1.606167, "runNs": 99.78625, "batchNs": 103.64541 },
    { "case": "scalar_10", "nodes": 1, "runtime": "mono", "compileMs": 0.95725, "loadMs": 0.590417, "runNs": 6.22667, "batchNs": null },
    { "case": "scalar_50", "nodes": 50, "runtime": "multi", "compileMs": 43.393833, "loadMs": 0, "runNs": 2509.14333, "batchNs": 2213.28167 },
    { "case": "scalar_50", "nodes": 50, "runtime": "fused", "compileMs": 6.097041, "loadMs": 1.848083, "runNs": 127.33583, "batchNs": 134.69667 },
    { "case": "scalar_50", "nodes": 1, "runtime": "mono", "compileMs": 1.0755, "loadMs": 0.583167, "runNs": 18.62334, "batchNs": null },
    { "case": "multi_out", "nodes": 2, "runtime": "multi", "compileMs": 1.363958, "loadMs": 0, "runNs": 47.95584, "batchNs": 92.09334 },
    { "case": "multi_out", "nodes": 2, "runtime": "fused", "compileMs": 4.763958, "loadMs": 2.0025, "runNs": 110.2425, "batchNs": 131.67459 },
    { "case": "matrix_edge", "nodes": 2, "runtime": "multi", "compileMs": 24.172125, "loadMs": 0, "runNs": 726.58375, "batchNs": null },
    { "case": "matrix_edge", "nodes": 2, "runtime": "fused", "compileMs": 4.495333, "loadMs": 1.992458, "runNs": 335.85083, "batchNs": null }
  ],
  "compare": [
    { "case": "scalar_3", "multiRun": 50.35625, "fusedRun": 96.9575, "ratio": 0.5193641543975454, "winner": "multi" },
    { "case": "scalar_10", "multiRun": 541.52375, "fusedRun": 99.78625, "ratio": 5.426837364867404, "winner": "fused" },
    { "case": "scalar_50", "multiRun": 2509.14333, "fusedRun": 127.33583, "ratio": 19.704927748929737, "winner": "fused" },
    { "case": "multi_out", "multiRun": 47.95584, "fusedRun": 110.2425, "ratio": 0.4350031974964283, "winner": "multi" },
    { "case": "matrix_edge", "multiRun": 726.58375, "fusedRun": 335.85083, "ratio": 2.1634121017357617, "winner": "fused" }
  ]
}
```
