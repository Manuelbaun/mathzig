# Plan 00: MathJS Parity — Strengths, Gaps, and Improvement Areas

**Priority:** 🟢 Foundational · **Last updated:** 2026-07-15 · **Status:** Living overview — live counts in `docs/STATUS.md`

> **Status banner (2026-07-15, task-20).** Snapshot tables below were corrected
> against the parity catalog + MathJS translated inventory. For regenerable
> totals (backends, quarantine, graph corpus) always prefer
> [`docs/STATUS.md`](../STATUS.md). Do not treat older “43 files / 98 cases”
> figures as current.

---

## Purpose

This document is the canonical parity overview for MathZig vs MathJS. It consolidates:

- Feature-level strong / partial / weak areas
- Translation feasibility for `libs/mathjs/examples`
- Concrete improvement backlog with linked tasks
- Verification commands and artifact locations

Related docs:

- [mathjs_vs_mathzig_comparison.md](../comparisons/mathjs_vs_mathzig_comparison.md) — broad feature inventory (some rows outdated; prefer this doc + parity tests)
- [test_parity_plan.md](../test_parity_plan.md) — Zig/FFI/WASM backend parity progression
- [Task 0084 index](../tasks/0084_0_index.md) — MathJS examples defect closure (core 55/55 complete)

---

## Current Parity Snapshot

| Harness | Scope | Latest result | Command |
|---------|-------|---------------|---------|
| **MathJS examples** | ~44 translated JSON files · **286** cases (core **63** / extended **221** / unsupported **2**) | Core cases run under `run_translated.test.ts`; failures classified in `tests/known_failures.json` (see STATUS.md quarantine) | `bun test tests/ts/parity/mathjs_examples` |
| **Expression parity** | **54** JSON case files · **629** cases (catalog inventory 2026-07-15) | Live pass/fail/skip per backend in STATUS.md artifacts; catalog skips: `ts_wasm_vm` 56, `wasm_aot` 3, standalone inherits wasm_aot | `bun tests/parity/cli.ts --full` |
| **Rocket simulation** | Multi-stage ODE + units | Active parity test | `bun test tests/ts/simulations/rocket_simulation` |

> **Note:** Live regenerable totals: [`docs/STATUS.md`](../STATUS.md). Historical core phase (55 evaluate-expressions → 55/55 on 2026-02-23) is archived under `docs/tasks/archive/`. Residual MathJS failures are **quarantined** (strict gate), not silent.

---

## Parity Strength Table

Areas where MathZig matches or exceeds MathJS for numeric / DSL workloads.

