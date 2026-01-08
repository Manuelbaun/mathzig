# MathZig VM Architecture

This document describes the internal architecture of the MathZig Virtual Machine. It serves as the source of truth for understanding stack operations, memory management, and instruction semantics.

## Overview

The MathZig VM is a stack-based virtual machine designed for high-performance mathematical expression evaluation. It supports a mix of scalar types (`f64`), complex numbers, and heap-allocated objects like Matrices, Records, and Time-Series.

## Core Concepts

### 1. The Stack
- **Structure:** A fixed-size array of `Value` unions (`[256]Value` currently).
- **Operation:** Last-In, First-Out (LIFO).
- **Pointer:** `sp` (Stack Pointer) points to the *next* free slot.
- **Safety:** Pushing decrements free space; popping increments free space. Underflow/Overflow checks are critical invariants.

### 2. The Value Union
All data on the stack is wrapped in a `Value` tagged union (16 bytes on 64-bit systems).
- **Inline:** `number` (f64), `boolean` (bool), `unit` (struct), `complex` (struct).
- **Reference:** `matrix`, `series`, `record`, `string` (pointers).
- **Ownership:** The VM *owns* references on the stack. When a reference value is popped and discarded, it must be `release()`ed.

### 3. Memory Management
- **Arena:** Temporary allocations (like string keys during compilation) use a `ChunkArena`.
- **Reference Counting:** Heap objects (`Matrix`, `Series`, `Record`) use intrusive reference counting (`ref_count`).
- **Tracking:** The VM maintains a list of "intermediate" objects created during execution that aren't assigned to variables. These are auto-released after execution.

## Instruction Set Architecture (ISA)

Instructions are packed structs containing an `Opcode` (u8) and an `Operand` (u24).

### Stack Operations
- `push_const (idx)`: Pushes `constants[idx]` onto the stack.
- `pop`: Removes top value.
- `dup`: Duplicates top value.

### Record Operations (Critical Ordering)
Because the compiler emits arguments left-to-right (key then value), but the stack is LIFO:

#### `rec_create`
**Operand:** `field_count`
**Stack Pre-condition (Top at right):** `[... key1, val1, key2, val2]`
**Execution:**
1. Loop `field_count` times:
2. Pop `value` (Top)
3. Pop `key` (Next)
4. `record.set(key, value)`
**Stack Post-condition:** `[... record]`

*Invariant:* `rec_create` must ALWAYS pop `value` then `key`.

#### `rec_get` (Static)
**Operand:** `key_const_idx`
**Stack Pre-condition:** `[... record]`
**Execution:**
1. Resolve key from constants.
2. Pop `record`.
3. Lookup key.
4. Push `result`.

#### `rec_get_dyn` (Dynamic)
**Stack Pre-condition:** `[... object, key]`
**Execution:**
1. Pop `key` (Top).
2. Pop `object` (Next).
3. Type check: `key` is String, `object` is Record.
4. Lookup.
5. Push `result`.

*Invariant:* `rec_get_dyn` must ALWAYS pop `key` then `object`.

### Matrix Operations
- `mat_create`: Operand encodes rows/cols. Pops values in reverse order (last element popped first).

### Control Flow
- `jmp`, `jmp_if_false`, `jmp_if_true`: Relative or absolute jumps within the bytecode array.

## Development Guidelines

1.  **Pop Order:** When implementing an opcode that consumes $N$ arguments, remember they are on the stack in pushing order. To retrieve them:
    ```zig
    const arg_N = self.pop(); // Top of stack (last pushed)
    const arg_N_minus_1 = self.pop();
    ...
    const arg_1 = self.pop(); // First pushed
    ```
2.  **Reference Counting:** If you pop a reference value and *don't* store it or return it, you MUST `release()` it.
3.  **Type Safety:** Always check `.tag` before accessing union fields. Return `VMError.TypeError` on mismatch.
