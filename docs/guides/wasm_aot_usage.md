# MathZig AOT: Consumption Guide

This guide explains how to use `.wasm` modules exported by the MathZig AOT compiler.

## Compile Modes

```bash
# Default AOT (may require env imports such as log/exp/ode_solve_euler)
./zig-out/bin/mathzig compile -i input.mzig -o output.wasm

# Standalone AOT (no imports, can run directly in wasmer/wasmtime)
./zig-out/bin/mathzig compile -i input.mzig -o output.wasm --standalone
```

Notes:
- `--standalone` currently stubs `ode_solve_euler` and returns `NaN`.
- `--standalone` fails compilation if an unsupported host import would be required.

## Fused graph compile (`compile-graph`)

Produce **one** wasm module for an entire scalar `GraphDefinition` (multi input / multi output values):

```bash
./zig-out/bin/mathzig compile-graph -i graph.json -o out.wasm
# → out.wasm  (exports tick; mathzig:graph custom section)
# → out.graph.json  (JSON sidecar, same payload as the custom section)

./zig-out/bin/mathzig compile-graph -i graph.json -o out.wasm --out-mode named_exports
./zig-out/bin/mathzig compile-graph -i graph.json -o out.wasm --standalone  # fail if env imports required
```

| Option | Meaning |
|--------|---------|
| `-i` / `--input` | Graph JSON path |
| `-o` / `--output` | Output `.wasm` path |
| `-v` | Verbose (plan summary + bytecode dumps) |
| `-s` / `--standalone` | Hard-error if any host import would be required |
| `--out-mode` | `table` (**CLI default**) or `named_exports` |
| `--export-node-helpers` | Also export `n_<id>` per compute node |

Load the artifact in TypeScript with `FusedGraphRunner.load(wasmBytes)` (see `src/ts/graph/fused_runner.ts`).  
`compileFused(def)` shells to this CLI when `zig-out/bin/mathzig` is present.

**Default split:** CLI `compile-graph` defaults to `out_mode=table` (Spec 01 preferred).  
TS `compileFused` defaults to **`table` when the graph has any non-scalar port** (Spec 07 full-value), and `named_exports` for pure-scalar graphs (historical golden compatibility). Pass `{ outMode: "table" | "named_exports" }` to force either mode.

`FusedGraphRunner.runBatch` is a **host loop** over `run()` (not a wasm `tick_batch` export).

v1 scope: `expr` graphs with multi **values** (Spec 07 full-value): number/boolean plus
matrix/complex/record/series on inputs, internal edges, and outputs. Opaque `wasm`
nodes are rejected (keep multi-module `GraphRunner` for those). Non-scalar **const**
nodes cannot be fused as f64 immediates — use an expr producer that builds the value.
Do **not** use `compile-graph` as the editor hot-reload path.

### Standalone limits for full-value fused graphs

| Mode | What works |
|------|------------|
| Default (env imports) | Full-value fuse with `AotHostEnv`: matrix/complex/record heap edges; series via shared host handles (`mathzig.abi` `series_repr=host_handle`) |
| `--standalone` | Only when every builtin used is in the standalone tier set. Matrix ops that have in-wasm bodies can work; host-only series/ODE/IO still hard-error. Series representation becomes `linear_memory`. Prefer env-import fused modules for mixed full-value product export. |

Host API: `FusedGraphRunner.run` writes non-scalar inputs once, runs `tick`, reads each out via `readWireValue`. Pure-number multi-out graphs may use `runBatch(inputLanes, n)`.

## 1. JavaScript (Node.js / Browser)
Standard WebAssembly imports map perfectly to the `Math` object.

```javascript
async function loadMathZigModule(path) {
    const wasmBuffer = await Bun.file(path).arrayBuffer();
    const imports = { 
        env: { 
            sin: Math.sin, cos: Math.cos, pow: Math.pow,
            exp: Math.exp, log: Math.log, sqrt: Math.sqrt
        } 
    };
    const { instance } = await WebAssembly.instantiate(wasmBuffer, imports);
    return instance.exports;
}
```

## 2. Python (using Wasmer)
```python
from wasmer import engine, Store, Module, Instance, ImportObject, Function
import math

# Map Python's math functions to WASM imports
imports = ImportObject()
imports.register("env", {
    "sin": Function(store, math.sin),
    "pow": Function(store, math.pow),
})
```

## 3. Rust (using Wasmtime)
```rust
use wasmtime::*;

linker.func_wrap("env", "sin", |x: f64| x.sin())?;
linker.func_wrap("env", "pow", |b: f64, e: f64| b.powf(e))?;
```

## 4. Unity / C#
- **WebGL:** Use a `.jslib` plugin.
- **Native:** Use `wasm2c` to transpile to C and compile with IL2CPP for maximum performance.