| Area | MathJS baseline | MathZig status | Evidence |
|------|-----------------|----------------|----------|
| **Core arithmetic** | `+ - * / % ^`, precedence, ternary | ✅ Strong | `core_arithmetic.json`, `basic.json`, `basic_usage.test.ts` |
| **Expression eval** | `evaluate(expr)` | ✅ Strong (compile + VM) | `vm_baseline.json`, `compiler.json` |
| **Variables & assignment** | scope + `x = 7` | ✅ Strong | `dsl_state.json`, `expressions.test.ts` |
| **DSL functions** | `f(x) = x^2` | ✅ Strong | `dsl_functions.json`, nested locals |
| **Records / objects** | `{a: 1}.a` | ✅ Strong | `records.json`, `objects.test.ts`, `chained_logic.json` |
| **Complex numbers** | `3+4i`, `sqrt(-4)` | ✅ Strong | `complex.json`, `builtins_comb_complex.json`, `complex_numbers.test.ts` |
| **Trigonometry** | sin/cos/tan + inverses | ✅ Strong (incl. sec/csc/cot) | `builtins_trig.json` |
| **Elementary math** | sqrt, log, exp, round, clamp | ✅ Strong | `builtins_math.json` |
| **Dense linear algebra** | det, inv, transpose, dot, cross | ✅ Strong | `builtins_linalg.json`, `matrix_ops.json` |
| **Matrix generators** | zeros, ones, identity, range, linspace | ✅ Strong | `builtins_linalg.json`, `matrices.test.ts` |
| **Matrix arithmetic** | `A * B`, `A + B`, `A^2` | ✅ Strong | `matrix_ops.json`, `chained_logic.json` |
| **Units (numeric)** | `cm`, `deg`, `conv`, `to` | ✅ Strong | `units.json`, `units.test.ts`, rocket sim |
| **Unit engineering** | gas law, circuits, cross(B,v) | ✅ Strong | `simulations.json`, `matrix_units.json` |
| **ODE solvers** | `solveODE` (MathJS addon) | ✅ Strong (native RK4 + Euler) | `ode.json`, `simulations.json`, `vector_ode.json` |
| **Statistics builtins** | mean, std, median, … | ✅ Strong | `builtins_stats.json` |
| **Combinatorics** | factorial, combinations | ✅ Strong | `builtins_comb_complex.json`, `builtins_nt.json` |
| **Probability** | distributions | ✅ Strong | `probability.json` |
| **Time series** | limited in MathJS | ✅ **Exceeds MathJS** | `timeseries_*.json` (filters, joins, indicators, resampling) |
| **LaTeX output** | via formatting | ✅ Strong (`toLaTeX`) | `metadata_api.json` |
| **Performance** | JS interpreter | ✅ **Exceeds MathJS** | SIMD batch, bytecode, WASM, multi-thread GEMM |
| **FFI / WASM** | browser bundle | ✅ Strong | `ffi_boundary.json`, `wasm_backend.json` |

---

## Parity Weakness Table

Areas where MathZig is behind MathJS or intentionally out of scope.

| Area | MathJS capability | MathZig gap | Severity | Policy |
|------|-------------------|-------------|----------|--------|
| **Symbolic algebra** | `simplify`, `derivative` on AST | No CAS | 🔴 Hard gap | Out of scope (numeric focus) |
| **BigNumber** | arbitrary precision decimal | float64 only | 🔴 Hard gap | Use external lib if needed |
| **Fraction** | exact rationals | float64 only | 🔴 Hard gap | Out of scope |
| **Sparse matrices** | native sparse type | dense only (large identity works) | 🟡 Soft gap | Dense path covers many cases |
| **Linear solvers** | `solve`, `eig` (via numeric.js) | not implemented | 🔴 Hard gap | BLAS ops yes; solvers no |
| **Chain API** | `chain(3).add(4).done()` | no fluent wrapper | 🟢 Cosmetic | Rewrite as expressions |
| **Expression trees** | `parse` → filter/traverse/transform | no exposed AST API | 🟡 API gap | Internal AST exists, not exported |
| **Function transforms** | `.transform` hooks | not supported | 🟡 API gap | Use DSL / Zig builtins |
| **math.import()** | extend runtime with JS objects | DSL + fixed builtins only | 🟡 API gap | `import.test.ts` covers DSL subset |
| **Custom datatypes** | typed-function factories | fixed value tags | 🔴 Hard gap | Records cover structured data |
| **JSON serialization** | `replacer` / `reviver` | no math-type codec | 🟡 API gap | Host handles serialization |
| **JS scope callbacks** | `scope.hello = function()` | not supported | 🟡 API gap | Use `hello(x) = ...` DSL |
| **Matrix slice assign** | `m[1,1:2] = [5,6]`, `m[:,1]` | largely implemented (VM + AOT step parity via task-18 D2); residual MathJS example chains quarantined | 🟡 Residual | See §3.1 |
| **round(x, n)** | decimal-place rounding | VM supports 2-arg; residual `wasm_aot` catalog skips on round decimals | 🟡 Residual | STATUS.md wasm_aot skips |
| **String relations** | custom `equal`, numeric string compare | not configurable | 🟡 API gap | `0095` |
| **Unit simplification** | `100000 N/m^2` → `100 kPa` | limited derived-unit display | 🟡 Soft gap | `0032` follow-ups |
| **createUnit** | runtime unit definition | partial / task-tracked | 🟡 Soft gap | `0069` |
| **1-based matrix indexing** | parser uses 1-based slices | 0-based indexing | 🟢 Doc gap | Document in ports |
| **Browser demos** | Plotly/MathJax/RequireJS | no first-party examples yet | 🟡 DX gap | See §5 recommended examples |

