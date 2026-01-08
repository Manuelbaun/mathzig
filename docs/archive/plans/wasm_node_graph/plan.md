# WASM AOT Full Parity + Chainable WASM Node Graph

> **SUPERSEDED / HISTORICAL (2026-07-15).**  
> This plan describes the **pre-stream-A/B architecture and sequencing**. Workstreams
> A0–A6 and B1–B5 have been implemented with residual acceptance debt; stream C
> (specs 12–20) hardens gates and burns that debt.  
> **Do not treat sections below as current status** — especially claims that “no
> graph exists”, “A1 remains next”, or “B5 deferred”.  
> **Current status:** [`docs/STATUS.md`](../../STATUS.md) (generated) · task specs:
> [`docs/STATUS.md`](../../STATUS.md) · audit snapshot:
> [`docs/AUDIT_2026-07-10.md`](../../AUDIT_2026-07-10.md).  
> Banner date: 2026-07-15 (task-20 / C9). Body left intact as design history.

## Context

Two goals: (1) make the `wasm_aot` backend **fully parity-compatible** (chosen scope: literally everything — units, records, strings, complex, series — phased), and (2) a **node-graph system**: multiple AOT-compiled wasm modules chained (node A's output → node B's input), full MathZig Values on edges, runnable in browser **and** native, configured by JSON (DSL sugar later).

### Audit findings (verified, file:line)

> **Historical baseline** (pre A/B implementation). Live counts: see `docs/STATUS.md`.

- Parity harness: 231 cases / 43 files; `wasm_aot` is skipped in only **7 cases** — 5 `toLaTeX` string-output (`metadata_api.json`), 2 ODE-sim→matrix (`simulations.json`). The "big gap list" in `docs/tasks/0080` is stale (those skips are `ts_wasm_vm`, not `wasm_aot`).
- But the foundation is fragile:
  - The env-import contract is **informal** (`env.<builtin>` all-f64, `src/wasm/compiler.zig:935/:1001`) and hand-reimplemented in **3 places**; the parity backend alone hand-writes ~100 builtins in JS (`tests/parity/backends/wasm_aot.ts:330+`, incl. its own gamma, RNG, Euler integrator).
  - `*_where` predicate imports are served by a Proxy that **ignores the predicate** (`wasm_aot.ts:1104`) — silently wrong semantics.
  - `get_index` with >2 keys silently pushes **NaN** (`compiler.zig:3218`); `mat_index`/`set_index` are `error.UnsupportedOpcode` (`:4046`) — so matrix slice *assignment* can't compile (VM has open todos here too, task 0093).
  - Result-type detection in the host is **regex guessing** (`likelyMatrixExpr`, `wasm_aot.ts:1158`) even though the compiler statically knows the result tag (type stack).
  - Standalone (`-s`) supports only exp/log internally; series values are host-side JS handles; ODE stepping is a hand-rolled JS loop with 2 hardcoded deriv functions (`wasm_aot.ts:1288`).
- AOT module shape today: exports `eval: N×f64 → f64` (+ `memory`/`heap_ptr`/`reset_heap` when heap used, `compiler.zig:279-310`); matrices `[rows,cols,f64…]` and records/complex/strings in linear memory as f64-encoded pointers; `heap_ptr` is an exported *mutable* global, so a host can write inputs into a module's heap — key enabler for node edges.
- User functions are already exported by name (`compiler.zig:308`) — an env-side ODE driver can call back into the module's compiled deriv function.
- Codegen-from-Zig precedent exists: `src/api_definition.zig` → `tools/bindings/abi_inspector.zig` → `src/bindings/generated/*` (`build.zig:36-55`).
- No graph/pipeline code exists anywhere; `docs/ideas/aot/README.md:88` already names wasm composition as a product direction.

### Central architecture (shared by both workstreams)

