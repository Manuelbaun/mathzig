# Task 0088: Fix Unit Subtraction Bug

- **ID:** 0088
- **Status:** Open (verified 2026-07-15 — needs runtime repro)
- **Priority:** Medium
- **Effort:** Small-Medium

## Overview
`5 km - 100 mile` returns `5000` (just the SI value of the first operand) instead of `-155934.4 m`. The second operand is effectively ignored in unit subtraction.

## Affected Tests
- `arithmetic/subtract > should subtract two quantities of the same unit`
- `arithmetic/subtract > should throw an error if subtracting two quantities of different units`

## Root Cause Investigation
Look in `src/core/value.zig` (or wherever unit arithmetic is performed) for the subtraction path. The bug likely stems from:
1. Unit conversion only converting the first operand to SI, or
2. The result taking the unit metadata from the first operand but not subtracting the second's SI value.

## Implementation Plan

1. [ ] **Locate** unit subtraction in `src/core/value.zig` — search for `Value.sub` or `Unit.sub`.
2. [ ] **Verify** both operands are converted to a common SI base before subtraction.
3. [ ] **Fix** the subtraction: `result_si = a_si - b_si`, wrapped in the output unit.
4. [ ] **Add validation:** If units are dimensionally incompatible (e.g. `km - gram`), throw a type error.

## Verification
```bash
bun test tests/ts/parity/mathjs_unit/arithmetic_subtract.test.ts
```
Expected: `5 km - 100 mile ≈ -155934.4` (result in meters).

## Paths
- `src/core/value.zig`
- `src/vm/vm.zig` (binary subtract dispatch)

---

## Verification (2026-07-15)

- **True status:** `UNKNOWN`
- **Evidence:** Value.sub mentions unit=True; units.json exists=True
- **Notes:** Needs runtime repro of specific bug; cannot close from static scan.
- **Audit:** [true_status_audit.md](true_status_audit.md)