---

## Partial Parity Table (Works with Adaptation)

| MathJS pattern | MathZig equivalent | Caveat |
|----------------|---------------------|--------|
| `evaluate(expr, scope)` | `ctx.eval(expr)` with persistent context | Scope is MathZig context, not plain JS object |
| `compile(expr).evaluate()` | `ctx.compile(expr).evaluate()` | ✅ Same model |
| `parser()` | `MathZig.create()` | No `get`/`set`/`clear` helpers on TS side |
| `unit(5, 'cm')` | `5 * cm` or `conv(5*cm, mm)` | Constructor-style `unit()` not required |
| `2 inch to cm` | `2 inch to cm` or `conv(2*inch, cm)` | Both supported |
| `number(5 cm, mm)` | `number(5*cm, mm)` | Added for examples parity ([0084.1](../tasks/0084_1_mathjs_examples_core_defects.md)) |
| `chain(x).add(y).done()` | `(x + y)` | No fluent API |
| `map(m, sqrt)` | `sqrt(m)` element-wise or vectorized expr | No JS callback `map` |
| `math.import({ fn })` | `ctx.eval('fn(x) = ...')` | No override of builtins via import |
| `sparse` 1000×1000 | `identity(1000)` dense | Works but memory-heavy |
| `derivative('x^2','x')` | — | Symbolic unsupported; `derivative(series)` is time-series calculus |
| `solveODE(f, [t0,tf], y0)` | `ode_solve("f", y0, [t0,tf], dt)` | Different signature; native in DSL |
| `format(value, 14)` | `Value.toString()` / numeric unwrap | Less formatting control |
| `JSON.stringify(x, replacer)` | host-side serialization | No built-in math-type JSON codec |

---

## MathJS Examples Translation Matrix

Source: `libs/mathjs/examples` (48 files). Test coverage: `tests/ts/parity/mathjs_examples/cases/`.

