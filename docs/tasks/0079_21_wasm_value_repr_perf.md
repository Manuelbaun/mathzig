# Subtask 0079.21: WASM Value Representation Performance

- **Status:** In Progress (verified partial 2026-07-15)
- **Priority:** Medium
- **Category:** WASM Runtime Performance

## Overview
Reduce overhead from using `f64` as the universal value representation for pointers and tags in WASM.

## Scope
- **Paths:** `src/wasm/compiler.zig`
- **Symbols:** pointer conversions (`f64_convert_i32_u`, `i32_trunc_f64_u`), matrix/record/complex pointer paths
- **Invariants:** Preserve ABI and correctness of pointer values

## Findings
- Pointer values are represented as `f64` on the stack and repeatedly converted to/from `i32`.
- Hot paths (`mat_create`, `get_index`, `emul`, etc.) do frequent `i32_trunc_f64_u` conversions.
- Using `f64` for pointers increases instruction count and can hinder optimization.
- Index values also go through `i32_trunc_f64_u`, adding extra conversions in loops (e.g., element-wise ops and indexing).
- Record storage is `u32 key + f64 value`, so non-number values (record of records, matrices, etc.) are effectively unsupported in WASM even though VM allows them.

## Implementation Plan
1. [x] Reduce pointer arithmetic churn in pointer-heavy record access paths (`rec_get`, `rec_get_dyn`).
2. [ ] Introduce a parallel i32 stack for pointer-typed values (or tagged locals) in WASM codegen.
3. [ ] Add debug assertions for value-type mismatches during codegen.

## Verification Plan
### Automated Tests
- [x] `zig build vm-baseline --summary all && zig build test --summary all`
- [x] WASM parity tests for matrix/record operations
- [x] WASM perf benchmark before/after

## Progress Log
- 2026-01-23: Subtask created from perf audit.
- 2026-01-23: Audited pointer/number representation churn and record storage limits.
- 2026-02-25: Optimized `rec_get` / `rec_get_dyn` codegen in `src/wasm/compiler.zig` by computing entry pointer once per loop iteration and reusing it for key/value loads (reduced repeated `base + index * stride` arithmetic).
- 2026-02-25: Verification: `zig build vm-baseline --summary all && zig build test --summary all`, `bun test tests/ts/parity/wasm_memory.test.ts`.
- 2026-02-25: Recorded before/after benchmark artifacts:
  - `tests/artifacts/performance/0079_21_value_repr_before_runs5.txt`
  - `tests/artifacts/performance/0079_21_value_repr_after_runs5.txt`
  - `tests/artifacts/performance/0079_21_value_repr_before_after.md`

---

## Verification (2026-07-15)

- **True status:** `PARTIAL`
- **Evidence:** Task file shows investigation checkboxes checked; no clear finish claim
- **Notes:** Investigation partial; not a closed optimization.
- **Audit:** [true_status_audit.md](true_status_audit.md)

