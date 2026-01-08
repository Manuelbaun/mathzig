# Task 0097: WASM AOT Real Standalone Runtime Matrix

- **Status:** Open (verified 2026-07-15 — maps to specs standalone tiers)
- **Priority:** Critical (P0)
- **Category:** WASM Backend / Runtime

## Overview
Goal: make AOT output truly standalone for `wasmer`, `wasmtime`, browsers, no `env.*` imports, no stubs.

Current `--standalone` only solves instantiation for a narrow set. It still:
- stubs `ode_solve_euler` to `NaN`
- rejects many builtins in codegen
- has no standalone path for `*_where` variants

## Scope
- **Paths:** `src/wasm/compiler.zig`, `src/wasm/math_lib.zig`, `src/wasm/module.zig`, `src/vm/bytecode.zig`
- **Reference runtime shim (to replace):** `tests/parity/backends/wasm_aot.ts`
- **CLI/API:** `src/main.zig` (`compile --standalone`)
- **Invariants:**
  - standalone wasm has `imports []`
  - no semantic stubs for supported language features
  - deterministic behavior across runtimes
  - AOT output is tree-shaken per input script (emit only used wasm-backend helpers)

## Findings
- External imports are still core mechanism in AOT: `addImport("env", ...)` in compiler.
- Builtin lowering is mixed:
  - some inline/opcode (`sqrt`, `floor`, `ceil`, etc.)
  - some local helper (`sin`, `pow`, now `exp/log/fmod` in standalone)
  - most delegate to host imports.
- Parity backend host env currently implements a large pseudo-runtime (matrix, series, ODE, stats, CSV, random, etc). Standalone backend must absorb this.
- `wasmer foo.wasm` expects `_start`; current modules are function-export modules. This is okay with `--invoke`, but entrypoint policy must be explicit.

## Tree-Shaken Compilation Contract (Per Script, Any Script)
During AOT compilation, the compiler must include only backend functions/helpers that are reachable from the to-be-compiled script.

### Required behavior
- Build a per-script dependency graph from compiled bytecode:
  - reachable functions (`main` + user functions reached via `call_user`)
  - used builtins (`call_builtin`, `call_builtin_where`)
  - opcode families that require runtime helpers
- Resolve transitive dependencies (example: `pow` requires `log` + `exp` helper in standalone path).
- Emit only resolved helper/runtime methods into final wasm.
- Exclude all unused backend helper functions from emitted module.
- Apply same tree-shake logic for both:
  - default AOT (imports allowed)
  - standalone AOT (imports forbidden)

### Compiler design notes
- Add explicit dependency registry in `src/wasm/compiler.zig`:
  - `BuiltinFn/opcode -> helper emitter(s) / import fallback`
- Replace ad-hoc registration with registry-driven finalization pass.
- Finalization pass computes exact `RequiredRuntimeSet` before emitting helper code/imports.
- In standalone mode:
  - unresolved dependency => hard compile error
  - no broad fallback, no silent stubs.

### Acceptance criteria
- Different scripts produce different runtime helper sets when features differ.
- Scalar-only script does not include ODE/matrix/series helpers.
- ODE script includes ODE + only scalar deps actually used.
- For standalone output, `WebAssembly.Module.imports` is empty and explainable by dependency report.
- Build can output deterministic dependency report (`used builtins`, `emitted helpers`, `dropped helpers`).

## Implementation Matrix (Complete Surface)