| Example | Translate? | Parity | Notes |
|---------|------------|--------|-------|
| `basic_usage.js` | ✅ Yes | 🟢 Strong | Eval paths covered; no `chain()` / symbolic `derivative` |
| `expressions.js` | ⚠️ Mostly | 🟡 Partial | Core path largely works; residual slice-chain cases **quarantined** in known_failures (not open todos) |
| `matrices.js` | ✅ Yes | 🟢 Strong | Core LA + generators; no `resize` / JS `map` |
| `chaining.js` | ⚠️ Rewrite | 🟡 Partial | Expression equivalents pass; `chain()` API unsupported |
| `complex_numbers.js` | ✅ Yes | 🟢 Strong | Polar create / natural sort may differ |
| `units.js` | ✅ Yes | 🟢 Strong | Engineering scenarios map well; unit simplification weaker |
| `objects.js` | ✅ Yes | 🟢 Strong | Records parity |
| `algebra.js` | ⚠️ Numeric only | 🔴 Weak | `simplify` / symbolic `derivative` throw by design |
| `fractions.js` | ⚠️ Float fallback | 🔴 Weak | Expressions evaluate as float64, not exact rationals |
| `bignumbers.js` | ⚠️ Float fallback | 🔴 Weak | `0.1+0.2` passes as float, not BigNumber semantics |
| `sparse_matrices.js` | ⚠️ Dense substitute | 🟡 Partial | Large `identity` ops pass; no sparse type |
| `serialization.js` | ❌ No | 🔴 Weak | No replacer/reviver |
| `import.js` | ⚠️ DSL subset | 🟡 Partial | Constants/functions via DSL; no `numeric.js` / `eig` |
| `advanced/expression_trees.js` | ❌ No | 🔴 Weak | No public parse-tree API |
| `advanced/function_transform.js` | ❌ No | 🔴 Weak | No transform hooks |
| `advanced/custom_scope_objects.js` | ⚠️ Partial | 🟡 Partial | Object scope works; custom Map types unsupported |
| `advanced/more_secure_eval.js` | ⚠️ Concept | 🟡 Partial | Sandboxing via allowed builtins, not `create()` subset |
| `advanced/custom_evaluate_using_factories.js` | ❌ No | 🔴 Weak | No factory composition |
| `advanced/custom_evaluate_using_import.js` | ❌ No | 🔴 Weak | No modular import |
| `advanced/custom_datatype.js` | ❌ No | 🔴 Weak | No typed-function extension |
| `advanced/custom_relational_functions.js` | ❌ No | 🔴 Weak | **2 todo** — string comparison policy |
| `advanced/custom_argument_parsing.js` | ❌ No | 🔴 Weak | No argument transforms |
| `advanced/convert_fraction_to_bignumber.js` | ❌ No | 🔴 Weak | **1 skip** — fraction display |
| `advanced/custom_loading.js` | ❌ No | N/A | Bundler-specific |
| `advanced/web_server/*` | ⚠️ Concept | 🟡 Partial | Good Bun/WASM server demo candidate |
| `code_editor/*` | ⚠️ Partial | 🟡 Partial | **2 todo** on `round(x, decimals)` |
| `browser/basic_usage.html` | ✅ Yes | 🟢 Strong | WASM port of `basic_usage.js` |
| `browser/plot.html` | ✅ Yes | 🟢 Strong | Compile-once + `linspace` — MathZig strength |
| `browser/lorenz.html` | ✅ Yes | 🟢 Strong | Covered in `simulations.json` |
| `browser/rocket_trajectory_optimization.html` | ✅ Yes | 🟢 Strong | Rocket sim parity test exists |
| `browser/lorenz_interactive.html` | ✅ Yes | 🟢 Strong | Same ODE core + UI |
| `browser/webworkers/*` | ⚠️ Concept | 🟡 Partial | WASM worker batch eval demo |
| `browser/currency_conversion.html` | ⚠️ Partial | 🟡 Partial | Units yes; Fixer.io fetch is orthogonal |
| `browser/angle_configuration.html` | ✅ Yes | 🟢 Strong | Units / deg |
| `browser/printing_html.html` | ⚠️ Partial | 🟡 Partial | Use `toLaTeX()` |
| `browser/pretty_printing_with_mathjax.html` | ⚠️ Partial | 🟡 Partial | LaTeX → MathJax pipeline |
| `browser/requirejs_loading.html` | ❌ No | N/A | Loader-specific |
| `browser/custom_separators.html` | ❌ No | N/A | Locale config not supported |

**Summary:** ~22 examples translate cleanly · ~14 need syntax/API adaptation · ~12 are out of scope today.

---

## Areas to Improve

### 3.1 Matrix slicing & assignment (🟡 Residual — narrowed 2026-07-15)

**Landed:** VM slice assignment + AOT step parity (`tests/parity/cases/matrix_slice_assign.json`, `matrix_slice_step.json`; task-18 D2). Arbitrary positive steps match VM; negative indices residual risk tracked historically under 0093.

**Residual (not “6 open todos”):** translated MathJS `expressions.js` chains still fail/quarantined in `tests/known_failures.json` (cascade from slice assign / hybrid indexing vs MathJS examples). See STATUS.md quarantine list.

**Impact:** MathJS-style tutorial replay incomplete; engine slice path is no longer the primary open gap.

**Related (archived / historical):**

