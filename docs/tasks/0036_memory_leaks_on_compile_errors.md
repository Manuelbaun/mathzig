# Task: Memory Leaks on Compile Errors

## Priority: Low

## Problem
The Zig test runner reports 2 leaked memory errors during test execution. These leaks occur specifically in tests that validate error handling when compilation fails. When the compiler encounters an error, it appears that some allocated memory (likely in the AST or IR phases) is not properly cleaned up before returning the error.

## Details
- **Symptom:** `zig build test` reports "2 errors were leaked".
- **Location:** Likely within `src/parser/compiler.zig` or related allocation arenas when a compilation error is triggered.
- **Context:** These leaks were identified as pre-existing during the fix of other issues in January 2026.

## Subtasks
- [x] Identify the specific tests causing the leaks. (Identified as `error_validation.test.zig`)
- [x] Audit `Compiler.compile` and related methods for early returns on error that bypass cleanup. (Addressed in Task 0030)
- [x] Ensure the compiler's arena or metadata allocator is properly cleared even when compilation fails. (Addressed in Task 0030)

## Verification Plan
### Automated Tests
- [x] Zig unit tests: `zig build test` (expecting 0 leaks). Verified in Task 0030.

## Progress Log
- 2026-01-15: Bug recorded after resolving other critical test failures.
- 2026-01-16: Transferred from `docs/bugs/0001_memory_leaks_on_compile_errors.md`.
- 2026-01-16: Resolved as part of Task 0030 (Memory Leak Fixes).

## Status
**Completed**
