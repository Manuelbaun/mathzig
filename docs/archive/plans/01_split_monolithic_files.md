# Plan 01: Split Monolithic Source Files

**Priority:** 🔴 Critical · **Effort:** 2-4 days · **Risk:** Low (pure refactoring)

---

## Problem Statement

Two core source files have grown to a point where they impede maintainability, reviews, and compile-time:

| File | Lines | Outline Items | Responsibility |
|------|-------|---------------|----------------|
| [vm.zig](../../src/vm/vm.zig) | **3,601** | 207 | VM init, execute, builtins, SIMD, tracking, user functions |
| [compiler.zig](../../src/parser/compiler.zig) | **2,683** | 161 | Tokenizer integration, Pratt parsing, AST simplification, peephole optimization, bytecode emission |

These are the two largest files in the entire codebase (25,532 LoC total), together accounting for **24.6%** of all Zig source.

---

## Current Structure: `vm.zig`

The VM file contains at least **5 distinct concerns** interleaved in a single struct:

1. **VM Core** (lines 117–340): Struct definition, `init`, `deinit`, variable management, intermediate tracking
2. **Execute Loop** (lines 341–~1200): Main dispatch loop handling 50+ opcodes
3. **Builtin Dispatch** (lines ~1200–~2800): `callBuiltin()` with 60+ function implementations spanning math, trig, statistics, time-series, ODE, generators, CSV, etc.
4. **SIMD Paths** (lines ~2800–~3200): `executeBatchSIMD()`, `executeNumbersOnlyBatch()`
5. **User Functions** (lines 307–340): `callUserFunction()` with sub-VM creation

### Why This Is a Problem

- A single change to a builtin (e.g., adding a new function) requires navigating 3,600 lines
- The `callBuiltin` function alone is likely 1,500+ lines — a single function that switches on 60+ names
- Testing individual concerns (e.g., just SIMD execution) requires compiling the entire VM
- Code review diffs are hard to contextualize

### Proposed Split

```
src/vm/
├── vm.zig                  # VM struct, init, deinit, variable management (~400 lines)
├── execute.zig             # Main dispatch loop, stack operations (~800 lines)
├── builtins.zig            # callBuiltin() dispatch table (~1,500 lines)
├── builtins_timeseries.zig # Time-series specific builtins (~400 lines)
├── simd.zig                # SIMD batch execution paths (~400 lines)
└── bytecode.zig            # (unchanged)
```

### Migration Strategy

1. **Extract `builtins.zig` first** — this is the lowest risk since builtins are purely dispatched functions with no internal state dependencies. Move the giant switch statement into a separate file with `pub fn callBuiltin(vm: *VM, name: []const u8, args: []Value) !Value`.

2. **Extract `simd.zig` second** — SIMD paths are self-contained execution modes that only need access to the VM's stack and variable arrays.

3. **Extract `execute.zig` last** — this is the most coupled, since it calls builtins and uses tracking. But with builtins and SIMD already extracted, it becomes a focused dispatch loop.

---

## Current Structure: `compiler.zig`

The compiler file mixes 3 responsibilities:

1. **Parsing** (lines 86–~1200): Pratt parser with `expression()`, `parsePrecedence()`, prefix/infix rules
2. **AST Simplification** (lines ~1200–~1800): `simplify()` with constant folding, identity rules
3. **Code Generation** (lines ~1800–~2683): `emitBytecode()`, `optimizeBytecode()` (peephole), bytecode builder interaction

### Proposed Split

```
src/parser/
├── compiler.zig      # Top-level compile() orchestration, re-exports (~200 lines)
├── parser.zig        # Pratt parsing, expression(), prefix/infix rules (~1,000 lines)
├── optimizer.zig     # simplify() + optimizeBytecode() peephole pass (~600 lines)
├── codegen.zig       # emitBytecode() AST-to-bytecode lowering (~800 lines)
└── tokenizer.zig     # (unchanged)
```

### Migration Strategy

1. **Extract `optimizer.zig` first** — `simplify()` and `optimizeBytecode()` are pure transformations (AST→AST and bytecode→bytecode) with no parser state dependencies.

2. **Extract `codegen.zig` second** — `emitBytecode()` walks the AST and emits instructions via the builder. It only needs access to the `BytecodeBuilder` and constant pool.

3. **Keep `compiler.zig` as facade** — the `Compiler` struct remains the public API, calling parser → optimizer → codegen in sequence.

---

## Invariants to Maintain

- All `@import` paths within `src/vm/` and `src/parser/` are relative
- The public API surface (`VM.init`, `VM.execute`, `Compiler.compile`) doesn't change
- Zero behavioral changes — this is a pure structural refactoring
- All 319 tests must continue passing after each extraction step

## Verification

```bash
# After each extraction:
zig build test && bun test
```
