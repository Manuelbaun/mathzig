# Task 0096: Built-in Function Gauntlet & Multi-Backend Parity

- **Status:** In Progress (verified partial 2026-07-15 — zeros/ones fixed; IBP open)
- **Priority:** Critical (P0)
- **Category:** Infrastructure / QA / Stability

## Overview
Establish the "Immutable Baseline Protocol" (IBP) for all 100+ built-in functions. This ensures bit-identical results across Zig VM, TS FFI, WASM VM, and WASM AOT. This task is a deep-dive into Task 0000 section 2.4.

## Current Progress
- [x] Expanded Golden Catalog: Basic Math, Trig, Stats, Linalg, Time-Series.
- [x] Fixed JSON ID collisions in test cases.
- [🟡] **Reproduction:** Confirmed `zeros(rows, cols)` and `ones(rows, cols)` argument swap in Zig VM.
- [ ] **Parity Status:** 
  - `zig_vm` & `ts_ffi`: High parity, blocked by minor bugs.
  - `ts_wasm_vm`: Missing structured type tags (Complex/Matrix).
  - `wasm_aot`: Precision issues and opcode coverage gaps.

## Atomic Goals
1. [ ] Fix argument order for `zeros` and `ones` in `src/vm/vm.zig`.
2. [ ] Verify fix with `tmp_test_zeros.ts` and `builtins_linalg.json`.
3. [ ] Resolve `complex_conj_01` and matrix tag issues in `ts_wasm_vm`.
4. [ ] Investigate and resolve `wasm_aot` precision gaps in `exp`, `log`, `cos`.
5. [ ] Establish the finalized "Immutable Baseline" for all 100+ functions.

## Verification
```bash
# Full parity check
bun tests/parity/cli.ts --task-id=builtin_gauntlet

# Targeted linear algebra check
bun tests/parity/cli.ts --case builtins_linalg.json
```

---

## Verification (2026-07-15)

- **True status:** `PARTIAL`
- **Evidence:** zeros/ones LIFO order is correct (pop cols then rows); gauntlet cases exist; last package: zig_vm 534/0, ts_ffi 534/0, ts_wasm_vm 469 pass+65 skip, wasm_aot 533 pass+1 skip
- **Notes:** Atomic zeros/ones fix appears DONE in code. Full IBP / multi-backend baseline still open due to ts_wasm_vm skips and remaining parity gaps.
- **Audit:** [true_status_audit.md](true_status_audit.md)

