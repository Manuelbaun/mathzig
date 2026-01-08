# Host runtimes for MathZig AOT modules

These examples load **freestanding** MathZig AOT WASM (from `mathzig compile`), not the full REPL engine.

Each module typically exports:

| Export | Role |
|--------|------|
| `eval` | `f64… → f64` entrypoint |
| `memory` / `alloc` / `reset_heap` | present on some modules |

Optional imports: `env.<builtin>` (e.g. `env.min`) for the default env-import AOT path.

| Host | Folder | Pattern |
|------|--------|---------|
| [Wasmer](./wasmer/) | CLI invoke | `wasmer run module.wasm --invoke eval …` |
| [WasmEdge](./wasmedge/) | CLI / AOT | `wasmedge --reactor module.wasm eval …` |
| [Fermyon Spin](./spin/) | HTTP + wasmi | Spin component hosts AOT via wasmi |

## Prerequisites (all examples)

From the **repo root**:

```bash
# MathZig CLI (AOT compiler)
export PATH="$PWD/tools/macos-sdk-shim:$PATH"   # macOS if needed
zig build

# Confirm
./zig-out/bin/mathzig --help
```

Then open a host folder and follow its README.

## Shared compile helper

```bash
./hosts/common/compile.sh
```

Writes sample modules under `hosts/common/out/`:

- `mul.wasm` — `x * 2` (no imports)
- `min.wasm` — `min(x, y)` (imports `env.min`)
- `sum3.wasm` — `x * y + z` (no imports)
