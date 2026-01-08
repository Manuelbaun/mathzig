# Task 0095: String Comparison Operators

- **ID:** 0095
- **Status:** In Progress (verified partial 2026-07-15)
- **Priority:** Medium
- **Effort:** Medium

## Overview
String comparison operators don't work correctly:
- `"a" == "a"` always returns `false` (strings are never equal)
- `"2" < "10"` returns `false` (no numeric string coercion, unlike MathJS default)
- Only `!=` works reliably for strings

## Affected Tests
- `custom_relational_functions > should compare non-numeric strings using ==`
- `custom_relational_functions > should compare strings by their numeric value (MathJS default)`

## Implementation Plan

### Phase 1: String Equality (required for `==`)
1. [ ] **`src/vm/vm.zig`** — In the `==` operator dispatch, add a `ValueTag.String` branch:
   ```zig
   if (a.tag == .String and b.tag == .String) {
       return Value{ .tag = .Boolean, .bool = std.mem.eql(u8, a.str, b.str) };
   }
   ```
2. [ ] Same for `!=`.

### Phase 2: Numeric String Comparison (MathJS default behaviour)
3. [ ] For `<`, `>`, `<=`, `>=` on strings: try parsing both as `f64`. If successful, compare numerically. If either fails to parse, fall back to lexicographic comparison.
   ```zig
   const a_num = std.fmt.parseFloat(f64, a.str) catch null;
   const b_num = std.fmt.parseFloat(f64, b.str) catch null;
   if (a_num != null and b_num != null) { return a_num.? < b_num.?; }
   // else: lexicographic
   return std.mem.lessThan(u8, a.str, b.str);
   ```

## Verification
```bash
bun test tests/ts/parity/mathjs_examples/cases/advanced__custom_relational_functions.test.ts
```
Expected: both todo tests become passing.

## Paths
- `src/vm/vm.zig` (comparison operator dispatch)

---

## Verification (2026-07-15)

- **True status:** `PARTIAL`
- **Evidence:** equals handles string=True; ordering ops unclear
- **Notes:** Equality may work; relational string ops likely missing.
- **Audit:** [true_status_audit.md](true_status_audit.md)

