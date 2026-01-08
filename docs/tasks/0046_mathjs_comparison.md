# Task 0043: MathJS Comparison & Parity

## Status
- **Progress:** 100%
- **Parent Task:** None

## Description
Directly compare MathZig's implementation with `mathjs` (located in `libs/mathjs` or via npm) using FFI. The goal is to verify correctness, feature parity, and measure performance differences.

## Goals
1.  **Correctness:** Ensure MathZig returns results identical (within epsilon) to MathJS for supported operations.
2.  **Performance:** Benchmark MathZig (FFI) vs MathJS (JS) for key operations.
3.  **Feature Gap:** Identify features present in MathZig that match MathJS.

## Implementation Results
- [x] Install `mathjs` via `bun install mathjs`.
- [x] Create benchmark/comparison tests under `tests/ts/parity/` (MathJS parity suite).
- [x] Compare **Matrix Operations**:
    - [x] Addition, Subtraction, Multiplication.
    - [x] Inversion, Determinant.
    - [x] Element-wise operations.
- [x] Compare **Scalar Math**:
    - [x] Basic arithmetic.
    - [x] Trigonometry, Log/Exp.
    - [x] Complex numbers.
- [x] Compare **Units**:
    - [x] Unit conversion (`conv`).
- [x] Output comparison analysis in `docs/comparisons/mathjs_vs_mathzig_comparison.md`.

## Summary
MathZig passed all correctness tests against MathJS. Performance speedups ranging from **3x to 12x** were observed for matrix operations. FFI overhead was noted for very simple scalar expressions.

## Deliverables
- `tests/ts/parity/comparison_mathjs_parity.test.ts`
- `tests/ts/parity/comparison_mathjs_comprehensive.test.ts`
- `docs/comparisons/mathjs_vs_mathzig_comparison.md`
