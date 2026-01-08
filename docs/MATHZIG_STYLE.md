# MATHZIG_STYLE

This document defines the coding standards and design philosophy for the MathZig project. We follow a "Safety, Performance, Developer Experience" priority model, heavily inspired by TigerStyle.

## 1. Core Principles

- **Safety First:** Correctness is more important than performance. Use assertions liberally.
- **Performance:** Mathematical operations must be SIMD-optimized and multicore-aware.
- **Simplicity:** Prefer simple, flat logic over complex abstractions.
- **Mechanical Sympathy:** Code should be written with CPU cache, SIMD lanes, and FFI overhead in mind.

## 2. Safety & Assertions

- **Assertion Density:** Aim for at least 2 assertions per function.
- **Pre/Post Conditions:** Assert that inputs are valid (e.g., matrix dimensions match) and outputs make sense.
- **Positive & Negative Space:** Assert not just that data is correct, but that invalid data is caught.
- **No Recursion:** Avoid recursion in the compiler and VM to prevent stack overflows and ensure bounded execution.

## 3. Memory Management

- **Arena-First:** Use `ChunkArena` for expression-lifetime allocations (AST nodes, bytecode).
- **Static Lifecycle:** Core VM state and function registries should be initialized once and rarely modified.
- **FFI Boundary:** Clearly define ownership. If the Zig side allocates memory returned to JS, it must be tracked and freed via an explicit handle or the Context.
- **No Hidden Allocations:** Functions that allocate must take an `Allocator` as an argument or clearly state their allocation behavior.

## 4. Naming Conventions

- **Case:** Use `snake_case` for functions, variables, and files. Use `PascalCase` for types (structs, enums).
- **Descriptive Naming:** Avoid single-letter variables except for loop indices (`i`, `j`) or well-known mathematical variables (`x`, `y`, `z`).
- **Units & Qualifiers:** Put units and qualifiers at the end of the name.
  - Good: `timeout_ms`, `price_usd_total`, `matrix_rows`.
  - Bad: `ms_timeout`, `total_price`, `rows`.
- **FFI Exports:** All C-exported functions must be prefixed with `mathzig_`.

## 5. Coding Style

- **Line Length:** Hard limit of 100 columns.
- **Function Length:** Aim for a maximum of 70 lines per function. If it's longer, refactor logic into leaf functions.
- **Explicit over Implicit:** Do not rely on default values or implicit behavior.
- **Error Handling:** Every error must be handled or explicitly propagated. No `_ = functionWithErr();`.
- **Comments:** Comments should explain **WHY**, not what. The code should show what is happening.

## 6. Testing

- **Test-Driven:** Every new feature, builtin function, or bug fix MUST include corresponding Zig unit tests.
- **FFI Verification:** If a feature is exposed to Bun/TypeScript, it MUST have a corresponding `.test.ts` file in the `tests/` directory.
- **Edge Cases:** Tests must cover zero, negative, infinity, and NaN values for mathematical functions.

## 7. Mathematical Integrity

- **SIMD Alignment:** Ensure matrix buffers are 32-byte aligned for AVX/NEON.
- **Stability:** Prefer numerically stable algorithms (e.g., Kahan summation for large series).
- **Floating Point:** Be mindful of `f64` precision. Use `std.testing.expectApproxEqAbs` for floating point comparisons.