- `docs/tasks/archive/` — 0079.6, 0093, 0055 as applicable
- task-18 D2 — AOT step parity

**Acceptance (remaining):** Quarantined MathJS expression-chain cases either pass and leave `known_failures.json`, or stay explicitly unsupported with tickets.

---

### 3.2 `round(x, decimals)` (🟡 Residual AOT)

**Landed (VM):** 2-arg `round(x, n)` in `src/vm/vm.zig` (`roundToDecimals`).

**Residual:** catalog skips on `wasm_aot` / standalone for `round_decimals_*` and gauntlet arity-2 (see STATUS.md). Extended MathJS/code_editor paths may still differ.

**Acceptance (remaining):** drop `wasm_aot` skips for decimal round; keep parity green.

---

### 3.3 String / relational comparison policy (🟡 Low)

**Symptom:** 2 `todo` in `advanced__custom_relational_functions.test.ts`.

**Task:** [0095 — String comparison operators](../tasks/0095_string_comparison_operators.md)

**Policy decision needed:** Match MathJS default (numeric strings) vs explicit opt-in.

---

### 3.4 Unit system polish (🟡 Medium)

**Gaps:** Derived-unit simplification (`kPa`), prettier unit strings, edge-case dimensions.

**Tasks:**

- [0032 — Unit system improvements](../tasks/0032_unit_system_improvements.md) (closed for core; follow-ups remain)
- [0069 — Runtime unit creation](../tasks/0069_runtime_unit_creation.md)
- [0057 — Complex unit parsing](../tasks/0057_complex_unit_parsing.md)

---

### 3.5 ODE solver UX (🟡 Medium)

**Gaps:** Named state access, adaptive stepping, perf for repeated calls.

**Tasks:**

- [0060 — ODE solver hardening](../tasks/0060_ode_solver_hardening_optimization.md)
- [0068 — Diff matrix and adaptive ODE](../tasks/0068_diff_matrix_and_adaptive_ode.md)
- [0059 — Adaptive ODE solver](../tasks/0059_adaptive_ode_solver.md)

---

### 3.6 WASM / TS backend edge cases (🟡 Medium)

**Gaps:** Some parity cases skip `ts_wasm_vm` / `wasm_aot` (complex, matrices, units, simulations).

**Tasks:**

- [0096 — Builtin function gauntlet parity](../tasks/0096_builtin_function_gauntlet_parity.md)
- [04 — WASM AOT parity plan](./04_wasm_aot_parity.md)
- [0079.13 — WASM complex/units parity](../tasks/0079_13_wasm_complex_units_parity.md)

---

### 3.7 Developer experience — examples & docs (🟡 Medium)

MathZig exceeds MathJS on performance but lacks a first-party `examples/` tree mirroring MathJS pedagogy.

**Recommended ports (priority order):**

1. `examples/basic_usage.ts` — arithmetic, trig, complex, det
2. `examples/units_engineering.mzig` — from `units.js`
3. `examples/plot_function.html` — compile + `linspace` + Plotly
4. `examples/lorenz.html` — ODE + 3D plot
5. `examples/rocket_trajectory.html` — extend existing rocket test
6. `examples/web_worker_batch.html` — WASM worker showcase
7. `examples/bun_eval_server.ts` — from `advanced/web_server`

---

### 3.8 Intentionally deferred (document, do not chase MathJS parity)

| Feature | Rationale |
|---------|-----------|
| Symbolic `simplify` / `derivative` | Different product axis; MathJS CAS is mature |
| BigNumber / Fraction | float64 + performance mission |
| Sparse matrix type | Dense + perf path sufficient for current users |
| `eig` / `solve` | Requires dedicated numeric module |
| `math.import` extensibility | DSL + Zig builtins preferred |
| Expression tree public API | Export only if symbolic tooling is planned |

---

## MathZig Advantages (Lean Into These)

