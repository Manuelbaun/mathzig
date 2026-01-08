# Compile-fuse — overview

**Status:** complete (specs 01–08)  
**Date:** 2026-07-10  
**Related:** `docs/plans/wasm_node_graph/plan.md`, `docs/graph_findings.md` §9

## Product model

| Context | Shape |
|--------|--------|
| **Editor / interactive runtime** | Unchanged: **one compute node → one wasm module**; TS `GraphRunner` topo + host-mediated edges |
| **Final / optimized artifact** | **One wasm module** for the whole graph: multi **input values**, multi **output values** |

Editor multi-module stays. Fuse is an **additional** compile path (“as well”), not a replacement for `GraphRunner.load`.

## Peak execution shape

```text
GraphDefinition
  → lower (topo + shared plan)
  → one WasmModule
       multi inputs (params trailing)
       multi output values (memory table and/or named out exports)
       single host entry preferred: tick(...)
```

Fast path = **one host entry per tick**, edges **inside** the module. Multi-export with JS still chaining nodes is intermediate only.

## Spec index (ordered)

| Spec | File | Goal |
|------|------|------|
| 01 | [`01_abi_and_graph_manifest.md`](./01_abi_and_graph_manifest.md) | Freeze multi-in / multi-out value ABI + `mathzig:graph` |
| 02 | [`02_graph_lowerer.md`](./02_graph_lowerer.md) | Graph → fuse plan (scalar first) |
| 03 | [`03_aot_multiroot_codegen.md`](./03_aot_multiroot_codegen.md) | One module: multi-export and/or sequential `tick` |
| 04 | [`04_fused_host_runner.md`](./04_fused_host_runner.md) | Host: load one module, multi input/output **values** |
| 05 | [`05_cli_compile_graph.md`](./05_cli_compile_graph.md) | `mathzig compile-graph` + sidecar |
| 06 | [`06_product_export.md`](./06_product_export.md) | Console/export UX; editor stays multi-module |
| 07 | [`07_full_value_and_batch.md`](./07_full_value_and_batch.md) | Non-scalar multi-out + batch |
| 08 | [`08_performance_gate.md`](./08_performance_gate.md) | Measured multi vs fused |

## Global constraints

- Correctness first, performance second (`Agents.md`).
- Zig / multi-module `GraphRunner` / `zig_vm` remain truth for goldens.
- Params remain runtime-tunable without recompile (trailing args, not baked constants).
- Prebuilt opaque `wasm` nodes: **out of fuse v1** (require `expr` dual or stay multi-module only).

## Global Do NOTs

- Do **not** remove or break multi-module `GraphRunner` for the editor.
- Do **not** invent a second value encoding; reuse `src/wasm/abi.zig` wire kinds.
- Do **not** make shared-memory multi-module the “single module” solution.
- Do **not** skip goldens: fused ≡ multi-module for every landed value kind.

## Definition of done (program)

- [x] Specs 01–05 landed with green tests  
- [x] Scalar multi-in multi-out one-module path usable via CLI  
- [x] Editor still multi-module  
- [x] Spec 06 product export (multi-module run + fused download)  
- [x] Spec 07 full-value multi-out + `runBatch`  
- [x] Spec 08 performance gate — multi vs fused measured ([`08_results.md`](./08_results.md)); fair hot `run()`: fused wins long chains (scalar_50 ~20×), multi wins short scalar/multi_out

## Spec 01 status

Multi-value ABI + `mathzig:graph` types/emit/read landed in:

- Zig: `src/wasm/graph_manifest.zig` (`writeJson` / `toJsonAlloc` / `emitCustomSection`)
- TS: `src/ts/graph/graph_manifest.ts` (`readGraphManifest`)

Wire kinds reuse `abi.WireKind` via `node_manifest` helpers (no second enum).
