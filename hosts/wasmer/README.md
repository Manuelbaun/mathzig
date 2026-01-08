# Wasmer

Run MathZig AOT modules with the [Wasmer](https://wasmer.io/) CLI.

## Install

```bash
# macOS
brew install wasmer

# or
curl https://get.wasmer.io -sSfL | sh
wasmer --version
```

## Run

From **repo root**:

```bash
./hosts/common/compile.sh
./hosts/wasmer/run.sh
```

Or from this directory:

```bash
../common/compile.sh
./run.sh
```

## What it does

1. Invokes pure modules (no host imports):

   ```bash
   wasmer run mul.wasm --invoke eval 3.0
   # → 6
   ```

2. Shows that modules with `env.*` imports **fail** without a host:

   ```bash
   wasmer run min.wasm --invoke eval 3.0 1.0
   # → unknown import env.min
   ```

3. Optional: `wasmer inspect` dumps exports/imports.

## Providing host imports

The plain CLI cannot wire MathZig’s `env` table. Use the Wasmer SDK (Rust/C/Python) to define:

```text
env.min(f64, f64) → f64
env.sin(f64) → f64
…
```

Same contract as the browser graph runtime’s `createDefaultScalarWasmImports()`.

## Tips

- Pure arithmetic / many ops compile with **no imports** → CLI is enough.
- Use `mathzig compile -s` / `--standalone` when you want fewer host imports (expr-dependent).
