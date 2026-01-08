# What MathZig implements (how & why)

Living product description of **landed** capabilities.  
Criterion counts / skips: [`docs/STATUS.md`](../STATUS.md).  
Architecture sketch: [`overview.md`](./overview.md).  
Agent gate: root [`AGENTS.md`](../../AGENTS.md).

**Verification:** last real pass [`verification.md`](./verification.md) (2026-07-16) — code + catalog + targeted tests; not every historical task file.

This document replaces the need to read closed task/spec checklists.

---

## Design principles (why the shape is this way)

| Principle | Consequence |
|-----------|-------------|
| **Zig VM is correctness truth** | All other backends match JSON parity cases against `zig_vm` |
| **Correctness before speed** | `bun run mz` runs correctness first; measure is soft; packages always record |
| **One daily gate** | No feature_id / task_id on the product path; auto run tags only |
| **Honest limits** | Standalone AOT and unit/matrix edges hard-error or quarantine — no silent wrong answers |
| **Editor ≠ export** | Graph **edit** path stays multi-module; **export** may fuse to one module |
| **Instrument UI** | Product console is a dense REPL workstation (`apps/console`), not a marketing shell |

---

## 1. Expression engine

### What

- Parse math expressions → AST → **bytecode** → execute on a **native VM**
- Types: number, complex, matrix, unit, series, record, boolean, string, …
- Builtins: arithmetic, comparisons, logical/bitwise, math, matrix kernels, units, timeseries indicators, ODE helpers (tier varies by backend)

### How

| Layer | Location |
|-------|----------|
| Tokenizer / compiler | `src/parser/` |
| Values | `src/core/value.zig` |
| Bytecode + VM | `src/vm/` |
| Functions / ODE | `src/functions/` |
| Time series | `src/timeseries/` |
| Units | `src/units/` |
| Memory | `src/memory/` (`ChunkArena` for expression lifetime) |

### Why

Native Zig + explicit bytecode gives a single optimizable IR that can be:

1. Interpreted fast on host (SIMD-aware paths)
2. Exposed over FFI to Bun/TS
3. Lowered to WASM (interpreter module or AOT)

Without a shared IR, parity across hosts collapses into ad-hoc ports.

---

## 2. Execution backends

| Backend | Path | Role |
|---------|------|------|
| `zig_vm` | Native adapter | **Reference** answers |
| `ts_ffi` | `src/ts/mathzig.ts` → libmathzig | Production native embed from TS |
| `ts_wasm_vm` | Interpreter WASM | Browser / portable VM |
| `wasm_aot` | Compile expr → freestanding wasm | Deployable modules |
| `wasm_aot_standalone` | AOT with no host imports | Full `mz` only; **skip budget** enforced |

**Daily host backends (parity default):** the first four.  
**Full `mz`:** also runs `wasm_aot_standalone` and enforces `standalone_skip_budget` (skips may only shrink; fails = 0).

**Why multi-backend:** product claims (native, FFI, browser VM, AOT, host-free AOT) must not drift. Same JSON vectors, one compare policy (`tests/parity/compare.ts`).

**Catalog:** `tests/parity/cases/*.json` (**54 files / 629 cases** as of verification) · runner: `tests/parity/cli.ts` (via `mz`).

**Verified residual skips (catalog):** `wasm_aot` = **3** (all 2-arg `round`); `ts_wasm_vm` = **56**; standalone runtime skips ≈ **274** under budget.

---

## 3. WASM AOT

### What

- `mathzig compile` → single-expression (or `--node`) module + manifests
- Optional `--standalone` (no env imports; unsupported ops hard-error)
- ABI / wire kinds in `src/wasm/abi.zig`; compiler in `src/wasm/compiler.zig`
- Host env for non-standalone: TS `AotHostEnv` / delegated imports

### How (user)

See [`wasm_aot_usage.md`](./wasm_aot_usage.md) and [`COMMANDS.md`](../COMMANDS.md).

### Why

