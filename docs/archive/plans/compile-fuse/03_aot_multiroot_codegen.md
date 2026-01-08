# Spec 03 — AOT multi-root / fused `tick` codegen

**Depends on:** 01, 02  
**Unblocks:** 04, 05  
**Scope:** produce **one** `.wasm` from a `FusePlan` (or equivalent unit list)

## Goal

Compile a fuse plan into a **single** wasm module such that:

- Shared env import table (union of all nodes’ builtins)
- Single linear memory / heap when any node needs it
- Multiple **output values** available after one tick (table and/or named exports)
- Prefer **one host entry** `tick` for execution speed

## Codegen strategies (land in order)

### Stage A — Multi-export (correctness scaffold)

- Each plan node → export `n_<id>` (or sanitized id)
- Each graph output → export `out_<name>` that recomputes along path **or** calls node exports
- Accept temporary double-work on diamonds; goldens only check **values**

### Stage B — Sequential `tick` (performance shape)

- One function `tick(inputs…, params…) -> i32` (ptr to output table) or `void` + fixed base
- Body: topo order; scalar results in locals; non-scalar later (spec 07)
- Write output table per spec 01
- Node helper exports optional behind flag / debug only

**Acceptance for “fuse done”:** Stage B for **scalar** multi-in multi-out. Stage A may land first if it shortens the path to goldens.

## Compiler work

### Todos

- [x] Extend `WasmCompiler` with multi-unit entry:
  - either `compileMany(units)` for Stage A
  - and/or `compileFusedTick(plan, compiledExprs[])` for Stage B
- [x] Preserve import-first registration discipline (existing two-phase discovery)
- [x] `force_heap` when out_mode is `table` or any non-number kind
- [x] Emit `mathzig:graph` via `graph_manifest` (spec 01)
- [x] Emit/keep `mathzig.abi` consistent (imports, heap flags)
- [x] Sanitize export names (wasm-legal identifiers from node ids)
- [x] Wire from MathZig `compile` of each node expr → bytecode → fuse codegen
- [x] Zig unit tests: 2-node chain single module, multi-export present, custom section present
- [x] Fixture: compile plan offline, export-section inspect in test harness (`tests/zig/backends/wasm/fuse_codegen_test.zig`)

### Landed decisions

| Topic | Choice |
|-------|--------|
| Primary path | **Stage B** `compileFusedTick` — topo order, node helpers + single `tick` |
| Stage A | `compileMany` multi-export scaffold; also `export_node_helpers` / `named_exports` out_* |
| Diamonds | Stage B `tick` evaluates each node **once**. Named `out_*` re-run the topo chain per call (Stage A interim for multi-call; values OK). Prefer table+tick for single-pass multi-out. |
| Output table | Spec 01 packed layout: `[u32 count]` + `[u32 kind][f64 wire]*`; f64.store align=2 |
| Scalar gate | **Lifted in Spec 07** — all `abi.WireKind` I/O allowed; params stay number/boolean (`error.NonScalarFuse` only for non-scalar params) |
| Single-expr | `compile` / CLI `--node` unchanged (thin wrapper over multi-unit path) |

## Do NOTs

- Do **not** break single-expression `mathzig compile` / `--node` paths.
- Do **not** add imports after defined functions (index shift bugs).
- Do **not** leave Stage A as the only long-term path if diamonds recompute (document as interim).
- Do **not** implement shared-memory **multi-instance** linking here.
- Do **not** call out to JS between fused nodes inside `tick` (no host edge protocol inside the module).

## Tests

| ID | Test | Expected |
|----|------|----------|
| T1 | Chain `*2` then `+1`, inputs `[3]`, one out | Module exports `tick` or `out_*`; result `7` |
| T2 | Two outputs from diamond | Both values match multi-module runner |
| T3 | Params trailing | Changing param args changes result without recompile |
| T4 | Custom section `mathzig:graph` | Parseable; outputs list length matches |
| T5 | Import union | Module imports = union, no dup names |
| T6 | Heap | Scalar-only may omit memory; table mode has memory+alloc as required by 01 |
| T7 | Invalid expr in node | Compile error, no partial silent module |

```bash
zig build test --summary all
# plus any bun tests that shell to zig-out/bin/mathzig once CLI exists (05)
```

## Expected outcomes

- [x] One wasm binary for a multi-node scalar plan  
- [x] Multiple **output values** readable per ABI 01 (table layout + `mathzig:graph`)  
- [ ] Numeric goldens vs multi-module — deferred to Spec 04 fused host runner (module structure + exports covered here)  
- [x] No regression on existing AOT/single-node compile tests  
