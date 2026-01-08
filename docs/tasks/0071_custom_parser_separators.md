# Task 0071: Custom Parser Separators

## Problem
Currently, the MathZig parser has hardcoded separators. While flexibility is desired, using a comma as a decimal separator creates severe ambiguity with element listings in matrices and arrays.

## Proposed Solution
- **Strict Standards:** Enforce the standard `.` (dot) as the ONLY valid decimal separator, consistent with programming languages and to prevent ambiguity.
- **Listing Separator:** Keep `,` (comma) as the standard separator for elements in lists, matrices, and function arguments.
- **Configurable Row Separators:** Support configuring the matrix *row* separator (e.g., `;` or `|`) since these do not conflict with the numeric dot or the element comma.

## Implementation Plan
- [x] Add configuration options for `row_separator` to `src/core/config.zig`.
- [x] Revert decimal comma logic in `src/parser/tokenizer.zig` and `src/parser/compiler.zig`.
- [x] Ensure `matrix()` parsing correctly handles the configured row separator.
- [x] Add tests for valid row separator configurations in `tests/zig/custom_separators.test.zig`.

## Verification
- `zig build test` (Passed)
- Matrix parsing works with both default `;` and custom `|` separators.
- Decimals strictly use `.` and listings strictly use `,`.

## Status
**Completed** (2026-01-24)
- Enforced standard `.` for decimals and `,` for list elements to avoid ambiguity.
- Supported configurable matrix row separators (default `;`, supports any character like `|`).
- Cleaned up tokenizer and compiler from temporary "decimal comma" logic.
- Verified system stability with a full test suite.
