# WasmEdge

Run MathZig AOT modules with [WasmEdge](https://wasmedge.org/).

## Install

```bash
# macOS
brew install wasmedge

# or official installer
curl -sSf https://raw.githubusercontent.com/WasmEdge/WasmEdge/master/utils/install.sh | bash
wasmedge --version
```

## Run

From **repo root**:

```bash
./hosts/common/compile.sh
./hosts/wasmedge/run.sh
```

## What it does

WasmEdge reactor mode calls an exported function by name:

```bash
wasmedge --reactor mul.wasm eval 3.0
# → 6
```

Same freestanding ABI as Wasmer:

- `eval` with `f64` args / result  
- optional `env.*` imports (must be registered via WasmEdge host APIs; bare CLI fails like Wasmer)

## Notes

- CLI flags differ slightly across WasmEdge versions; `run.sh` tries the common `--reactor` form and prints a hint if your build differs.
- For production host imports, use the WasmEdge C/Rust/Go SDK and register `env` functions the same way as in the Spin/wasmi example.
