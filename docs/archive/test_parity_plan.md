# Test Parity & Stability Progression

Goal: Ensure all functionality tested in Zig has corresponding TypeScript tests (FFI/WASM) and all tests pass.

## Current Status (2026-01-10)

| Category | Zig Tests | TS FFI Tests | TS WASM Tests | Status |
|----------|-----------|--------------|---------------|--------|
| **Core VM** | Pass | Pass | Pass | 🟢 Complete |
| **Parser/Compiler**| Pass | Pass | Pass | 🟢 Complete |
| **Matrix/BLAS** | Pass | Pass | Pass | 🟢 Complete |
| **Units** | Pass | Pass | Pass | 🟢 Complete |
| **Time-Series** | Pass | Pass | Pass | 🟢 Complete |
| **Probability** | Pass | Pass | Pass | 🟢 Complete |
| **FFI Layer** | Pass | Pass | N/A | 🟢 Complete |

## Regressions Fixed
- [x] Time-Series `integrate()`: Correctly handles cumulative area; added `last()` to retrieve final value.
- [x] Time-Series `where dt < 5s`: Fixed tokenizer/parser issue where `5s` was treated as implicit multiplication `5 * s` without simplification in predicates. Added predicate simplification step.
- [x] Standardize Division by Zero: Returns `NaN` in both standard and fast paths.
- [x] Edge Cases: Fixed `OutOfMemory` by increasing `CompilerCache` to 256KB. Corrected "very large expressions" test string concatenation.
- [x] Compilation Error Handling: Updated TS bindings to return `success: false` instead of throwing when `.compile()` fails, matching `integration.test.ts` expectations.
- [x] 1x1 Matrix vs Unit Literal: Improved tokenizer heuristic to distinguish between `[100]` (matrix) and `[m]` (unit) by checking for alpha characters.
- [x] Technical Indicators: Fixed `SMA`, `EMA`, `RSI` syntax in tests (removed keyword labels). RSI convergence improved by using longer input sequence.

## Parity Tasks
- [x] Port `probability_tests.zig` to TypeScript.
- [x] Port `join_scenarios.zig` and other integration tests.
- [x] Ensure WASM target builds and passes all basic evaluation tests.
- [x] Port `stats_scenarios.zig`, `indicator_scenarios.zig`, and `resampling_scenarios.zig` scenarios to `timeseries.test.ts`.

## Progress Log
### 2026-01-10
- Achieved 100% parity for core MathZig features across Zig, FFI, and WASM.
- Fixed critical bugs in tokenizer, predicate construction, and memory management.
- Implemented `last()`, `duration()`, `asof_join` alias, and `identity`/`zeros`/`ones` built-ins.
