# Task 0000: Zero-Regression & Master Feature Verification

- **Status:** In Progress (verified partial 2026-07-15)
- **Priority:** Critical (P0)
- **Category:** Infrastructure / QA / Stability

## Overview
Establish a "Zero-Regression Architecture" using the **Immutable Baseline Protocol (IBP)**. This task ensures that every single feature implemented in MathZig—from the simplest scalar addition to complex orbital simulations—remains bit-identical across all updates. We treat the current stable state as a "Gold Master" and enforce quad-backend parity (Zig, FFI, WASM VM, WASM AOT).

---

## 1. The Immutable Baseline Protocol (IBP)
1. **Zero Tolerance:** No commit is allowed if it breaks existing parity or simulation outcomes.
2. **Quad-Backend Parity:** All results MUST match across Zig VM, TS FFI, WASM VM, and WASM AOT.
3. **Bit-Identity:** Floating point results must match to `1e-15` for scalars and `1e-12` for matrices.
4. **Visual Parity:** Every expression must produce the exact same `toLaTeX` string.
5. **Memory Invariance:** Library memory usage must remain stable (no leaks) after 1000 iterations of the E2E suite.

---

## 2. Master Feature Inventory (Mandatory Verification List)

Every item below MUST have at least one dedicated parity test case in `tests/parity/cases/`.

### 2.1 Core Types & Literals
| Feature | Syntax Example | Notes |
| :--- | :--- | :--- |
| **Numeric (Standard)** | `42`, `3.14`, `0.5` | |
| **Numeric (Sci-Note)** | `6.674e-11`, `1.5E10` | Critical for physics |
| **Numeric (Hex/Bin)** | `0xFF`, `0b1010` | |
| **Complex** | `1 + 2i`, `i`, `-i` | |
| **Unit** | `10m`, `5.5kg`, `[kg/kWh]` | Implicit and Explicit |
| **Duration** | `500ms`, `30s`, `1h`, `7d` | Used in TS & ODE |
| **Timestamp** | `"2024-01-15"`, `now()` | ISO strings & Epochs |
| **Matrix** | `[1,2; 3,4]`, `[1, 2, 3]` | Row-major storage |
| **Series** | `series([1,2], [t1, t2])` | SoA Time-series |
| **Record** | `{a: 1, b: "test"}` | Named tuples |
| **Array** | `[1, "two", 3.0]` | Heterogeneous dynamic |
| **Boolean** | `true`, `false` | |
| **String** | `"hello"`, `'world'` | |
| **Slice** | `1:10`, `0:100:2`, `:` | |
| **Null/Undef** | `null`, `undefined` | |

### 2.2 Operator Permutations
| Group | Operators | Permutations to Verify |
| :--- | :--- | :--- |
| **Arithmetic** | `+`, `-`, `*`, `/`, `%`, `^` | `Scalar op Scalar`, `Matrix op Scalar`, `Scalar op Matrix`, `Matrix op Matrix`, `Series op Scalar`, `Unit op Scalar`, `Unit op Unit` |
| **Element-wise** | `.*`, `./`, `.^` | `Matrix op Matrix`, `Matrix op Scalar` |
| **Comparison** | `==`, `!=`, `<`, `<=`, `>`, `>=` | `Numeric`, `Boolean`, `Complex (== only)`, `String` |
| **Logical** | `and`, `or`, `not`, `&&`, `||`, `!` | `Lazy evaluation check` |
| **Bitwise** | `&`, `|`, `^^`, `~`, `<<`, `>>`, `>>>` | `F64 to U64 conversion` |
| **Assignment** | `x = 10`, `{a, b} = {a:1, b:2}` | `Single`, `Destructuring`, `Unit Shadowing` |
| **Matrix Spec** | `m'` (transpose) | `Vector'`, `Matrix'`, `Complex Matrix'` |
| **Indexing** | `m[row, col]`, `s[1:5]`, `r.f`, `r["f"]` | `Constant idx`, `Expression idx`, `Slice idx`, `Open-ended slice` |

### 2.3 Chained & Nested Logic (High-Risk)
- [ ] **Indexing on Result:** `size(m).rows`, `ode_solve(...)[end, 0]`
- [ ] **Nested Records:** `{ a: { b: { c: 1 } } }`
- [ ] **Complex in Matrix:** `[1+i, 2-i; i, -i]`
- [ ] **Units in Matrix:** `[1m, 2m; 3m, 4m]`
- [ ] **Records in Series:** (Metadata tracking per timestamp)
- [ ] **Function Returning Matrix:** `f(x) = [x, 0; 0, x]`
- [ ] **Closure Persistence:** Functions accessing outer scope variables after assignment.

