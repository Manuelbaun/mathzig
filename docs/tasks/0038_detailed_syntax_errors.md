# Task: Detailed Syntax Error Reporting

## Priority: High

## Overview
Improve error reporting for syntax errors (parsing phase). Currently, `MathZig` swallows detailed parsing errors and returns generic messages or error codes without location info for syntax errors.

## Goals
1.  Capture specific error messages from the `Compiler` (e.g., "Expected ')'", "Unexpected token").
2.  Capture the exact source offset of syntax errors.
3.  Ensure `MathZig.eval` exposes these details via `lastError()` and `getLastErrorOffset()`.
4.  Fix `Tokenizer` EOF position to point *after* the last character, not overlapping it.

## Implementation Plan
- [x] **Compiler Error State:** Add `error_msg` and `error_offset` to `Compiler` struct.
- [x] **Error Capture:** Implement `setError` and `setErrorFrom` in `Compiler` to populate these fields.
- [x] **MathZig Integration:** Update `MathZig.compileInPlace` to transfer error info from `Compiler` to `MathZig` context on failure.
- [x] **Tokenizer Fix:** Correct `EOF` token start position to be `source.len`.
- [x] **Verification:** Add `tests/zig/syntax_error_test.zig` to verify messages and offsets for syntax errors.

## Verification
- Run `zig build test`.
- Verify `syntax_error_test` passes.

## Status
**Complete**