| Advantage | MathJS limitation | Demo opportunity |
|-----------|-------------------|------------------|
| Bytecode compile-once | Re-parse per call | `plot.html` style batch eval |
| SIMD / parallel GEMM | Single-threaded JS | Matrix benchmark examples |
| Native ODE in DSL | Requires `import` / custom solver | Lorenz + rocket HTML demos |
| Time-series DSL | Basic series support | Financial / telemetry pipelines |
| WASM deployment | Heavy browser bundle | Web worker examples |
| Zero-GC hot paths | GC pauses on bulk eval | 1M-point linspace eval |

---

## Verification Checklist

Run after any parity-impacting change (per `AGENTS.md`):

```bash
zig build vm-baseline --summary all
zig build test --summary all
bun test
bun tests/parity/cli.ts --quick    # iteration
bun test tests/ts/parity/mathjs_examples
bun tests/parity/cli.ts --full     # before declaring done
```

**Key artifacts:**

| Artifact | Path |
|----------|------|
| Expression parity cases | `tests/parity/cases/*.json` |
| MathJS example tests | `tests/ts/parity/mathjs_examples/cases/*.test.ts` |
| Core defects (closed) | `tests/artifacts/mathjs_examples/defects_core.json` |
| Extended triage (closed) | `tests/artifacts/mathjs_examples/defects_extended.json` |
| Rocket simulation | `tests/ts/simulations/rocket_simulation/` |

---

## Roadmap Phases

### Phase A — Close active todos (1–2 weeks) 🟡

- [ ] Matrix slice assignment + `m[:, col]` ([§3.1](#31-matrix-slicing--assignment--high--active-todos))
- [ ] `round(x, n)` ([§3.2](#32-roundx-decimals--medium))
- [ ] Expand `matrix_slicing.json` parity cases

### Phase B — Examples & DX (2–3 weeks) 🟡

- [ ] Create `examples/` tier-1 set ([§3.7](#37-developer-experience--examples--docs--medium))
- [ ] Document MathJS → MathZig syntax table in README

### Phase C — WASM backend parity (ongoing) 🟡

- [ ] Reduce `skip: ["ts_wasm_vm"]` count in parity JSON
- [ ] Browser validation per [04_wasm_aot_parity.md](./04_wasm_aot_parity.md)

### Phase D — Strategic extensions (future) 💡

Only if product direction changes:

- Symbolic algebra subset
- Sparse matrices
- `solve` / `eig` via bundled numeric kernel
- Public expression-tree API

---

## Syntax Quick Reference (for porting MathJS examples)

| MathJS | MathZig |
|--------|---------|
| `math.evaluate('...')` | `ctx.eval('...')` |
| `math.compile('...').evaluate()` | `ctx.compile('...').evaluate()` |
| `const p = math.parser()` | `const ctx = MathZig.create()` |
| `p.evaluate('x = 3')` then `p.evaluate('x+1')` | sequential `ctx.eval(...)` in same context |
| `f(x) = x^a` | same DSL syntax |
| `m[1, 1]` (1-based) | `m[0, 0]` (0-based) |
| `unit(45, 'cm')` | `45 * cm` |
| `b.to('inch')` | `conv(b, inch)` or `b to inch` |
| `number(u, 'mm')` | `number(u, mm)` |
| `chain(3).add(4).done()` | `(3 + 4)` |
| `map(a, sqrt)` | `sqrt(a)` or element-wise builtins |
| `derivative('x^2', 'x')` | not available (symbolic) |
| `simplify('2x+3x')` | not available (symbolic) |
| `math.import({...})` | `ctx.eval('name = ...')` / DSL functions |

---

## Progress Log

| Date | Change |
|------|--------|
| 2026-02-23 | Task 0084 core closed: 55/55 MathJS example evaluate expressions pass |
| 2026-02-23 | Task 0084.2 extended triaged: 0 engine defects, 30 harness/integration skips |
| 2026-07-07 | Plan 00 created: consolidated examples analysis, live harness 87/98 pass |