### 2.4 Mathematical Functions (Built-in)
- [ ] **Basic:** `abs`, `sqrt`, `cbrt`, `exp`, `log`, `log10`, `log2`, `pow`, `mod`, `sign`, `trunc`
- [ ] **Trig:** `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `hypot`, `norm`
- [ ] **Hyperbolic:** `sinh`, `cosh`, `tanh`, `asinh`, `acosh`, `atanh`
- [ ] **Reciprocals:** `sec`, `csc`, `cot`, `asec`, `acsc`, `acot`, `sech`, `csch`, `coth`, `asech`, `acsch`, `acoth`
- [ ] **Rounding:** `floor`, `ceil`, `round`, `clamp`
- [ ] **Special:** `factorial`, `gamma`, `lgamma`, `erf`
- [ ] **Stats:** `mean`, `sum`, `count`, `median`, `std`, `variance`, `mad`, `prod`
- [ ] **Linear Algebra:** `det`, `inv`, `transpose`, `gemv`, `size`, `trace`, `dot`, `cross`
- [ ] **Creation:** `identity`, `zeros`, `ones`, `diag`, `reshape`, `flatten`, `concat`

### 2.5 Time-Series & Temporal DSL
- [ ] **Core Ops:** `series`, `len`, `duration`, `start_time`, `end_time`, `now`, `last`
- [ ] **Selection:** `head`, `tail`, `slice`, `between`, `since`, `shift`
- [ ] **Calculus:** `derivative`, `integrate`, `diff`, `pct_change`, `cumsum`, `cummax`, `cummin`
- [ ] **Rolling Windows:** `rolling_sum`, `rolling_mean`, `rolling_min`, `rolling_max`, `rolling_stddev`, `rolling_count`
- [ ] **Time-based Rolling:** `rolling_mean(s, 1h)` (Duration-based windowing)
- [ ] **Indicators:** `sma`, `ema`, `rsi`, `macd`, `bollinger`
- [ ] **Resampling:** `resample(s, interval, agg)`, `ohlc(s, interval)`
- [ ] **Alignment:** `align(a, b, mode)`, `asof_join(left, right, tolerance)`
- [ ] **Cleaning:** `dropna`, `fillna` (constant/forward/backward/linear), `clip`

### 2.6 Solvers & Meta-API
- [ ] **Generators:** `range`, `linspace`, `logspace`
- [ ] **ODE Solvers:** `ode_solve`, `ode_solve_euler`
- [ ] **Simulations:** Multi-stage ODE chains (State handover from result1 to result2).
- [ ] **Units API:** `conv`, `create_unit`
- [ ] **System:** `toLaTeX`, `typeof`, `config`, `get_functions`, `get_error`, `write_csv`

---

## 3. Implementation Plan

### Phase 1: The "Golden" Catalog Expansion
- [🟡] **Task 0.1:** Map all `src/api_definition.zig` methods to parity entries. (Initial `api_surface.json` created)
- [ ] **Task 0.2:** Create `regressions_shadowing.json` covering unit/variable overlaps (`m`, `s`, `t`, `kg`, etc.).
- [ ] **Task 0.3:** Create `matrix_units.json` testing nested units: `[1m, 2m] * 2`.
- [ ] **Task 0.4:** Implement `metadata_api.json` to verify `toLaTeX` output for every core expression.
- [ ] **Task 0.5:** Create `timeseries_master.json` with 10k+ point snapshots to verify SIMD stability.

### Phase 2: Simulation Stability (Headless)
- [ ] **Task 0.6:** Update `tests/parity/cli.ts` to support `sequence: string[]` for multi-statement simulation tests.
- [🟡] **Task 0.7:** Extract Rocket Simulation math from `web/rocket_sim.js` into `tests/parity/cases/simulations.json`. (Stage 1 ported)
- [ ] **Task 0.8:** Extract Lorenz Attractor math into the simulation suite.

### Phase 3: The Gatekeeper Integration
- [ ] **Task 0.9:** Enforce `tools/testing/feature_gate.ts` as the mandatory pre-merge quality gate.
- [ ] **Task 0.10:** Establish the `tests/artifacts/parity/master/` directory as the "Source of Truth" for comparisons.

---

## 4. The Testing Bible (How to Test)

### 4.1 Internal Integrity (The "Quick" Check)
Always run these first to ensure the basic compilation and FFI bridge are not crashing.
```bash
# 1. Zig VM baseline first
zig build vm-baseline --summary all

# 2. Full Zig tests
zig build test --summary all

# 3. TS Binding & Logic Tests
bun test
```

### 4.2 The Full Parity Gauntlet
Run the entire library through the 4 backends. This is the ultimate verification.
```bash
# Run ALL test cases across ALL backends
bun tests/parity/cli.ts --full --task-id=current_audit
```
*   **Backends:** Native Zig, Bun FFI, WASM (Interpreter), WASM (AOT).
*   **Output:** Generates `tests/artifacts/parity/current_audit_report.md`.

### 4.3 Regression Comparison
Use this to prove that your changes haven't changed existing behavior.
```bash
# Compare your current run against the established master baseline
tools/testing/compare_parity.ts master current_audit
```

### 4.5 Unified Gate (Recommended)
```bash
tools/testing/feature_gate.ts current_audit master 5
```

### 4.4 Cross-Library Parity (MathJS)
For physics and simulations, we verify against MathJS to ensure our numerical logic is correct.
```bash
# Run rocket simulation comparison test
bun test tests/ts/simulations/rocket_simulation/full-simulation.test.ts
```

---

## Progress Log
- 2026-01-24: Audit complete. Identified "Chained Logic" (e.g., `size(m).rows`) as a major untested area.
- 2026-01-24: Confirmed `call_user` fix and build stability.
- 2026-01-24: Added Sci-note and multi-stage ODE requirements to inventory.

---

## Verification (2026-07-15)

- **True status:** `PARTIAL`
- **Evidence:** gauntlet=True; builtins cases=['builtins_comb_complex', 'builtins_linalg', 'builtins_math', 'builtins_nt', 'builtins_stats', 'builtins_trig', 'builtins_ts']
- **Notes:** Evergreen IBP; catalog expanded, not closed.
- **Audit:** [true_status_audit.md](true_status_audit.md)

