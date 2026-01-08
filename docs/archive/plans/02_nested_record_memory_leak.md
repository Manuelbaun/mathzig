# Plan 02: Fix Nested Record Memory Leak

**Priority:** 🔴 Critical · **Effort:** 2-3 days · **Risk:** Medium (touches VM internals)

---

## Problem Statement

From [ROADMAP.md](../ROADMAP.md):

> **Nested Record Memory Leak:** VM intermediate tracking issue in `nested record member access`. Fix attempted (Signal 6) but requires deeper refactoring of stack management.

This means that expressions like `bollinger(price, 20).upper` or `{a: {b: 42}}.a.b` leave intermediate `Record` objects un-freed, causing memory to grow over repeated evaluations.

---

## Current Tracking Architecture

The VM uses a unified `TrackedObject` tagged union (good design — already unified):

```zig
pub const TrackedObject = union(enum) {
    matrix: *Matrix,
    series: *Series,
    record: *Record,
    slice: *val_module.Slice,

    pub fn release(self: TrackedObject) void {
        switch (self) {
            .matrix => |m| m.release(),
            .series => |s| s.release(),
            .record => |r| r.release(),
            .slice => |s| s.release(),
        }
    }
};
```

Tracked objects live in `intermediate_objects: std.AutoHashMapUnmanaged(usize, TrackedObject)`, keyed by pointer address. The VM provides `trackRecord()`, `untrackRecord()`, and `releaseIntermediate()` methods.

### The Problem Chain

When executing a nested access like `bollinger(price, 20).upper`:

1. `callBuiltin("bollinger", ...)` creates a `Record` with fields `{upper, middle, lower}` → tracked ✅
2. `rec_get` opcode accesses `.upper` → returns a `Series` → tracked ✅
3. The **intermediate Record** from step 1 should be released after step 2, but...
4. If the `rec_get` handler untrack+releases the record immediately, and the returned series was **owned by** the record, the series gets freed too → **Signal 6 (double free / use-after-free)**

The core tension: **the Record owns its field values, but the VM also needs to manage lifetimes independently when fields are extracted**.

---

## Root Cause Analysis

The issue is an **ownership transfer problem**:

- Records use `std.StringHashMap(Value)` for fields, and own those values
- When a field value is extracted via `rec_get`, the extracted value must be **retained** before the record is released
- But the current `rec_get` handler may not correctly retain complex field values (Series, Matrix) before releasing the parent Record
- A previous fix attempt likely tried to release the record in `rec_get`, but didn't retain the extracted value first, causing Signal 6

---

## Proposed Fix

### Strategy: Retain-Before-Release

In the `rec_get` opcode handler:

```zig
.rec_get => {
    const record_val = self.stack[self.sp - 1];
    const record = record_val.data.record;
    const field_name = expr.getStringConstant(inst.operand);
    
    if (record.get(field_name)) |field_val| {
        // 1. RETAIN the extracted value FIRST
        field_val.retain();
        
        // 2. Track the extracted value if it's heap-allocated
        self.trackIfNeeded(field_val);
        
        // 3. Now safe to untrack + release the parent record
        _ = self.untrackRecord(record);
        record.release();
        
        // 4. Replace stack top with the retained field value
        self.stack[self.sp - 1] = field_val;
    } else {
        // field not found → push undefined, still release record
        _ = self.untrackRecord(record);
        record.release();
        self.stack[self.sp - 1] = Value.initUndefined();
    }
}
```

### Key Invariant

> **Before releasing any container, all extracted sub-values must be independently retained and tracked.**

This pattern must also be checked for:
- `rec_get_dyn` (dynamic field access)
- Matrix indexing (`mat_index`, `get_index`) where sub-matrices might be views
- Nested member access chains (e.g., `a.b.c`)

---

## Testing Strategy

### Unit Tests to Add

1. **Single-level record access**: `{x: 42}.x` → verify no leak
2. **Nested record access**: `{a: {b: 42}}.a.b` → verify no leak
3. **Record with Series field**: `bollinger(price, 20).upper` → verify no leak and correct value
4. **Repeated evaluation**: Run `bollinger(price, 20).upper` 10,000 times in a loop, measure RSS before/after → should be stable
5. **Record field that is a Matrix**: `{m: [1,2;3,4]}.m` → verify matrix is correctly retained

### Verification Commands

```bash
# Zig tests
zig build test

# TS FFI tests (bollinger returns a record)
bun test tests/ts/

# Memory leak check (if available)
# Run a stress test and check for growing intermediate_objects count
```

---

## Deeper Refactoring (Optional Future Work)

If the retain-before-release pattern becomes error-prone across many opcodes, consider:

1. **Deferred Release Queue**: Instead of releasing intermediates immediately when overwritten on the stack, collect them in a deferred list and release at the end of `execute()`. This is simpler but uses slightly more peak memory.

2. **Reference-Counted Values**: Make all heap-allocated values (`Matrix`, `Series`, `Record`) consistently ref-counted, so the VM can `retain()` freely and only the last `release()` actually frees. The current `ref_count` on Matrix suggests this is partially in place but may not be consistently applied to Records.
