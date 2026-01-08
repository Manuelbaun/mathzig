# Task 0090: Matrix × Vector Multiplication Dimension Handling

- **ID:** 0090
- **Status:** In Progress (verified partial 2026-07-15)
- **Priority:** Medium
- **Effort:** Medium

## Overview
Matrix multiplication fails for vector operands:
- `[1,2,3] * [4,5,6]` → "Matrix dimension mismatch" (should return scalar dot product = 32)
- `[1,2;3,4] * [5,6]` → "Matrix dimension mismatch" (should treat row vector as column vector)

## Affected Tests
- `arithmetic/multiply > Array/Matrix > should multiply vectors (dot product)`
- `arithmetic/multiply > Array/Matrix > should multiply matrix x vector`
- `matrix > matrix multiplication > should multiply matrix x vector (column)`

## Root Cause
The GEMM kernel (`mathzig_gemm`) requires matching inner dimensions. Row vectors stored as `[1×n]` don't match an `[n×m]` matrix's expected column count.

## Implementation Plan

1. [ ] **Dot product:** In the `*` operator dispatch in `src/vm/vm.zig`, detect when both matrices are `[1×n]` (same shape). Compute `∑ aᵢbᵢ` and return a scalar.
2. [ ] **Matrix × row vector:** When RHS is `[1×n]`, automatically transpose to `[n×1]` before GEMM.
3. [ ] **Matrix × column vector:** Ensure a `[n×1]` matrix is recognized as a column vector and the operation `[m×n] * [n×1]` returns `[m×1]`.
4. [ ] **Tests:** Verify `[1,2;3,4] * [5;6]` also works (column vector using semicolons).

## Invariants
- `dot([a,b,c], [d,e,f])` = scalar
- `matmul([m×n], [n×1])` = `[m×1]`
- `matmul([m×n], [1×n]ᵀ)` = `[m×1]` (auto-transpose row vector)

## Verification
```bash
bun test tests/ts/parity/mathjs_unit/arithmetic_multiply.test.ts
bun test tests/ts/parity/mathjs_unit/matrix.test.ts
```

## Paths
- `src/vm/vm.zig` (binary multiply dispatch)
- `src/vm/matrix_kernels.zig` (`mathzig_gemv` for matrix×vector)

---

## Verification (2026-07-15)

- **True status:** `PARTIAL`
- **Evidence:** Value.mul vector-dim logic=False; gemv present=True
- **Notes:** Kernel GEMV exists; MathJS dimension edge-cases may still fail.
- **Audit:** [true_status_audit.md](true_status_audit.md)