AOT exists so MathZig expressions ship as **loadable artifacts** in browsers, edge hosts, and native WASM runtimes — not only as a linked library. Standalone mode exists for hosts that cannot supply `env` imports; the skip budget exists so “standalone” does not silently mean “half the language.”

**Residual debt (tracked in STATUS):** e.g. 2-arg `round` AOT skips; standalone coverage may only shrink.

---

## 4. Graphs (dual model)

### What

| Mode | Implementation | When |
|------|----------------|------|
| **Multi-module (wasm)** | **TS** `GraphRunner` — one wasm instance per compute node; host-mediated edges | **Editor / hot path** (`apps/console` `/graph`) |
| **Fused** | `mathzig compile-graph` + **TS** `FusedGraphRunner` — one module, internal edges | **Export / optimized artifact** |
| **VM-native** | **Zig** `src/graph/runner.zig` `GraphRunner` — in-process VM; **never loads `.wasm`** | CLI `mathzig graph run`, goldens `native_vm` |

> Naming: Zig and TS both export a type named `GraphRunner`. They are **not** the same runtime.

### How

| Piece | Location |
|-------|----------|
| Schema / topo | `src/graph/schema.zig`, `topo.zig` |
| VM-native runner | `src/graph/runner.zig`, `engine.zig` |
| Fuse lowerer | `src/graph/fuse.zig` |
| Graph / node manifests | `src/wasm/graph_manifest.zig`, `node_manifest.zig` |
| TS multi-module | `src/ts/graph/runner.ts` (`WebAssembly.instantiate`, `runBatch`, `setParam`) |
| TS fused | `src/ts/graph/fused_runner.ts`, `fused_compile.ts` |
| Console | `apps/console` routes `/` and `/graph` |
| Goldens | `tests/graph/goldens/` (**12** required files; modes in `tests/graph/corpus.ts`) |
| Cross-runner tests | `tests/ts/graph_cross_runner_parity.test.ts` |

### Why dual model

- **Edit:** recompile one node, keep graph fluid, support opaque wasm nodes later.
- **Ship:** one `tick` entry, edges inside the module, fewer host round-trips (measured win on long scalar chains).
- **Do not** replace the editor with fuse-only — reload cost and opaque nodes break that model.

**Deliberate non-goals (measured):**

- Shared imported memory multi-module: matrix-heavy batch speedup ~1.13× &lt; 2× gate → not prototyped.
- Pure-wasm node interpreter: **phase-2** (goldens skip `native_wasm`).

**Perf baseline (tripwire):** [`docs/reference/graph_tick_baseline.md`](../reference/graph_tick_baseline.md).

---

## 5. Host bindings & codegen

### What

- C-ABI surface defined in `src/api_definition.zig`
- Generated exports under `src/bindings/generated/*` via `zig build gen-bindings`
- TS wrappers: FFI, WASM VM, graph runners

### Why

Hand-written dual ABIs drift. One definition → generated Zig exports + JSON/TS keeps FFI and docs honest.

**Rule:** never hand-edit generated bindings.

---

## 6. Product surfaces

| Surface | Role | How |
|---------|------|-----|
| **CLI** `zig-out/bin/mathzig` | REPL, `compile`, `compile-graph`, `graph run` | `src/main.zig` |
| **TUI** | Terminal REPL | `src/tui/` + libvaxis |
| **Console** | Browser REPL + plots + graph editor | `apps/console` + freestanding wasm in `public/` |
| **Progress** | Correctness/perf history | `apps/progress` fed by `mz` |
| **Hosts** | AOT demos | `hosts/` (Wasmer, WasmEdge, Spin) |

**Why console ≠ `web/`:** product UI is Solid/Vite app with routes and AOT APIs; `web/` holds demos/artifacts only.

Design intent: [`PRODUCT.md`](../../PRODUCT.md), [`DESIGN.md`](../../DESIGN.md).

---

## 7. Quality system (hardening)

### What landed

