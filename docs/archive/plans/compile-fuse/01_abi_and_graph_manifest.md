# Spec 01 — Multi-value ABI + `mathzig:graph` manifest

**Depends on:** nothing (first)  
**Unblocks:** 02–05  
**Scope:** design + formal types + round-trip tests only (no full fuse runner yet)

## Goal

Define how a **single** fused wasm module exposes:

- multiple **input values**
- multiple **param values** (runtime-tunable)
- multiple **output values**

…via a custom section + JSON sidecar, reusing existing wire kinds from `src/wasm/abi.zig`.

## Decisions (lock in this spec)

### Inputs / params

- Ordered list of graph inputs, then ordered list of params.
- Each port: `{ name, kind }` (`kind` = short names already used by `node_manifest`: number, matrix, …).
- Params may carry `default: number | null`.
- Wasm boundary for numbers: `f64` params to the entry export(s).
- Non-scalar: same wire as AOT today (`f64` carrying ptr/handle after host write into module memory) — **document only** in this spec; implement decode in later specs.

### Outputs (multi **values**, one module)

**v1 choice (required):**

| Mode | When |
|------|------|
| **A. Output table in linear memory** (preferred default) | Mixed kinds later; one entry `tick` |
| **B. Named exports `out_<name>`** | Scalar-only shortcut / debug |

v1 scalar MVP may implement **B** first if faster, but the **manifest must describe outputs as a list of values** so host code is mode-agnostic.

**Output table layout (Mode A) — freeze:**

```text
// After successful tick (heap not reset by host until outputs read):
// base = value returned by tick as i32 ptr, OR fixed heap_base+offset from manifest
//
// [u32 count]
// repeated count times:
//   [u32 kind_tag]   // map from abi / short kind enum (document mapping)
//   [f64 wire]       // number payload or ptr/handle as f64 bits per existing AOT
```

Names live **only** in the manifest (not necessarily in memory) to avoid string churn in v1.

### Custom section

- Name: `mathzig:graph`
- Payload: compact JSON (same escaping style as `mathzig:node` / `mathzig.abi`)
- Sidecar: `<stem>.graph.json` next to `.wasm`

### JSON shape (normative)

```json
{
  "abi": 1,
  "entry": "tick",
  "inputs": [{ "name": "x", "kind": "number" }],
  "params": [{ "name": "gain.k", "kind": "number", "default": 1.0 }],
  "outputs": [
    { "name": "u", "kind": "number", "result_tag": "number" },
    { "name": "v", "kind": "number", "result_tag": "number" }
  ],
  "out_mode": "table",
  "exports": [{ "name": "tick", "params": 2 }]
}
```

- `out_mode`: `"table" | "named_exports"`
- If `named_exports`: each output has optional `"export": "out_u"`
- `abi` version integer independent of node-manifest; start at `1`

### Relationship to existing sections

- Keep `mathzig.abi` for compiler imports/result of primary export if still emitted.
- `mathzig:node` is **single-node**; fused modules use **`mathzig:graph`** instead (do not overload node section with arrays).

## Todos

- [x] Write normative layout + JSON schema in this folder or `src/wasm/graph_manifest.zig` module comments
- [x] Implement `src/wasm/graph_manifest.zig`: types, `writeJson`, `toJsonAlloc`, `emitCustomSection` (mirror `node_manifest.zig`)
- [x] TS types + `readGraphManifest(module: WebAssembly.Module)` in `src/ts/graph/` (or `aot_env` sibling)
- [x] Document `kind` ↔ `result_tag` mapping (reuse `node_manifest.kindToResultTag`)
- [x] Unit tests: JSON round-trip, custom-section emit + parse
- [x] Cross-link from `00_overview.md` and `docs/plans/wasm_node_graph/plan.md` (one paragraph)

## Do NOTs

- Do **not** change `mathzig:node` single-port shape or break `--node` CLI.
- Do **not** introduce a second wire-kind enum (no parallel to `abi.WireKind`).
- Do **not** implement full graph codegen or lowerer in this spec.
- Do **not** require multi-value wasm multi-return (`(result f64 f64)`); stick to table or named exports.
- Do **not** bake param defaults into wasm globals as the primary param mechanism.

## Tests

| ID | Test | Location (suggested) |
|----|------|----------------------|
| T1 | `writeJson` ↔ parse equality for fixture manifests | Zig test in `graph_manifest.zig` or `tests/zig/backends/wasm/` |
| T2 | Emit custom section on empty/minimal `WasmModule`, read bytes back | Zig |
| T3 | `readGraphManifest` returns null on modules without section | TS |
| T4 | `readGraphManifest` parses section written by Zig fixture | TS + golden `.wasm` or build in test |
| T5 | Reject / document invalid: empty outputs, unknown kind | Zig or TS validation helper |

Commands:

```bash
zig build test --summary all
bun test src/ts/graph/  # or dedicated graph_manifest test file
```

## Expected outcomes

- [x] Normative multi-**value** I/O contract written and versioned (`abi: 1`)
- [x] `graph_manifest` write/emit/read works without fuse compiler
- [x] Hosts can introspect fused modules the same way they introspect `--node` modules
- [x] No regression in existing `mathzig:node` / AOT parity suites *(additive-only change; full `mz` residual risk accepted — see review Issue 4)*
