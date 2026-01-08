# Task: VM Memory Ownership & Alignment Fixes (Zig 0.15.2)

- **Status:** In Progress (verified partial 2026-07-15)

## Goal
Stabilize the MathZig VM's memory management to prevent double-frees and leaks, while satisfying the strict type and alignment requirements of the Zig 0.15.2 compiler.

## Context
- **Zig 0.15.2 Compliance:** Stricter rules on pointer alignment (`@alignCast`) and variable shadowing.
- **Memory Safety:** Transitioning from a mixed ownership model to a "Tracker-Owned" model where `intermediate_objects` in the VM holds the primary reference, and the stack holds non-owning observations for intermediate results.

## Subtasks

### 1. Ownership Model Refactor (Tracker-Owned)
- [x] Implement unified `intermediate_objects` hash map in `VM`.
- [x] Update `trackMatrix`, `trackSeries`, `trackRecord` to use address-based deduplication.
- [x] Refactor `VM.push` and `VM.pop` to be non-owning (no retain/release).
- [x] Update opcodes (`add`, `sub`, `mul`, `div`, etc.) to use standard `pop`/`push` without manual release (since stack is non-owning).
- [x] Ensure creation opcodes (`mat_create`, `zeros`, `identity`, etc.) only track the object and push a non-retained reference.
- [x] Update `execute` to transfer ownership of the *final* result to the caller (retaining it once before returning).
- [x] Release all values stored in variables during `VM.deinit`.
- [x] Untrack reference types when storing them in records (`rec_create`) to prevent double-release.

### 2. Slices and Alignment (Zig 0.15.2)
- [x] Update `VM.executeBatchSIMD` and `VM.executeBatchComplexSIMD` signatures to take `[]const f64` / `[]f64` slices instead of raw many-pointers (`[*]f64`).
- [x] Update `api_definition.zig` to pass slices to these batch functions.
- [x] Fix `tests/performance/perf_runner.zig` alignment syntax: Changed `.{"32"}` to `.@"32"` for proper enum tag syntax.

### 3. Peripheral Regressions
- [x] Restore `VM.executeNumbersOnlyUnchecked` which was accidentally removed.
- [x] Add missing imports (`Vec`, `VectorLen`) in `VM`.
- [x] Add `dup` opcode handling to `executeNumbersOnlyUnchecked` for assignment expressions.
- [x] Mark comparison operators (`lt`, `le`, `gt`, `ge`, `eq`, `ne`) as non-numeric in bytecode builder.
- [x] Mark boolean operators (`and_`, `or_`, `not_`) as non-numeric.
- [x] Mark bitwise operators (`band`, `bor`, `bxor`, `bnot`, `shl`, `shr`) as non-numeric.
- [x] Mark `call_builtin`, `call_builtin_where`, and jump opcodes as non-numeric.
- [x] Remove manual unit name freeing (unit names are arena-allocated via metadata_allocator).

### 4. Unit Name Memory Management
- [x] Removed manual `allocator.free(name)` calls for unit names from:
  - `VM.deinit`
  - `VM.freeIntermediates`
  - `VM.setVariable`
  - `VM.setVariableF64`
- [x] Unit names are now properly managed by the arena allocator (metadata_allocator).

## Verification
- [x] Compile `mathzig` library.
- [x] Compile `perf_runner`.
- [x] Run `replay.mzig` successfully without leaks or segfaults.
- [x] 225/227 tests pass (99% pass rate).

## Remaining Issues (Pre-existing, not related to this refactor)
- [ ] `csv_loading.test.test.CSV: loading data with headers` - Returns wrong value.
- [ ] `error_validation.test.test.VM: sma rejects non-number period` - Test expectation mismatch (expected NotEnoughArgs, got TypeError).
- [ ] Some error_validation tests leak memory when compiling invalid expressions.

## Summary
The VM memory model has been successfully refactored to use a "Tracker-Owned" approach:
1. **Intermediate objects** are tracked in a hash map and released at the end of `execute()`.
2. **Variables** retain their values and release them during `deinit`.
3. **Records** own their nested reference types (matrices, series, records are untracked when stored).
4. **Unit names** are arena-allocated and automatically freed when the context is destroyed.
5. **The fast path** (`executeNumbersOnly`) now correctly falls back to the full VM for expressions with comparison, boolean, and builtin function opcodes.

---

## Verification (2026-07-15)

- **True status:** `PARTIAL`
- **Evidence:** Task body: ~25 checkboxes done, 3 residual failures (csv headers, sma expectation, compile-error leaks)
- **Notes:** Core memory/alignment work landed; residual test debt.
- **Audit:** [true_status_audit.md](true_status_audit.md)

