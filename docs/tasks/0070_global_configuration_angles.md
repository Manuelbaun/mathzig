# Task 0070: Global Configuration (Angles and more)

## Problem
MathZig lacks a global configuration system. For example, users should be able to choose between degrees and radians for trigonometric functions, similar to Math.js.

## Proposed Solution
- Implement a `Config` struct in `src/core/config.zig`.
- Support options like `angles: .radians | .degrees`.
- Update trigonometric functions to respect this configuration.
- Expose `config(options)` in the DSL.

## Implementation Plan
- [x] Create `src/core/config.zig`.
- [x] Update `VM` to hold a reference to the current configuration.
- [x] Update trig functions in `src/vm/vm.zig` to check `self.config.angles`.
- [x] Implement `config()` builtin to get/set settings.
- [x] Add tests in `tests/zig/config.test.zig`.

## Verification
- `zig build test` (Passed)
- Trig functions switch correctly between radians and degrees.

## Status
**Completed** (2026-01-24)
- Created `Config` system with support for `AngleMode`.
- Refactored `VM` initialization to propagate global configuration.
- Integrated configuration into trig builtins (`sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`).
- Exposed configuration through DSL with `config()` and `config({ angles: "..." })`.
