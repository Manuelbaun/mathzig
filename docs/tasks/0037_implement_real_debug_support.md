# Task: Implement Real Debug Support

## Priority: Low

## Overview
Implement a systematic debugging and tracing framework for the MathZig VM and Compiler to resolve complex bugs (like Task 0031) faster. Adopt the TigerBeetle "Crash Early" philosophy by making assertions pervasive and "invasive" during debug runs.

## Goals
1.  **Systematic Assertions:** Add `std.debug.assert` to all functions to verify parameters and invariants.
2.  **Instruction Tracing:** Create a switchable tracing mode that logs Opcode, Stack, and Variable state per cycle.
3.  **Source Mapping:** Link bytecode back to DSL source offsets for better error reporting.
4.  **Invasive Safety Audits:** Implement a debug-only "audit" that verifies the integrity of all tracked objects and variables.

## Detailed Implementation Plan

### Phase 1: Source Mapping (Compiler & Bytecode)
- [x] **Bytecode Side-Table:** Update `CompiledExpr` in `src/vm/bytecode.zig` to include `source_offsets: []u32`. This keeps `Instruction` (32-bit) compact while providing mapping.
- [x] **Builder Updates:** Modify `BytecodeBuilder` to accept a source offset for every `emit` call.
- [x] **Compiler Integration:** Update `src/parser/compiler.zig` to pass `self.previous.start` (or `current.start`) to the builder during bytecode emission.

### Phase 2: VM Tracing & Debug Mode
- [x] **Debug Flag:** Add `debug_mode: bool = false` to the `VM` struct in `src/vm/vm.zig`.
- [x] **Instruction Tracer:** Implement `VM.traceInstruction(ip, instr)` that prints:
    ```text
    [IP: 004] [Op: ADD] [Stack: 2] [Top: 10.5] [Source: "x + 5"]
    ```
- [x] **Stack Visualization:** Add a helper `dumpValue` to print the top stack value in a readable format.
- [x] **FFI Exposure:** Add `mathzig_set_debug(bool)` to the C API to toggle tracing at runtime from Bun/TS.

### Phase 3: Pervasive Assertions (Safety)
- [x] **Builtin Arg Validation:** All `callBuiltin` cases now return `error.NotEnoughArgs` for insufficient arguments (converted from `assert` since this is a user error, not a system error).
- [x] **Object Validation:** Ensure `Matrix`, `Series`, and `Record` magic numbers are checked in `setVariable`.
- [x] **Ref-Count Guard:** Assert that `ref_count > 0` in the audit function before any operation on reference types.

### Phase 4: Invasive Safety Pass
- [x] **VM Audit Function:** Implement `VM.audit()` which:
    - Scans `intermediate_objects` and verifies magic numbers.
    - Scans `variables` and verifies magic numbers for all reference types.
    - Checks `sp` is within bounds.
- [x] **Auto-Audit:** Call `VM.audit()` every 100 instructions when `debug_mode` is enabled.

### Phase 5: CSV Export Support
- [x] **Implement `writeCsv`:** Add `writeCsv` to `src/io/csv.zig` to support exporting `Series` and `Record` (of Series) to CSV files.
- [x] **DSL Builtin:** Register `write_csv(data, path)` as a builtin function in the compiler and VM.
- [x] **FFI Exposure:** Added `mathzig_write_csv(ctx, var_name, path)` and `mathzig_get_last_error_offset(ctx)` to the C API.

## Verification Plan
- [x] **Tracing Test:** Run a simple expression with `debug_mode = true` and verify console output. (`tests/zig/debug_trace_test.zig`)
- [x] **Source Map Test:** Force a VM error (e.g., `sin()` with no args) and verify `vm.getLastErrorOffset()` points to the correct character (offset 4 for `sin` in `"1 + sin()"`).
- [x] **Regression:** Ensure `zig build test` passes (233/233 tests pass).
- [x] **Error Formatting:** Implemented `formatErrorWithPointer` in `src/core/diagnostics.zig` and integrated it into both TUI (`src/tui/state.zig`) and REPL (`src/main.zig`). Added unit tests in `tests/zig/diagnostics_test.zig`.

## Status
**Complete** - All debugging infrastructure implemented and verified. Error reporting enhanced in TUI and REPL.
