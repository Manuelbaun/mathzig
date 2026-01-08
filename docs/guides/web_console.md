# Web Console & Graph Editor

**Product UI lives in `apps/console`** (SolidJS + Vite + Tailwind).

The old vanilla page under `web/` is **not** the product surface. Prefer `apps/console`. `web/mathzig_wasm.wasm` may still receive a build copy from `zig build wasm`; the console loads WASM from `apps/console/public/`.

Full develop notes: [`apps/console/README.md`](../../apps/console/README.md).  
Design tokens / product intent: [`DESIGN.md`](../../DESIGN.md), [`PRODUCT.md`](../../PRODUCT.md).

---

## Routes

| Path | Purpose |
|------|---------|
| `/` | REPL console — eval, variables, plots, demos |
| `/graph` | Graph editor (`GraphRunner` / fused compile) |

---

## Develop

From repo root:

```bash
# 1) Interpreter WASM for the Console REPL
export PATH="$PWD/tools/macos-sdk-shim:$PATH"   # macOS if needed
zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
cp zig-out/bin/mathzig_wasm.wasm apps/console/public/

# 2) Native mathzig binary for Graph page AOT compile API
zig build

# 3) Console app
bun install --cwd apps/console
bun run --cwd apps/console dev
```

- Console: http://localhost:5173/
- Graph: http://localhost:5173/graph

### Build / preview

```bash
bun run --cwd apps/console build
bun run --cwd apps/console preview   # also serves /api/aot_compile and /api/compile_graph
```

---

## Console usage

- Type expressions and press **Enter**.
- **Up/Down** cycle input history.
- Variables panel lists live values; click a variable for inspector (matrix / series).
- Quick-ref / examples insert expressions into the prompt.
- Plotting uses uPlot / Plotly loaders as needed (on-demand).

Typical REPL-oriented commands (engine demos may register more):

```text
help      Command / syntax hints
clear     Clear output
sample    Demo series
load      CSV → series (timestamp,value)
rocket    Falcon 9 trajectory demo (console)
plot(...) Plot series / matrix / arrays
```

Exact command set is defined by the console session/engine code under `apps/console/src/`.

---

## Graph editor (`/graph`)

Workflow: **Example → Design → Validate → Compile mode → Compile → Run**.

| Compile mode | Meaning |
|--------------|---------|
| **Modules** (default) | One WASM per compute node via `GraphRunner` + `POST /api/aot_compile` |
| **Fused** | One WASM for the whole graph via `POST /api/compile_graph` → `FusedGraphRunner` |

- **Export optimized WASM** always fuses (download `.wasm` + `.graph.json`), independent of Run mode.
- Opaque pure-`wasm` nodes cannot be fused — stay on multi-module.
- Structural edits require recompile; parameters can change without recompile when they are runtime ports.

AOT middleware: `apps/console/vite.aot_plugin.ts` shells out to:

```bash
zig-out/bin/mathzig compile …          # per node / expression
zig-out/bin/mathzig compile-graph …    # fused export
```

CLI details: [`../COMMANDS.md`](../COMMANDS.md). AOT consumption: [`wasm_aot_usage.md`](./wasm_aot_usage.md).

---

## Architecture (console app)

```text
apps/console/
  src/engine/          UI-free WASM runtime, plots, demos, graph helpers
  src/engine/graph/    GraphRunner glue, fuse export helpers
  src/state/session.ts Solid store + command dispatch
  src/components/      Shell, REPL, panels, plots
  src/pages/           Console + Graph routes
  vite.aot_plugin.ts   /api/aot_compile, /api/compile_graph
```

Engine TS used by the graph path also lives in `src/ts/graph/` (shared with tests).

---

## Troubleshooting

| Symptom | Check |
|---------|--------|
| WASM fetch fails | Built freestanding wasm and copied to `apps/console/public/mathzig_wasm.wasm` |
| Graph Compile 500 | `zig build` produced `zig-out/bin/mathzig`; Vite plugin can spawn it |
| Graph Compile 400 | Graph rejected by fuse lowerer / validate (opaque wasm, free vars, …) |
| Solid Flow rubber-band glitch | `bun run --cwd apps/console patch:solid-flow` (postinstall usually runs it) |

---

## Related

- [`apps/console/README.md`](../../apps/console/README.md) — authoritative develop/build notes  
- [`graphs.md`](./graphs.md) — multi-module / fused / VM-native model  
- [`../../hosts/README.md`](../../hosts/README.md) — running freestanding AOT outside the console  
