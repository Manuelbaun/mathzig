# Graph tick performance baseline

> **Live baseline for the graph perf tripwire** (`tools/testing/graph_perf_tripwire.ts`).
> Source: former task-10 B4 after-optimization measurement. Do not delete the fenced JSON `rows` block.


Measured with `bun tools/bench/graph_tick.ts --ticks 100000 --batches 7 --mode both`
after tick-plan + `runBatch` landed.

## Machine

Machine (historical B4 baseline run): Apple M1 Pro, Darwin 25.4.0, arm64, bun 1.3.14.

## What changed

1. **Tick plan** (`GraphRunner` rebuild after load/reload): dense slot indices, hoisted
   `eval` / `reset_heap`, preallocated arity buffers, specialized arity-0..3 call path.
2. **`run()` scalar fast path**: no per-tick `Map` / args array; writes into reused
   `Float64Array` slots; object outputs only at the boundary.
3. **`runBatch(inputLanes, n) → outputLanes`**: per-input / per-output `Float64Array`
   lanes; pure-scalar inner loop has zero per-tick allocation; non-scalar edges keep
   host-mediated copy protocol (mixed path).
4. **Shared imported memory**: **not** prototyped — see decision below.

## Delta table (median ns/tick, N=100k, 7 batches)

| Case | Nodes | baseline `run` | after `run` | after `batch` | run speedup | batch vs baseline | batch vs after-run |
|------|------:|---------------:|------------:|--------------:|------------:|------------------:|-------------------:|
| scalar_3 | 3 | 381.1 | **50.8** | **44.0** | **7.5×** | **8.7×** | 1.15× |
| scalar_10 | 10 | 1722.4 | **548.5** | **462.1** | **3.1×** | **3.7×** | 1.19× |
| scalar_50 | 50 | 9265.7 | **2563.3** | **2241.0** | **3.6×** | **4.1×** | 1.14× |
| matrix_edge | 2 | 769.9 | **725.6** | n/a | **1.06×** | — | — |

### Raw JSON (after)

```json
{
  "ticks": 100000,
  "batches": 7,
  "mode": "both",
  "rows": [
    { "case": "scalar_3", "nodes": 3, "runNs": 50.78542, "batchNs": 44.01292 },
    { "case": "scalar_10", "nodes": 10, "runNs": 548.46625, "batchNs": 462.10375 },
    { "case": "scalar_50", "nodes": 50, "runNs": 2563.2675, "batchNs": 2240.97333 },
    { "case": "matrix_edge", "nodes": 2, "runNs": 725.63917, "batchNs": null }
  ]
}
```

## Shared-memory decision

Spec: prototype shared imported memory **only if** lanes leave **>2×** on the table
for matrix-heavy graphs.

### Original B4 observation (matrix **output**)

- Matrix **outputs** are non-scalar → `runBatch` number-lane API does not apply
  (`matrix_edge` batchNs=null).
- Single-tick matrix path improved only ~6% from plan hoisting (725 vs 770 ns).
- Residual matrix cost is host-mediated copy + `reset_heap` + decode, not JS Map churn.
- Batch vs optimized single-tick on pure scalar is ~1.15× — **not** >2×.

### task-19 P5 measurement (matrix **intermediate**, number out)

`bun tools/bench/graph_tick.ts --ticks 20000 --batches 7 --mode both`  
(Apple M1 Pro class machine, 2026-07-15). Graph: input k →
`[k,0;0,k]*[1,2;3,4]` (matrix mid) → `sum` (number out).

| Case | runNs (median) | batchNs (median) | batch vs run |
|------|---------------:|-----------------:|-------------:|
| matrix_heavy_num | **2496.9** | **2205.3** | **1.13×** |

Raw row:

```json
{ "case": "matrix_heavy_num", "nodes": 3, "runtime": "multi",
  "runNs": 2496.9021, "batchNs": 2205.34375,
  "note": "matrix intermediate, number out; batch vs run for shared-memory decision" }
```

Lanes leave only ~1.13× on the table for the matrix-heavy number-out path —
**well under the 2× threshold**. Host-mediated matrix copy still dominates;
shared imported memory would not close a 2× gap that is not present.

**Conclusion (evaluated): shared imported memory not needed for B4; measured
matrix-heavy batch speedup 1.13× < 2× gate. No prototype.**

## Residual for task-11 (and later)

- Matrix / record / series edge throughput still dominated by per-tick copy protocol.
- Optional later: shared-memory or in-module multi-eval for matrix-heavy graphs if a
  product workload demands it (out of B4 scope) — **not** justified by P5 numbers.
- task-11: native runner + DSL sugar — do not block on further perf work.
- Optional micro: further scalar batch wins via in-wasm multi-sample export (not done).
- Residual AOT: `x + 2i` / `(c)*x` with params can emit invalid wasm (local index);
  complex+number dual-input graph attachMemory gap — not blocking batch equivalence.
