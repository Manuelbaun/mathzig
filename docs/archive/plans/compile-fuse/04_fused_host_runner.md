# Spec 04 — Fused host runner (multi input/output values)

**Depends on:** 01, 02, 03  
**Unblocks:** 05, 06, 08  
**Scope:** TypeScript host API to run a fused module; goldens vs multi-module

## Goal

Provide a host path that:

1. Instantiates **one** wasm module  
2. Accepts multiple **input values** (and params)  
3. Returns multiple **output values** as `Record<string, GraphValue>`  
4. Matches multi-module `GraphRunner.run` on golden graphs  

## API sketch

```ts
// src/ts/graph/fused_runner.ts (name flexible)
class FusedGraphRunner {
  static async load(
    wasm: Uint8Array | WebAssembly.Module,
    options?: { host?: AotHostEnv; env?: ScalarWasmImports },
  ): Promise<FusedGraphRunner>;

  /** Manifest-driven; keys = graph input names + optional param overrides */
  run(inputs: Record<string, GraphValue>, paramOverrides?: Record<string, number>): GraphRunOutputs;

  setParam(name: string, value: number): void; // fused flat param name
  dispose(): void;
  manifest: GraphManifest;
}
```

Also:

```ts
async function compileFused(
  def: GraphDefinition,
  compiler: WasmCompiler, // may be multi-expr aware or CLI-backed
): Promise<Uint8Array>;
```

`compileFused` may live in TS calling native binary (like console AOT plugin) until pure in-process path exists.

## Todos

- [x] `readGraphManifest` integration (01)
- [x] Build import object from `mathzig.abi` + fused needs (reuse `AotHostEnv` / scalar env)
- [x] Implement `run` for `out_mode: "named_exports"` (scalar)
- [x] Implement `run` for `out_mode: "table"` (scalar f64 table)
- [x] Param store + `setParam` without re-instantiate
- [x] Golden suite: `FusedGraphRunner` ≡ `GraphRunner` for fixtures
- [x] Determinism: two `run`s same inputs → bit-identical scalars
- [x] Progress/errors: clear message if section missing (“not a fused graph module”)
- [x] Export from `src/ts/graph/index.ts`

## Do NOTs

- Do **not** replace `GraphRunner` or change default editor load path in this spec.
- Do **not** fork matrix/record decode; call `value_transfer` / `AotHostEnv` only (even if scalar-only now).
- Do **not** require N `WebAssembly.instantiate` calls for fused path.
- Do **not** silently drop outputs not listed in manifest.
- Do **not** reintroduce regex result-type guessing; use manifest `result_tag` / kind.

## Tests

| ID | Fixture | Expected |
|----|---------|----------|
| T1 | 3-node scalar chain, 1 out | fused ≡ multi |
| T2 | 2 outs from chain mid+end | both keys present; values ≡ multi |
| T3 | Diamond shared node | fused ≡ multi (no wrong double-apply if Stage B) |
| T4 | Params | `setParam` then `run` matches multi `setParam` |
| T5 | Missing input | throws with input name |
| T6 | Module without `mathzig:graph` | load throws |
| T7 | Pure scalar | no requirement for host Full-Value env |

```bash
bun test tests/ts/graph/fused*.ts
# or tests/ts/graph/compile_fuse*.ts
```

## Expected outcomes

- [x] Host returns **multiple output values** from **one** module  
- [x] Golden property vs multi-module green for scalar fixtures  
- [x] Editor multi-module path untouched  
- [x] API usable by CLI harness (05) and later console export (06)  
