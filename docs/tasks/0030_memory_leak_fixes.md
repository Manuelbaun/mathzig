# Task: Fix Memory Leaks in Tests

## Priority: High

## Problem

There were 3 memory leaks detected in tests:

1. **Nested Record Access** (`record_tests.test.nested record member access`)
   - Expression: `{ a: { b: 42 } }.a.b`
   - Leaks the intermediate record structures

2. **Compiler Error Handling** (`error_validation.test.test.Compiler: invalid number format`)
   - Expression: `"1..2"` (invalid syntax, implicit multiplication makes it valid but unexpected)
   - Compiled expression not freed on error path

3. **Compiler Error Handling** (`error_validation.test.test.Compiler: invalid binary literal`)
   - Similar leak on unexpected success

## Root Cause Analysis

### Nested Record Leak
When accessing `{ a: { b: 42 } }.a.b`:
1. Inner record `{ b: 42 }` is created and tracked (ref=1).
2. Outer record `{ a: ... }` is created. `setOwned` increments inner ref (ref=2).
3. `rec_create` logic untracks inner from VM, but DOES NOT release the original intermediate reference.
4. When `outer` is freed, it releases `inner` (ref->1).
5. **Issue**: `inner` persists with ref=1.
6. **Attempted Fix**: Releasing `inner` after `setOwned` fixes the leak but causes crashes (Signal 6, Result Error: 1) in `Dynamic Field Access` tests, implying a use-after-free or memory corruption scenario in complex access patterns. Fix was reverted to preserve stability.

### Compiler Error Leak
When compilation fails or succeeds unexpectedly:
1. `BytecodeBuilder.build()` didn't use `errdefer` to clean up `constants` if subsequent allocations (`constants_f64`, `code`) failed.
2. `error_validation.test.zig` tests for invalid syntax (`1..2`) were actually succeeding (due to implicit multiplication parser feature), and the test code was not freeing the resulting `CompiledExpr`.

## Resolution

- [x] **Compiler Fix**: Added `errdefer` in `BytecodeBuilder.build()` to clean up allocated slices on error.
- [x] **Test Fix**: Updated `error_validation.test.zig` to properly free `CompiledExpr` (using `ctx.freeExpr`) when `compile()` succeeds unexpectedly.
- [x] **Test Fix**: Corrected expectation in `sma` test (expect `TypeError` for string period).
- [x] **Record Leak**: Fixed by releasing after setOwned and retaining on get.

## Files Examined

- `src/vm/vm.zig` - `rec_create` opcode
- `src/vm/bytecode.zig` - `BytecodeBuilder.build()`
- `src/parser/compiler.zig`
- `tests/zig/error_validation.test.zig`

## Status

**COMPLETED** - All leaks fixed:
- Compiler error path cleanup (errdefer)
- Test fixes for unexpected success cases
- Record leak fixed: Added `field_val.release()` after `setOwned()` in `rec_create`
- Fixed `rec_get`/`rec_get_dyn` to `retain()` before `trackValue()` to prevent double-free