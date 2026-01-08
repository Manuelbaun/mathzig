# Spec 07 — Full-Value multi-out + batch

**Depends on:** 01–05 green on scalar  
**Unblocks:** production parity for matrix/series graphs as single module  
**Scope:** non-scalar edges/outs inside fused module; batch API

## Goal

Extend fused modules beyond scalar:

1. Non-scalar **input values** and **output values** via existing ABI wire + output table  
2. In-module edges for matrix/complex/record using **one heap** (no host-mediated mid-tick copies)  
3. Optional `tick_batch` / host batch wrapper for multi-in multi-out number lanes  

## Todos

- [x] Lowerer: accept matrix/complex/record/series kinds on ports (reject unknown)
- [x] Codegen Stage B: non-scalar producers leave ptr locals; consumers take ptr args
- [x] Output table kinds for non-number (spec 01 layout)
- [x] Host `FusedGraphRunner.run`: write non-scalar inputs once; after tick read each out via `readWireValue`
- [x] Series: single `AotHostEnv` handle space (same as multi-module shared host rule)
- [x] Golden: matrix chain multi ≡ fused
- [x] Golden: multi-out one scalar + one matrix
- [x] `runBatch` equivalent for fused pure-number multi-out (optional API `runBatch` on fused)
- [x] Document standalone limits for full-value fused graphs

## Do NOTs

- Do **not** host-mediate between fused nodes mid-tick (defeats fuse).
- Do **not** reset_heap between internal nodes; only around whole tick as needed.
- Do **not** skip scalar goldens when adding full-value.
- Do **not** implement wasm multi-memory or dynamic linking for this.
- Do **not** treat series linear_memory vs host_handle inconsistently with `mathzig.abi` `series_repr`.

## Tests

| ID | Case | Expected |
|----|------|----------|
| T1 | Matrix `*2` → consumer sum | fused ≡ multi |
| T2 | Two outs: matrix + scalar derived | both match multi |
| T3 | Record edge if supported in multi already | fused ≡ multi |
| T4 | Heap discipline | two fused runs identical; no cross-tick leak of outs |
| T5 | Number batch N ticks | lane i ≡ run(i) |

```bash
bun test tests/ts/graph/fused_fullvalue*.ts
bun run mz -- correct all   # or targeted parity if integrated
```

## Expected outcomes

- [x] One module carries multi **values** including non-scalars  
- [x] Internal edges avoid host copy  
- [x] Goldens vs multi-module for landed kinds  
- [x] Batch path for pure number multi-out (if implemented) documented  

## Landed (implementation notes)

| Surface | Location |
|---------|----------|
| Stage B full-value | `compileFusedTick` accepts all `abi.WireKind` I/O; per-node `arg_kinds` seed AOT param tags; result locals are f64 wire (ptr/handle); single heap for whole tick |
| CLI | `mathzig compile-graph` passes `arg_kinds` / `output_kind`; non-scalar const immediates still rejected |
| Host | `FusedGraphRunner.run` + `runBatch` (pure-number multi-out only) |
| Goldens | `tests/ts/graph/fused_fullvalue.test.ts`, `tests/zig/backends/wasm/fuse_codegen_test.zig` Spec07 cases |
| Standalone limits | `docs/guides/wasm_aot_usage.md` (full-value section) |
