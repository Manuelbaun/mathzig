# Task 0069: Runtime Unit Creation

## Problem
To support currency conversion and other dynamic physical systems, MathZig needs the ability to define new units at runtime, similar to `math.createUnit` in Math.js.

## Proposed Solution
- Implement a way to add new unit definitions to the `UnitSystem`.
- Expose a builtin function `create_unit(name, base_unit_value)` in the DSL.
- Ensure the parser can recognize these new units immediately after they are defined.

## Implementation Plan
- [x] Add dynamic unit registration to `src/units/unit_registry.zig`.
- [x] Update `VM` to hold a reference to `UnitRegistry` and propagate it to sub-VMs.
- [x] Add `create_unit` builtin function to handle runtime registration.
- [x] Add tests for runtime unit creation and conversion in `tests/zig/runtime_units.test.zig`.

## Verification
- `zig build test` (Passed)
- Currency conversion example works in tests.

## Status
**Completed** (2026-01-24)
- Implemented `create_unit(name, base_val)` builtin.
- Supported scalar, derived, and physical unit definitions at runtime.
- Refactored `UnitRegistry` to own dynamically created unit names.
- Fixed unit resolution priority in parser to support immediate usage of new units.

## Backlog: Dynamic/Volatile Units
For high-frequency market data (e.g., Bitcoin prices), units need to support "late-binding" to avoid stale data caused by constant folding during compilation.

**Requirements for consideration:**
- **Late-Binding:** Introduce a way to mark a unit as "dynamic" so the VM fetches its scale factor at execution time rather than bake it in during compile time.
- **Constant Folding Protection:** The compiler's `simplify()` pass must be aware of dynamic units and skip folding for expressions containing them.
- **Live Updates:** Re-defining a unit via `create_unit` should immediately affect all existing compiled expressions that use that unit.
- **Series Integration:** Consider if a unit's scale could be a `Series`, allowing `10 BTC` to automatically evaluate to a time-series of values.

