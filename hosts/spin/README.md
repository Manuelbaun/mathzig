# Fermyon Spin

MathZig AOT modules are **not** Spin HTTP components by themselves (they export `eval`, not `wasi:http/...`).

This example is a small **Rust Spin app** that:

1. Embeds sample AOT modules (`mul.wasm`, `min.wasm`)
2. Loads them with **[wasmi](https://github.com/wasmi-labs/wasmi)** inside the Spin guest
3. Exposes HTTP routes that call `eval`

```text
HTTP → Spin (wasi:http) → wasmi → MathZig AOT eval → JSON
```

## Prerequisites

```bash
# Spin CLI — https://spinframework.dev/install
spin --version    # tested with 4.x

# Rust + WASI target
rustup target add wasm32-wasip2
```

From repo root, ensure MathZig is built:

```bash
zig build
```

## Build & run

From **repo root**:

```bash
./hosts/spin/build.sh
./hosts/spin/run.sh
```

Or manually:

```bash
./hosts/common/compile.sh
cp hosts/common/out/mul.wasm hosts/common/out/min.wasm hosts/spin/wasm/
cd hosts/spin
spin build
spin up --listen 127.0.0.1:3458
```

## Try it

```bash
curl -s http://127.0.0.1:3458/
curl -s http://127.0.0.1:3458/info
curl -s 'http://127.0.0.1:3458/mul?x=3'      # → y: 6
curl -s 'http://127.0.0.1:3458/min?x=3&y=1'  # → r: 1  (env.min host import)
```

## What this proves

| Approach | Result |
|----------|--------|
| Point Spin at AOT `.wasm` alone | Fails (missing HTTP export) |
| Nested `WebAssembly` in Spin JS | Not available in Spin JS runtime |
| wasmi host inside Spin Rust component | **Works** (this example) |

## Layout

```text
spin.toml          Spin manifest
Cargo.toml         Rust + spin-sdk + wasmi
src/lib.rs         HTTP routes + wasmi loader
wasm/              Generated AOT modules (gitignored; from compile.sh)
build.sh / run.sh  Convenience scripts
```
