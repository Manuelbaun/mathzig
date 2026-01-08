# Task 0094: Complex Number Support for pow and Trig

- **ID:** 0094
- **Status:** In Progress (verified partial 2026-07-15)
- **Priority:** High
- **Effort:** Large

## Overview
Two categories of complex number support are missing:

1. **`pow` with negative base and non-integer exponent:** `(-2) ^ 1.5` returns `NaN` instead of the complex result `~2.83i`.
2. **Trig functions on complex inputs:** `sin(1+i)` throws "Type error: operation requires compatible types".

## Affected Tests
- `arithmetic/pow > should exponentiate a negative number to a non-integer power`
- `trigonometry > sin > should return the sine of a complex number`

## Implementation Plan

### Part 1: Complex pow (negative base, fractional exponent)
1. [ ] **`src/vm/vm.zig`** — In the `^` operator, when `base < 0` and `exponent` is non-integer:
   - Compute via polar form: `r = |base|`, `θ = π` (since base < 0)
   - Result: `r^n * (cos(n*θ) + i*sin(n*θ))`
   - Return `ValueTag.Complex`.

### Part 2: Complex trig functions
2. [ ] **`src/vm/vm.zig`** — In `callBuiltin` for `sin`, `cos`, `tan`, add a `ValueTag.Complex` branch:
   ```
   sin(a + bi) = sin(a)·cosh(b) + i·cos(a)·sinh(b)
   cos(a + bi) = cos(a)·cosh(b) - i·sin(a)·sinh(b)
   tan(a + bi) = sin(a+bi) / cos(a+bi)
   ```
3. [ ] Similarly implement for `sinh`, `cosh`, `tanh` on complex inputs.
4. [ ] Ensure `abs(complex)` already works — it does (confirmed).

## Verification
```bash
bun test tests/ts/parity/mathjs_unit/arithmetic_pow.test.ts
bun test tests/ts/parity/mathjs_unit/trigonometry.test.ts
```

## Paths
- `src/vm/vm.zig`
- `src/core/value.zig` (complex arithmetic helpers)

---

## Verification (2026-07-15)

- **True status:** `PARTIAL`
- **Evidence:** Complex methods: abs,add,arg,conj,div,exp,log,mul,neg,pow,sqrt,sub — missing sin/cos/tan on Complex
- **Notes:** pow/exp/log/abs present; trig on complex still missing for MathJS parity.
- **Audit:** [true_status_audit.md](true_status_audit.md)

