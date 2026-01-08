# Subtask 0079.8: WASM Unsupported Opcode Handling

- **Status:** In Progress (verified partial 2026-07-15)
- **Priority:** Critical
- **Category:** WASM Compiler Correctness

## Overview
Ensure unsupported opcodes are not silently ignored during WASM compilation.

## Audit Notes (Current Coverage)
- **Default case is a no-op:** `compileInstruction` falls through to `else => {}` for unhandled opcodes, silently emitting no code.
- **Known opcodes currently unhandled:** `pos`, `call`, `mat_index`, `call_builtin_where`, and `nop` are not implemented in the switch and therefore get ignored.
- **Control-flow opcodes are explicitly rejected:** `jmp`, `jmp_if_false`, `jmp_if_true` return `UnexpectedUnstructuredJump`, which is correct but inconsistent with silent ignores for other opcodes.
- **Silent ignores can corrupt stack semantics:** Ignored opcodes still advance the compiler's instruction pointer but do not adjust the WASM stack or `type_stack`, producing invalid behavior without errors.

## Scope
- **Paths:** `src/wasm/compiler.zig`
- **Symbols:** `compileInstruction` default case
- **Invariants:** Unsupported opcodes produce explicit compile-time errors

## Implementation Plan
1. [ ] Replace `else => {}` with a hard error (`UnsupportedOpcode`).
2. [ ] Add a clear error message including opcode name and location.
3. [ ] Add a regression test that compiles a bytecode with an unsupported opcode.

## Verification Plan
### Automated Tests
- [ ] `zig build vm-baseline --summary all && zig build test --summary all`
- [ ] WASM compile test with intentionally unsupported opcode

## Progress Log
- 2026-01-23: Subtask created from audit.
- 2026-01-23: Audited opcode coverage and identified silent ignores.

---

## Verification (2026-07-15)

- **True status:** `PARTIAL`
- **Evidence:** UnsupportedOpcode handling present=True
- **Notes:** Hard fail path exists; full opcode matrix / policy still a gap.
- **Audit:** [true_status_audit.md](true_status_audit.md)

