# Build System

MathZig uses Zig’s native build system (`build.zig`) for native CLI/lib, freestanding interpreter WASM, TUI, tests, and maintainer tools. TypeScript apps under `apps/*` use Bun + Vite.

On macOS, if the system SDK resolution fails:

```bash
export PATH="$PWD/tools/macos-sdk-shim:$PATH"
```

---

## Primary outputs

| Command | Output | Role |
|---------|--------|------|
| `zig build` | `zig-out/bin/mathzig`, native lib | CLI REPL + `compile` / `compile-graph` / `graph` |
| `zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall` | `zig-out/bin/mathzig_wasm.wasm` | Interpreter WASM (console / `ts_wasm_vm`) |
| `zig build wasm` | WASM + copy under `web/` | Convenience install of interpreter module |
| `zig build repl` | runs CLI | Interactive REPL |
| `zig build run` | `mathzig_tui` | Terminal UI |
| `zig build test` | — | Full Zig test suite (includes vm-baseline) |
| `zig build vm-baseline` | — | Must-pass core VM gate |
| `zig build gen-bindings` | generated bindings | `api.json`, exports, `aot_abi.json`, TS |
| `zig build emit-fuse-goldens` | fuse goldens | Spec 03 fixtures for Bun tests |
| `zig build perf` / `benchmark` / `fuzz` | tools | Perf / TS bench / fuzzer (when enabled) |

Daily correctness + perf + progress is **not** a zig step — use:

```bash
bun run mz
```

---

## Common recipes

### Native CLI + library

```bash
zig build
zig build -Doptimize=ReleaseFast
./zig-out/bin/mathzig
./zig-out/bin/mathzig compile -i expr.mz -o out.wasm
./zig-out/bin/mathzig compile-graph -i graph.json -o out.wasm
```

### Interpreter WASM for console

```bash
zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
cp zig-out/bin/mathzig_wasm.wasm apps/console/public/
# optional optimize:
# bun tools/wasm/optimize_wasm.ts
```

### Tests

```bash
zig build vm-baseline --summary all
zig build test --summary all
bun run mz                 # full multi-backend pipeline
```

### Bindings codegen

```bash
zig build gen-bindings     # abi-inspect + exports + aot_abi + TS generate
```

Never hand-edit `src/bindings/generated/*`.

---

## Build graph (simplified)

```text
build.zig
├── native: mathzig CLI (src/main.zig)
├── native: shared/static lib from generated exports
├── freestanding: mathzig_wasm (src/bindings/generated/exports.zig)
├── native: mathzig_tui (src/tui)
├── steps: test, vm-baseline, gen-bindings, wasm, perf, fuzz, …
└── (TS) apps/console, apps/progress via Bun — outside zig
```

AOT **expression/graph** modules are produced by the **installed CLI** (`mathzig compile*`), not as separate `zig build` install artifacts.

---

## Optimize modes

| Mode | Use |
|------|-----|
| `Debug` | Dev / leak hunting |
| `ReleaseSafe` | Default-ish safety + speed |
| `ReleaseFast` | Peak native throughput |
| `ReleaseSmall` | Interpreter WASM size for the console |

---

## Related

- [`wasm.md`](./wasm.md) — interpreter vs AOT WASM  
- [`../COMMANDS.md`](../COMMANDS.md) — CLI surface  
- [`../guides/testing.md`](../guides/testing.md) — `mz` pipeline
- [`../../apps/console/README.md`](../../apps/console/README.md) — UI build  
