# Task 0045: Comprehensive MathJS Parity

## Status
- **Progress:** 100%
- **Parent Task:** [0043: MathJS Comparison](../task_done/0043_mathjs_comparison.md)

## Description
Expand MathZig's function library to achieve closer parity with MathJS, focusing on missing arithmetic, trigonometric, statistical, and probability functions identified in the comparison reports.

## Identified Gaps to Implement

### 1. Missing Arithmetic & Rounding
- [x] **square(x):** Alias for `x^2` or specialized.
- [x] **cube(x):** Alias for `x^3` or specialized.
- [x] **nthRoot(a, n):** n-th root.
- [x] **fix(x):** Round towards zero (alias for `trunc`).
- [x] **log1p(x):** `ln(1 + x)`.
- [x] **expm1(x):** `exp(x) - 1`.

### 2. Missing Trigonometry
- [x] **Inverse Hyperbolic:** `asinh`, `acosh`, `atanh`.
- [x] **Reciprocal:** `csc`, `sec`, `cot`.
- [x] **Inverse Reciprocal:** `acsc`, `asec`, `acot`.
- [x] **Hyperbolic Reciprocal:** `csch`, `sech`, `coth`.
- [x] **Inverse Hyperbolic Reciprocal:** `acsch`, `asech`, `acoth`.

### 3. Statistics & Probability
- [x] **mad(list):** Median Absolute Deviation.
- [x] **combinations(n, k):** nCr.
- [x] **permutations(n, k):** nPr.
- [x] **gamma(x):** Already in `BuiltinFn` but maybe needs verification/exposure.
- [x] **lgamma(x):** Log-gamma.
- [x] **erf(x):** Error function.

### 4. Utility & Aliases
- [x] **ln(x):** Alias for `log(x)`.
- [x] **log(x, base):** Support optional second argument for `log`.

## Plan
1.  **Update `src/vm/bytecode.zig`:** Add new `BuiltinFn` enum members.
2.  **Update `src/parser/compiler.zig`:** Map new functions to `BuiltinFn` and handle aliases.
3.  **Update `src/vm/vm.zig`:** Implement the logic for new built-ins in `callBuiltin`.
4.  **Implement Kernels:** Add necessary math functions to `src/functions/` if not provided by `std.math`.
5.  **Expand Tests:** Add tests for all new functions in `tests/ts/comparison/mathjs_comprehensive.test.ts`.

## Goal
Achieve significantly higher coverage in the `mathjs_vs_mathzig_comparison.md` report and pass more tests in the comprehensive suite.
