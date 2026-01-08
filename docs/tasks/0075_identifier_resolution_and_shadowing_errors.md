# Task 0075: Identifier Resolution and Shadowing Errors

## Priority: High

## Overview
Currently, identifier resolution in MathZig has implicit priorities that can lead to confusing compilation errors. For example, the identifier `s` is globally reserved as the unit for "seconds". If a user tries to define a function `f(s) = s^2`, the parser resolves `s` as a unit constant during the initial pass, causing the parameter list validation to fail with a generic "Compilation error" because it expected a variable node but got a unit node.

We need a proper resolution mechanic that:
1.  Detects when a reserved name (unit, built-in, or system constant) is being shadowed.
2.  Provides descriptive error messages when an identifier cannot be used as a parameter or variable name.
3.  Standardizes the resolution order (Parameters > Local Variables > Global Variables > Units > Built-ins).

## Goals
1.  **Descriptive Errors:** Replace generic `error.CompileError` with specific messages like `"Identifier 's' is a reserved unit and cannot be used as a parameter name"`.
2.  **Resolution Logic:** Refactor `Compiler.identifier` to handle the context of definition vs. usage.
3.  **Built-in Protection:** Prevent users from redefining core built-in functions or system constants (if any).
4.  **Unit Disambiguation:** Allow units to be used as identifiers only if they don't conflict with active scope variables, or explicitly prohibit shadowing with a clear error.

## Implementation Plan
- [x] **Audit Identifier Resolution:** Review `src/parser/compiler.zig`'s `identifier` and `functionCall` methods.
- [x] **Context-Aware Parsing:** Update parameter parsing in `functionCall` to strictly expect identifiers and avoid unit resolution when parsing a definition's signature.
- [x] **Improved `setError` Coverage:** Ensure all paths returning `error.CompileError` in `infix` and `identifier` call `self.setError()` with a helpful message.
- [x] **Shadowing Detection:** Add logic to check if a proposed variable/parameter name exists in the `UnitRegistry`.
- [x] **Verification:** Add tests in `tests/zig/shadowing.test.zig` specifically for shadowing scenarios.

## Verification
- `zig build test` (Passed)
- `bun test tests/ts/error_handling.test.ts` (Verify JS-side error messages are clear)

## Status
**Completed** (2026-01-24)
- Implemented `shadow_scope` mechanism in `Compiler` to track parameters during body parsing.
- Refactored `identifier()` to prioritize shadowed names over unit decomposition and built-ins.
- Added comprehensive shadowing tests for units and built-ins.
