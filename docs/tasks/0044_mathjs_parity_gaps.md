# Task 0044: MathJS Parity Gaps

## Status
- **Progress:** 100%
- **Parent Task:** [0043: MathJS Comparison](0043_mathjs_comparison.md)

## Description
Address the feature gaps and bugs identified during the comprehensive MathJS comparison test suite (`tests/ts/comparison/mathjs_comprehensive.test.ts`).

## Identified Gaps

### 1. Missing or Broken Functions
- [x] **gcd / lcm:** `BuiltinFn` exists but returns `undefined`. Implement or expose correctly.
- [x] **factorial:** Returns `undefined`. Implement.
- [x] **Complex exp:** `exp(complex)` throws type error. Implement complex dispatch for `exp`.

### 2. Statistical Functions
- [x] **std / variance:** MathZig result differs from MathJS. Likely `N` vs `N-1` normalization. MathJS uses `unbiased` (N-1) by default. Verify MathZig's implementation and align or document.
- [x] **min / max:** Behavior on lists/matrices (`min([1, 2, 3])`) differs. MathZig returns a Matrix (likely column-wise or identity), MathJS reduces to scalar. Ensure `min/max` on 1D arrays reduces to scalar.
- [x] **prod:** Returns Matrix instead of scalar for 1D array input.

### 3. Matrix Reductions
- [x] Ensure `sum`, `mean`, `prod`, `min`, `max`, `variance`, `std` correctly reduce 1D vectors to scalars.

## Plan
1.  **Investigate `src/functions/`:** Check implementations of `gcd`, `lcm`, `factorial`.
2.  **Fix Reductions:** Update `matrix_kernels.zig` or `statistics.zig` to handle 1D vector reductions to scalar.
3.  **Implement Complex Exp:** Add `Complex.exp` support in `vm.zig` dispatch.
4.  **Verify:** Run `bun test tests/ts/comparison/mathjs_comprehensive.test.ts` and remove `todo: true` flags.

## Goal
Achieve 100% pass rate on `mathjs_comprehensive.test.ts` without `todo` skips.
