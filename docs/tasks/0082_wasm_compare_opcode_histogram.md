# Task 0082: WASM Compare Opcode Histogram Diff

**Category:** WASM AOT Optimization

## Goal
Add an opcode histogram diff to the WASM comparison report to highlight where MathZig's codegen diverges from Zig/LLVM.

## Rationale
Size and instruction count ratios are coarse. A histogram diff reveals which opcodes (e.g., `local.get`, `f64.const`, `f64.mul`) are over- or under-emitted and where to focus optimizations.

## Status
- ✅ Done

## Requirements
1. Extend `tools/wasm/wasm_compare/compare.ts` to output opcode histograms for `eval` from both backends (already collected when `wasm-objdump` is present).
2. Add a diff section to the JSON report: per-opcode delta and ratio.
3. Print a short console summary of the top N opcode deltas (configurable, default 8).
4. Document this in `tools/wasm/wasm_compare/README.md`.

## Acceptance Criteria
- Report includes a histogram diff for each case when `wasm-objdump` is available.
- Console output lists top opcode deltas for quick scanning.
