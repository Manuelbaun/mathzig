# Task: Fix Test Expectations

## Priority: Low

## Problem

One test has incorrect expectation:

**Test:** `error_validation.test.test.VM: sma rejects non-number period`
```
Expected: error.NotEnoughArgs
Got: error.TypeError
```

The test expects `NotEnoughArgs` when passing a non-number period to `sma()`, but the implementation returns `TypeError` which is more accurate.

## Analysis

When calling `sma(series, "not a number")`:
- The function tries to convert the period argument to a number
- It fails because it's a string, not a number
- Returns `TypeError` (type mismatch)

`NotEnoughArgs` would be for `sma(series)` with missing argument.
`TypeError` is correct for `sma(series, "bad")` with wrong type.

## Subtasks

- [ ] Review the test in `tests/zig/error_validation.test.zig`
- [ ] Change expectation from `error.NotEnoughArgs` to `error.TypeError`
- [ ] Verify the fix with `zig build test`

## Files to Modify

- `tests/zig/error_validation.test.zig`

## Status

Open (verified 2026-07-15 — not done)

---

## Verification (2026-07-15)

- **True status:** `OPEN`
- **Evidence:** error_validation files=[PosixPath('tests/zig/diagnostics/error_validation.zig')]; sma_hint=tests/zig/diagnostics/error_validation.zig:144:test "VM: sma rejects non-number period" {
- **Notes:** Small test-only task; no evidence of fix applied.
- **Audit:** [true_status_audit.md](true_status_audit.md)