1. **`src/wasm/abi.zig` — single source of truth** (comptime-queryable): builtin signature table over `BuiltinFn` (arg kinds: number / matrix_ptr / string_ptr / series_handle / record_ptr / complex_ptr / predicate_ptr; return kind; where-capable; standalone tier), boundary value encodings (matrix, record, complex, length-prefixed string, 24-byte predicate, series handle base), ABI version.
2. **`mathzig.abi` custom section** in every compiled module (writer in `src/wasm/module.zig`): ABI version, required imports, exported functions, **static result tag** (from the compiler's type stack — kills the regex guessing), heap base. Plus an `alloc(n)→ptr` export so hosts stop poking `heap_ptr` raw. This custom section doubles as the **node manifest** the graph loader introspects.
3. **Generated, delegated host env** (replaces the 3 hand-written copies): `src/ts/aot_env.ts` (marshal kernel) + generated per-builtin stubs. Non-trivial builtins **delegate to the real engine** (FFI ctx under bun/native, `MathZigWasm` in browser) via one new generic export `mathzig_call_builtin(ctx, builtin_id, argc, args_ptr, pred_ptr)` added through `src/api_definition.zig` → **parity by construction**; scalar libm stays `Math.*` fast path (knob: `delegated | fast-scalar`). `_where` stubs decode the 24-byte predicate payload and call the real where-variant — the Proxy dies.

## Workstream A — AOT full parity

**A0. Formalize ABI (landed).** `src/wasm/abi.zig`; `registerBuiltin`/`registerBuiltinWhere` derive signatures from the table (unknown builtin = compile error, not a silent import); custom section + `result_tag` + `alloc`; `tools/bindings/` generator emits `src/bindings/generated/aot_abi.json`. Also: `std.debug.print` bytecode dumps at `compiler.zig:228-241` moved behind a verbose flag. Verified with Zig tests + parity unchanged; new test asserts every codegen-reachable builtin has a table entry.

**A1. Generated delegated host env.** New `src/ts/aot_env.ts` + generated stubs; `mathzig_call_builtin` + predicate-builder exports via `api_definition.zig`. Gut `tests/parity/backends/wasm_aot.ts` (~1000-line env, Proxy, regexes → custom-section-driven decode); `createDefaultWasmEnv` becomes a re-export. Risk control: land as `wasm_aot` vs `wasm_aot_legacy` backends for one cycle, diff, then delete legacy. Expect latent `_where` diffs to surface — fix each against `zig_vm`.

**A2. Close the 7 skips → zero.**
- toLaTeX (5): string-return ABI (`result_tag=string`, `[u32 len][bytes]`); constant-fold `toLaTeX` of static args at compile time using the existing Zig LaTeX generator; dynamic arg → delegated import.
- ODE sims (2): `env.ode_solve(_euler)` host driver that resolves the deriv via `instance.exports[name]` and steps **op-for-op like `src/functions/ode.zig`** (RK4/Euler, same trajectory-matrix layout incl. time column); deriv math runs inside the module. Delete `callOdeFunc`.

**A3. Kill silent NaN + slice assignment (VM-first).** (1) `get_index` >2 keys: NaN → hard error (land first). (2) Finish VM slice-assignment todos (task 0093 — this is also parity-plan Phase A). (3) New `cases/matrix_slice_assign.json`, green on `zig_vm`. (4) Implement `set_index`/`mat_index`/multi-key `get_index` in AOT codegen against settled VM semantics.

**A4. Standalone tiers (task 0097).** `RequiredRuntimeSet` from abi.zig tier tags; unresolved dep in `-s` = hard error. Tier 1 scalar libm bodies in `math_lib.zig`; Tier 2 matrix helpers; Tier 3 in-wasm ODE (static deriv name → direct call; `call_indirect` only for dynamic); Tier 4 series in linear memory `[u32 len][ts…][vals…]` (shared with node graph). `--standalone` parity sub-run.

**A5. Parity hardening (task 0096).** Generated per-builtin gauntlet derived mechanically from the abi.zig table (provable 100% coverage), + seeded differential fuzz `wasm_aot` vs `zig_vm` under `compare.ts` tolerances; failures minimized into permanent cases.

**A6. Full-Value long tail.** Units: static dimensional analysis + folded conversion factors at compile time, unit annotation in the custom section; dynamic units via delegation. Records/strings/complex first-class per A0 ABI; series → linear memory (Tier 4).

## Workstream B — Node graph (chained wasm modules)

**Decisions:** edges are **host-mediated copies** (not shared imported memory — that's dynamic linking; revisit in B4 only if profiling demands): scalar = plain f64; matrix/complex = raw block copy into consumer heap (layouts are self-contained/relocatable); record = ABI wire encoding (decode/re-encode fallback until A0 lands); series = handle pass-through via **one shared HostEnv across all node instances**. Node manifest = `mathzig:node` custom section + JSON sidecar, emitted by `mathzig compile --node`. Config params are compiled as trailing params (never baked globals) → runtime-tunable without recompile. Graph JSON v1: nodes (`expr` | `wasm` | `const` | graph `inputs`/`outputs`), edges `"lp.out" → "gain.x"`, Kahn topo sort, cycles = load error (feedback later via explicit `delay` node).

**Compile-fuse (follow-on):** whole-graph one-module path uses a separate `mathzig:graph` multi-value manifest (`src/wasm/graph_manifest.zig`, `src/ts/graph/graph_manifest.ts`) — see [`docs/plans/compile-fuse/00_overview.md`](../compile-fuse/00_overview.md). Editor multi-module `GraphRunner` stays; fuse does not overload `mathzig:node`.

Per-tick node protocol: `reset_heap()` → write non-scalar inputs into heap → `eval(...)` → decode output before that node's next reset.

**B1. Scalar MVP (landed).** `src/ts/graph/{schema,topo,runner,compile_cache}.ts`; GraphRunner API `load(def, {compiler, env}) / run(inputs) / setParam(node, name, v) / dispose()`; compile cache lifted from `tests/parity/wasm_aot.ts` semantics (key = sha1(expr|compilerVersion)); tested 3+-node JSON graph == single-expression eval in bun. Browser path is API-compatible through injected compiler/env; browser page remains B3.
**B2. Full-Value edges + `--node` CLI** (`src/main.zig` compile branch: `--node --in x:matrix --param alpha:scalar=0.1 --out matrix`; force memory exports; new `src/wasm/node_manifest.zig`); `value_transfer.ts` per-type transport; factor the host readers (readMatrix/readRecord/handle stores) out of the parity backend into shared `src/ts/` code.
**B3. Runtime config + browser demo:** `setParam`, node `reload(id, expr)`, `web/graph_demo.html` + `web/graph_controller.js` (JSON textarea, param sliders, tick).
**B4. Performance (measured):** batch tick loops with per-edge Float64Array lanes (successor of `mathzig_batch_eval_simd`); only then evaluate shared imported memory.
**B5. Native Zig runner + DSL sugar** (`graph { a = lowpass(x); ... }` lowering to the same JSON). Native runner needs an embedded wasm interpreter — deferred; manifest-driven design keeps the port mechanical.

## Recommended sequencing

> **Historical sequencing (superseded).** A0–A6 and B1–B5 are implemented; residual
> debt was burned under stream C (`docs/tasks/archive/specs/task-12`…`task-20`); live status is `docs/STATUS.md`.

1. **A0 and B1 landed** — ABI formalization and scalar node graph are in place.
2. **A1 remains next** (delegated env) — downstream work should consume A0 custom sections and avoid adding local host shims.
3. **A2** (zero skips) then **A3** (slice assignment; also closes parity-plan Phase A).
4. **B2/B3** can reuse the landed A0 ABI/manifest + value-transfer pieces.
5. **A4/A5/A6, B4/B5** as follow-on tranches.

## Verification

Per phase (per AGENTS.md): `zig build vm-baseline --summary all && zig build test --summary all && bun test && bun tests/parity/cli.ts --full`. Specific:
- A1: `wasm_aot` vs `wasm_aot_legacy` diff run before deleting legacy env.
- A2: full parity with **zero** `skip: ["wasm_aot"]` entries.
- A3: `grep` codegen for NaN-sentinel fallbacks → none except genuine math NaN.
- B: golden property — for any expression split into nodes g→f, `GraphRunner.run()` == `zig_vm` eval of the composed expression (table-driven: scalar, matrix, record, series); determinism test (two runs identical, heap-reset discipline); manifest custom-section round-trip test.

## Critical files

- `src/wasm/abi.zig` (new), `src/wasm/compiler.zig`, `src/wasm/module.zig`, `src/wasm/math_lib.zig`, `src/wasm/node_manifest.zig` (new)
- `src/api_definition.zig`, `tools/bindings/abi_inspector.zig`, `build.zig`
- `src/ts/aot_env.ts` (new), `src/bindings/generated/aot_env.ts` (generated), `src/ts/graph/*` (new)
- `src/main.zig` (compile subcommand flags), `src/functions/ode.zig` (reference semantics)
- `tests/parity/backends/wasm_aot.ts` (gutted), `tests/ts/wasm_utils.ts`, `tests/parity/cases/*` (new case files)
- `web/graph_demo.html`, `web/graph_controller.js` (new)