| Surface | Functions / Symbols | Current AOT path | Standalone gap | Required backend work |
|---|---|---|---|---|
| Scalar core (already local) | `abs`, `sqrt`, `floor`, `ceil`, `round`, `trunc`, `min`, `max`, `sin`, `pow`, `%/fmod`, `exp`, `log` | inline/op/local helper | partial only | keep, harden edge-cases (`NaN`, `inf`, signed zero) |
| Scalar math missing | `cbrt`, `log10`, `log2`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `tanh`, `asinh`, `acosh`, `atanh`, `sec`, `csc`, `cot`, `asec`, `acsc`, `acot`, `sech`, `csch`, `coth`, `asech`, `acsch`, `acoth`, `sign`, `clamp`, `hypot`, `norm`, `square`, `cube`, `nthRoot`, `log1p`, `expm1` | mostly host import | not implemented local | add wasm-local builtins or lower to existing primitives; define precision/tolerance targets |
| Special/combinatorics | `factorial`, `gamma`, `lgamma`, `erf`, `combinations`, `permutations`, `gcd`, `lcm`, `isPrime` | host import | missing local impl | implement deterministic scalar algorithms in wasm backend |
| Complex helpers | `re`, `im`, `arg`, `conj` | host import + host memory helper | missing local impl | implement complex memory layout ops in compiler/runtime helpers |
| Matrix/Linalg | `det`, `inv`, `transpose`, `gemv`, `size`, `trace`, `dot`, `cross`, `reshape`, `flatten`, `concat`, `diag`, `identity`, `zeros`, `ones` | host import + `mathzig_gemm` service | missing local impl | implement matrix runtime helpers in wasm backend; remove external GEMM import path |
| Stats reductions | `mean`, `sum`, `count`, `median`, `std`, `variance`, `mad`, `prod` | host import | missing local impl | implement scalar + matrix + series reductions inside wasm runtime |
| Cumulative/window ops | `cumsum`, `cummax`, `cummin`, `rolling_sum`, `rolling_mean`, `rolling_min`, `rolling_max`, `rolling_count`, `rolling_stddev`, `diff`, `pct_change` | host import | missing local impl | add standalone time-series kernels |
| Time-series core | `series`, `twa`, `derivative`, `integrate`, `sma`, `ema`, `rsi`, `last`, `duration`, `asofJoin`, `resample`, `align_`, `head`, `tail`, `slice`, `between`, `since`, `shift`, `dropna`, `fillna`, `clip` | host import | missing local impl | implement full series data model + ops in wasm heap |
| Indicators | `bollinger`, `macd` | host import | missing local impl | implement as pure wasm functions returning record-compatible layout |
| Generators | `gen_range`, `linspace`, `logspace`, `agg_range` | host import | missing local impl | implement deterministic matrix/vector generators |
| ODE | `ode_solve`, `ode_solve_euler` | host import (`ode_solve_euler`) / stub in standalone | stubbed or missing | implement native ODE solver path in standalone runtime; support user callback invocation |
| Units/config | `conv`, `number`, `create_unit`, `config` | host import or unsupported | missing local impl | embed unit conversion + runtime config handling in wasm backend |
| I/O + assert | `read_csv`, `write_csv`, `assert` | host import | policy undefined | decide: WASI support vs explicit unsupported-in-standalone errors with diagnostics |
| Random/time policy | `random`, `randomInt`, `pickRandom`, `now` | host import | policy undefined | define deterministic PRNG + time source strategy (seeded mode + optional host mode) |
| Where variants | `*_where` forms via `call_builtin_where` | host import (`name_where`) | no standalone lowering | lower predicates + filter/aggregate logic in wasm backend, remove dynamic where imports |
| Runtime service | `mathzig_gemm` | direct host import | external dependency | inline gemm kernel / internal runtime call only |
| Module entrypoint | `_start` export contract | not exported | CLI friction in wasmer | optional compile mode `--entry _start` or tiny start wrapper calling selected function |

## Phase Plan
1. [ ] Build standalone lowering map for all `BuiltinFn` + `call_builtin_where`.
2. [ ] Implement scalar/special math local helpers first (fastest import reduction).
3. [ ] Implement matrix runtime primitives + remove `mathzig_gemm` host import.
4. [ ] Implement series runtime + stats/window ops + indicator stack.
5. [ ] Implement ODE runtime in wasm backend (replace `ode_solve_euler` stub).
6. [ ] Finalize policy for `read_csv/write_csv/now/random` in standalone.
7. [ ] Add entrypoint option (`_start`) for plain `wasmer file.wasm` UX.

## Verification Matrix
- [ ] Import surface: `WebAssembly.Module.imports(module).length === 0` for standalone builds.
- [ ] Standalone execution: `wasmer file.wasm --invoke eval` works for scalar, matrix, series, ODE catalogs.
- [ ] Cross-runtime: `wasmer`, `wasmtime`, browser `WebAssembly.instantiate` parity.
- [ ] Parity: same outputs as `zig_vm` for supported standalone surface.
- [ ] No host shim dependency in `tests/parity/backends/wasm_aot.ts` when standalone mode is selected.

## Progress Log
- 2026-02-25: Task created. Compiler/import surface analyzed. Full standalone implementation matrix drafted.

---

## Verification (2026-07-15)

- **True status:** `OPEN`
- **Evidence:** standalone mode code present=True; addImport sites=6
- **Notes:** True zero-import standalone runtime matrix not finished.
- **Audit:** [true_status_audit.md](true_status_audit.md)

