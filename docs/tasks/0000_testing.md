# Task 0000: Full-Surface End-to-End Testing & Stability

- **Status:** In Progress (verified partial 2026-07-15)
- **Priority:** Critical (P0)
- **Category:** Infrastructure / QA / Stability

## Overview
This is the master task for the **MathZig Full-Surface E2E Suite**. The goal is to move the library from an unstable state to a "Zero-Regression" state by implementing a mandatory, constant testing protocol that covers 100% of implemented features across all backends (Zig VM, TS FFI, WASM VM, WASM AOT).

## The "Gatekeeper" Workflow
No feature implementation or bugfix is considered "Done" until `tools/gatekeeper.sh` passes with **100% parity**.
1. **Zig Internal:** `zig build test`
2. **TS Binding Logic:** `bun test`
3. **The Parity Gauntlet:** `bun tests/parity/cli.ts --full` (All 4 backends vs All cases)
4. **Visual/Structural:** `toLaTeX` parity verification for all expressions.
5. **Baseline Audit:** Bit-identical comparison against the "Gold Master" artifacts.

---

## End-to-End Test Matrix (Coverage Inventory)

| Feature Area | Sub-Features | Parity Case File | Status |
| :--- | :--- | :--- | :--- |
| **Scalar Math** | Arithmetic, Powers, Complex, Logic | `core_arithmetic.json` | 🟢 Verified |
| **Linear Algebra** | Gemm, Gemv, Inverse, Det, Slicing | `matrix_ops.json` | 🟡 Unstable |
| **Unit System** | Base units, Prefixes, Decompositions | `units.json` | 🟡 Regression (Shadowing) |
| **Combined Types** | Units in Matrices, Complex in Records | `matrix_units.json` | 🔴 MISSING |
| **Temporal Math** | Date/Time Arithmetic, Epochs | `temporal.json` | 🟡 Incomplete |
| **Time Series** | Rolling, EMA, Joins, Resampling | `timeseries_master.json` | 🔴 MISSING |
| **Solvers** | ODE (Euler/Adaptive), Root finding | `simulations.json` | 🔴 Broken (Rocket) |
| **Metadata** | `toLaTeX`, Type Tags, Field names | `metadata_api.json` | 🔴 MISSING |
| **FFI / WASM** | Memory safety, Pointers, Binary Parity | `ffi_boundary.json` | 🟢 Partial |

---

## Implementation Plan

### Phase 1: The "Golden" Catalog Expansion
- [ ] **Task 0.1:** Map all symbols in `src/api_definition.zig` to parity entries.
- [ ] **Task 0.2:** Create `matrix_units.json` to catch regressions in unit-matrix math (e.g., `[1m, 2m] * 2`).
- [ ] **Task 0.3:** Create `timeseries_master.json` with 10k+ point snapshots to verify SIMD stability.
- [ ] **Task 0.4:** Implement `metadata_api.json` to verify `toLaTeX` output for every core expression.

### Phase 2: Simulation Stability (Headless)
- [ ] **Task 0.5:** Integrate Rocket and Lorenz simulations into the parity suite (Step-by-step verification).
- [ ] **Task 0.6:** Ensure deterministic RNG seeding for all stochastic tests (e.g., `probability.json`).

### Phase 3: Automation & Guarding
- [ ] **Task 0.7:** Finalize `tools/gatekeeper.sh` as a single-command "Pre-Flight" check.
- [ ] **Task 0.8:** Update `tests/parity/compare.ts` to enforce strict bit-parity for matrices and series.

---

## Verification Procedures

### Constant Testing Protocol
For every task implementation, the following steps must be taken:
1. Add a representative case to `tests/parity/cases/`.
2. Run `tools/gatekeeper.sh`.
3. If any `DIFF` appears in the report, the implementation is reverted or fixed until parity is restored.

### Bit-Identity Policy
- **Floating Point:** `1e-15` tolerance for scalars; `1e-12` for complex matrix reductions.
- **Memory:** Verify that `getMemoryUsed()` remains stable after 1000 iterations of the E2E suite (Leak Detection).

---

## Progress Log
- 2026-01-24: Task 0000 created to address library instability.
- 2026-01-24: Shadowing regression identified (`m` unit vs `m` variable).
- 2026-01-24: Initiated "Full Surface" audit plan.

---

## Verification (2026-07-15)

- **True status:** `PARTIAL`
- **Evidence:** requested catalogs present=['matrix_units', 'metadata_api', 'probability', 'simulations', 'timeseries_master']; total_cases=53; gatekeeper.sh=False; mz=True
- **Notes:** Catalogs partially exist; gatekeeper replaced by bun run mz; IBP checklist incomplete.
- **Audit:** [true_status_audit.md](true_status_audit.md)

