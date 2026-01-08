# WASM Compare (MathZig vs Zig/LLVM)

This tool compares MathZig's WASM AOT output against Zig's WASM output for a fixed set of expressions. It reports size and instruction-count ratios, and flags cases that exceed the configured tolerance.

## Run
```
bun tools/wasm/wasm_compare/compare.ts
```
or
```
bun ./tools/wasm/wasm_compare/compare.ts
```

## Options
```
bun tools/wasm/wasm_compare/compare.ts --size-tol 0.10 --instr-tol 0.10 --out-dir /tmp/wasm_compare
```
or
```
bun ./tools/wasm/wasm_compare/compare.ts --size-tol 0.10 --instr-tol 0.10 --out-dir /tmp/wasm_compare
```

## Cases
Edit `tools/wasm/wasm_compare/cases.json` to add or tweak cases. Each case includes:
- `dsl`: MathZig DSL expression
- `params`: parameter names (controls `-p` for MathZig and the Zig signature)
- `zig_expr`: Zig expression returned from `eval`
- `zig_helpers`: optional top-level helper functions

## Outputs
- `/tmp/wasm_compare/mathzig_<case>.wasm`
- `/tmp/wasm_compare/zig_<case>.wasm`
- `/tmp/wasm_compare/report.json`

## Notes
- Requires `wasm-objdump` for instruction counting and opcode histogram diffs. If unavailable, size comparisons still run.
- Uses `zig build -Doptimize=ReleaseSmall` for MathZig, and `zig build-exe -O ReleaseSmall` for Zig baselines.

## Opcode Histogram Diff
Use `--top-ops N` (default 8) to print the top opcode deltas per case.
