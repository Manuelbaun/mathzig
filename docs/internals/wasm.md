# WebAssembly Integration

MathZig has two distinct WASM products:

| Artifact | How built | Role |
|----------|-----------|------|
| **Interpreter module** `mathzig_wasm.wasm` | `zig build -Dtarget=wasm32-freestanding` (also `zig build wasm`) | Full engine exported via C-ABI (`src/bindings/generated/exports.zig`) for browser console / `ts_wasm_vm` |
| **AOT modules** | `mathzig compile` / `mathzig compile-graph` | Freestanding expression, node, or fused-graph modules for hosts and `wasm_aot` parity |

Product UI: **`apps/console`** (loads interpreter WASM from `apps/console/public/`).  
`web/mathzig_wasm.wasm` may receive a copy from `zig build wasm`; it is **not** the product app.

Consumption of AOT modules: [`../guides/wasm_aot_usage.md`](../guides/wasm_aot_usage.md).  
Hosts: [`../../hosts/README.md`](../../hosts/README.md).

---

## Interpreter module build

### 1. Compile

```bash
export PATH="$PWD/tools/macos-sdk-shim:$PATH"   # macOS if needed
zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
# → zig-out/bin/mathzig_wasm.wasm
```

Convenience step that also copies under `web/`:

```bash
zig build wasm
```

For the console:

```bash
cp zig-out/bin/mathzig_wasm.wasm apps/console/public/
```

### 2. Optional post-process

```bash
bun tools/wasm/optimize_wasm.ts
```

Requires `wasm-strip` (wabt) and `wasm-opt` (binaryen) when used.

| Tool | Package | Purpose |
|------|---------|---------|
| `wasm-strip` | wabt | Strip debug / symbols |
| `wasm-opt` | binaryen | Size / speed opts |

---

## Interpreter architecture

- **Entry:** generated exports from `api_definition.zig` → `src/bindings/generated/exports.zig`
- **Target:** `wasm32-freestanding` (no WASI required for core logic)
- **Host:** browser via `apps/console`, or TS via `src/ts/mathzig_wasm.ts`
- **API:** `mathzig_*` C-ABI functions (create context, compile, evaluate, …)

```js
const { instance } = await WebAssembly.instantiate(bytes, { env: {} });
const exports = instance.exports;
// mathzig_create / compile / evaluate — see generated bindings
```

---

## AOT compiler backend

The AOT path (`src/wasm/compiler.zig`) lowers **bytecode** (not the source string alone) into a freestanding WASM module.

| Mode | CLI | Output |
|------|-----|--------|
| Expression | `mathzig compile -i … -o out.wasm` | `eval` (and helpers) |
| Node | `mathzig compile --node …` | Module + `.node.json` |
| Fused graph | `mathzig compile-graph -i graph.json -o out.wasm` | One module + `.graph.json` / `mathzig:graph` section |

- Default AOT may **import** `env.*` builtins (sin, exp, ODE, series, …).  
- `--standalone` hard-errors if a required host import is not in the standalone tier set.  
- Fuse v1: expr graphs with full multi-value ports; opaque pure-`wasm` nodes stay multi-module only.

### Stack machine notes

WASM is stack-based. The compiler parks values in scratch locals (`scratch_f*`, `scratch_i*`) when an op needs reorder or multi-use. Logical ops convert f64 truthiness via `f64.ne` / `i32.and` patterns before converting back to f64 where the DSL expects numbers.

### Memory

AOT modules use a linear heap pointer (`heap_ptr`) for matrices/records/etc. Full GC is not the product model for freestanding AOT; hosts may `reset_heap` / reload. Series may use **host handles** (env imports) or **linear_memory** under standalone tiers.

### Parity

Cross-backend correctness for AOT is enforced by `tests/parity` cases run through **`bun run mz`** (`wasm_aot` backend), not by the status table below alone.

| Category | Typical state | Notes |
|----------|---------------|-------|
| Arithmetic / compare | Implemented | f64 ops + host pow/mod when imported |
| Jumps / short-circuit | Implemented where bytecode emits jumps | Keep parity cases green as source of truth |
| Matrices / complex / records | Implemented (tier-dependent) | Wire via `src/wasm/abi.zig` |
| Units | Partial | Matrix elementwise conversion; honesty tasks under specs C4 |
| Series / ODE | Env-import or standalone tiers | Standalone hard-errors for unsupported builtins |
| User functions | Compiled as module functions | |
| Fused multi-out | `compile-graph` + `FusedGraphRunner` | Specs 01–08 complete |

For live limits, prefer parity JSON + `docs/guides/wasm_aot_usage.md` over this table.

---

## Related

- [`../guides/wasm_aot_usage.md`](../guides/wasm_aot_usage.md)  
- [`../guides/web_console.md`](../guides/web_console.md)  
- [`../archive/plans/compile-fuse/00_overview.md`](../archive/plans/compile-fuse/00_overview.md)
- [`build.md`](./build.md)  
