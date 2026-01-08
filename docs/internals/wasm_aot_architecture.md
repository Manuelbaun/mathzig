# WASM AOT Backend: Architecture

## Goal
The WASM AOT (Ahead-of-Time) backend compiles MathZig bytecode (`CompiledExpr`) directly into standalone WebAssembly (`.wasm`) binaries.

## Compilation Pipeline
```
[Source Code] -> [Parser] -> [CompiledExpr (Bytecode)] -> [WasmCompiler] -> [WasmModule] -> [.wasm Binary]
```

## Data Mapping
| MathZig Concept | WASM Concept | Notes |
| :--- | :--- | :--- |
| `Value.number (f64)` | `f64` | Native mapping. |
| `Value.matrix` | `i32` (Pointer) | Uses Linear Memory (Heap). |
| `VM Stack` | WASM Operand Stack | Maps naturally. |
| `Registers (Vars)` | `local.get` / `local.set` | Variables 0..255 map to locals. |
| `Builtins (sin, cos)` | `func` (Imported) | Imported from 'env' namespace. |

## Control Flow Strategy
MathZig uses unstructured jumps (`JMP`, `JMP_IF`). 
*   **Simple Loops/Branches:** Handled via pattern matching in `compileSequence`.
*   **Arbitrary Jumps:** Requires a Relooper algorithm (Phase 4) to restructure into `block`/`loop`.

## Interaction Models
### 1. Browser / Node / Bun
The host provides imports for math functions and manages the WASM memory buffer.
```javascript
const imports = {
  env: {
    sin: Math.sin,
    pow: Math.pow,
  }
};
const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
const result = instance.exports.eval(args...);
```

### 2. Standalone Runtimes (Wasmtime/Wasmer)
Host applications in Rust/Go provide the same `env` mapping to their native math libraries.
