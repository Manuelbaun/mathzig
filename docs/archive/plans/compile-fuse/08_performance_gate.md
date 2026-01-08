# Spec 08 — Performance gate (multi vs fused)

**Depends on:** 04 (scalar fused), ideally 03 Stage B  
**Unblocks:** claims that fuse is faster; guides further opts  
**Scope:** measure only; optimize only with evidence

## Goal

Prove (or refute) that fused single-module execution beats multi-module for hot ticks, without breaking correctness.

## Method

Reuse `tools/bench/graph_tick.ts` (or extend it):

| Case | Graph | Modes |
|------|-------|--------|
| scalar_3 | 3-node chain | multi `run`, fused `run` |
| scalar_10 | 10-node chain | multi, fused |
| scalar_50 | 50-node chain | multi, fused |
| multi_out | chain with 2 graph outs | multi, fused |
| matrix_edge (if 07) | 2-node matrix | multi, fused |

- N ticks ≥ 100k where practical; median ns/tick; machine note  
- Compile/load cost reported **separately** from steady-state tick  
- Exclude first-run warmup from median window  

## Todos

- [x] Extend bench harness with `--runtime multi|fused|both` (keeps existing `--mode run|batch|both`)
- [x] Commit multi baseline context via task-10 `docs/tasks/archive/specs/task-10-b4-performance/baseline.md` + this run’s multi column
- [x] Commit results: [`08_results.md`](./08_results.md) with table multi vs fused
- [x] Measured **Stage B** table `tick` (not Stage A named multi-export recompute); fused `run` wins
- [x] Optional: mono single-expr upper bound via `--mono`
- [x] Record residual: fused host pack/decode vs mono; fused batch is host-loop only

## CLI (landed)

```bash
bun tools/bench/graph_tick.ts --ticks 100000 --batches 7 --runtime both --mode both --mono
```

| Flag | Values | Meaning |
|------|--------|---------|
| `--runtime` | `multi` \| `fused` \| `both` | GraphRunner vs FusedGraphRunner Stage B |
| `--mode` | `run` \| `batch` \| `both` | Single-tick vs host `runBatch` |
| `--mono` | flag | Single-expr AOT upper bound on scalar chains |

Results: [`08_results.md`](./08_results.md).

## Do NOTs

- Do **not** optimize without baseline numbers.
- Do **not** change numerical results to game benches.
- Do **not** compare compile-time of multi (cached per node) vs cold full fuse without labeling metrics.
- Do **not** enable shared-memory multi-module as substitute for fuse in this gate.
- Do **not** regress task-10 `runBatch` multi-module behavior.

## Tests / evidence

| ID | Evidence | Pass criteria |
|----|----------|----------------|
| T1 | Correctness still green (04/07 goldens) | required before publishing speedups |
| T2 | results table committed | multi vs fused ns/tick |
| T3 | Stage B fused scalar_50 | expected: fused **&lt;** multi ns/tick (direction); magnitude documented |
| T4 | If fused not faster | written analysis; follow-up tasks, no fake win |

```bash
bun tools/bench/graph_tick.ts --ticks 100000 --batches 7 --runtime both --mode both
```

## Expected outcomes

- [x] Published numbers: multi-module vs fused single-module — see [`08_results.md`](./08_results.md)  
- [x] Clear statement whether Stage B `tick` meets “fastest execution” goal — **yes on long chains** (scalar_50 ~20× fair multi); multi wins short scalar / multi_out  
- [x] No correctness regression — graph/fused suite green before publish  
- [x] Follow-ups filed only from measured gaps — residual host pack vs mono; short-graph fuse  