| Capability | Mechanism |
|------------|-----------|
| Daily pipeline | `bun run mz` → correctness → measure → progress package |
| Strict bun gate | `tools/testing/strict_bun_gate.ts` + `tests/known_failures.json` quarantine |
| Parity harness | JSON catalog + 4 backends + single `compare.ts` |
| Standalone budget | `tools/testing/standalone_skip_budget.ts` (skips may only shrink; fails = 0) |
| Graph corpus | Goldens × `ts_wasm` / `native_vm` / `zig_vm` oracle |
| Adversarial | Default fuzz in gate; deep optional `adversarial_deep` |
| Units honesty | Hard errors on dishonest unit/matrix paths (vs silent strip) |
| Soak / leak focus | Soak tests under `tests/soak/` |
| Docs truth | Generated `docs/STATUS.md` via `tools/status_report.ts` |
| Graph perf tripwire | vs committed baseline in full `mz` (not `--quick`) |

### Why

A green demo is not a product. Quarantine makes known debt **visible**; unexpected fail/pass fails the gate. STATUS is regenerable so prose cannot lie about counts.

---

## 8. Language & library features (implemented themes)

Behavior is enforced by **parity + Zig tests**, not by historical task files.  
Theme → case-file mapping verified 2026-07-16 (see [`verification.md`](./verification.md)).

| Theme | Evidence (examples) | Notes |
|-------|---------------------|--------|
| Core arithmetic / logic | `core_*`, `basic`, `chained_logic` | **PROVEN** |
| Control flow | `compiler`, `jump_fusion`, `shadowing` | **PROVEN** |
| Matrices | `matrix_ops*`, `matrix_slicing*`, `gemv` in linalg/gauntlet | **PROVEN**; MathJS slice/power **quarantined** |
| Complex | `complex*`, `builtins_comb_complex` | **PROVEN** base; full pow/trig matrix **not** claimed |
| Units | `units*`, VM `MatrixUnitElementUnsupported` | **PROVEN** honesty path |
| Records | `records*`, field access | **PROVEN**; MathJS object mutation **quarantined** |
| Series / indicators | `timeseries*`, `builtins_ts` | **PROVEN** |
| User functions / sequences | `dsl_functions` (`f(x)=…; f(10)`) | **PROVEN** |
| DSL / generators | `dsl_*`, `src/functions/generators.zig` | **PROVEN** modules + cases |
| ODE / sims | `ode*`, `simulations.json` | **PROVEN**; rocket+units **quarantined** |
| LaTeX / display | `src/parser/latex.zig`, `toLaTeX` cases, console | **PROVEN** |
| SIMD / hot paths | `executeBatchSIMD`, matrix kernels | **PROVEN** code paths (not re-benched here) |
| String compare operators | — | **WEAK** — no dedicated parity theme found |
| Matrix integer power `M^n` | quarantine | **RESIDUAL** |

**Open residual** (STATUS + `known_failures.json`): MathJS examples (power, slices, units display, record mutation), rocket/ODE unit forms, AOT 2-arg `round`, pure-wasm graph interpreter (phase-2).

---

## 9. How to verify anything claimed here

```bash
export PATH="$PWD/tools/macos-sdk-shim:$PATH"
bun run mz                          # full gate + package
bun tools/status_report.ts          # refresh docs/STATUS.md
cd apps/progress && bun run dev     # trends / regressions
```

| Claim type | Evidence |
|------------|----------|
| Expression semantics | `tests/parity/cases/*.json` + mz parity CSVs |
| Graph behavior | `tests/graph/goldens/` |
| Known debt | `tests/known_failures.json`, STATUS quarantine table |
| Perf non-regression | mz measure + progress packages; graph tripwire baseline |
| Product UI | `apps/console` against copied wasm |

---

## 10. What we deliberately do **not** claim

- “100% MathJS parity” — translated examples still quarantine several cases
- “Standalone AOT = full language” — budgeted skips
- “Fused path replaces the editor”
- “Pure-wasm graph interpreter is shipping” — phase-2
- Task/spec checkboxes as live status — **STATUS.md only**
