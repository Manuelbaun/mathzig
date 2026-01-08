# MathZig Console (`apps/console`)

SolidJS + Vite + Tailwind console for the MathZig WASM engine.

**This is the product UI.** The old `web/` folder (including `graph_demo.html`) is legacy and not maintained for product use.

## Routes

| Path | Purpose |
|------|---------|
| `/` | REPL console (eval, vars, plots, demos) |
| `/graph` | Graph editor (`GraphRunner` from `src/ts/graph`) |

## Develop

From repo root:

```bash
# 1) Interpreter WASM for the Console REPL
export PATH="$PWD/tools/macos-sdk-shim:$PATH"
zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
cp zig-out/bin/mathzig_wasm.wasm apps/console/public/

# 2) Native mathzig binary for Graph page AOT compile API
zig build

# 3) Console
bun install --cwd apps/console
bun run --cwd apps/console dev
```

Open:

- Console: http://localhost:5173/
- Graph:   http://localhost:5173/graph

### Graph page notes

Graph editor (Solid Flow / `@dschz/solid-flow`) on `/graph`. Workflow: **Example → Design → Validate → Compile mode → Compile → Run**.

- **Starter examples:** toolbar **Example** menu + File menu + ⌘K — basics through **simulations**. Lorenz / Rocket are **multi-node** graphs (const assignments → state vector → ODE → post-process), not one mega-expression. Named **graph outputs** appear as canvas `out_*` nodes and in the **Graph outputs** panel (trajectory matrices + scalars). Nested ODE helpers stay on the integrate node (AOT module isolation).
- **Canvas** authors an `EditorDocument` = `GraphDefinition` (runner IR) + `ui` layout. Default example is lowpass + gain.
- **Add nodes:** palette click, **drag onto canvas**, double-click empty canvas, or **⌘K** command menu.
- **Compile mode** (toolbar, before Compile):
  - **Modules** — one WASM per compute node (`GraphRunner` + `POST /api/aot_compile`). Default; supports opaque wasm nodes; per-node timings.
  - **Fused** — one WASM for the whole graph (`POST /api/compile_graph` → `FusedGraphRunner`). Faster hot path; unavailable when fuse lowerer rejects (e.g. wasm-only nodes).
- **Compile** validates, then loads the selected mode. Does **not** run automatically. Changing mode after compile marks the graph dirty until recompile.
- **Run** modes: once, on input/parameter change, continuously. Structural edits require recompile; parameters do not.
- Continuous validation: Problems panel, graph outline, inline node/port errors; compile disabled when blocking.
- **WASM nodes:** inspector file picker → data URL. Prefer `mathzig compile --node`. Multi-module only for opaque modules.
- **Edit:** undo/redo, multi-select, edge reconnect, align/distribute, auto-layout.
- **Import/Export** menu: optimized WASM download, graph file, executable definition, full document (+ advanced source panel).
- Tests: `bun test ./apps/console/src/engine/graph/` and `bun test ./apps/console/vite.aot_plugin.test.ts` from repo root.
- Browser path is **scalar-first** for execution; the editor models full port kinds / wasm for authoring.
- **Solid Flow patch:** `@dschz/solid-flow@0.1.4` mis-transforms connection rubber-band start
  (upstream #21). `postinstall` runs `scripts/patch-solid-flow.mjs`. Re-run after reinstall:
  `bun run --cwd apps/console patch:solid-flow`.

### Dual model: multi-module run vs optimized export

| Action | Shape |
|--------|--------|
| **Compile mode: Modules** | Multi-module `GraphRunner` — one WASM per compute node (default) |
| **Compile mode: Fused** | One fused module via `compile-graph` + `FusedGraphRunner` for Run |
| **Export optimized WASM** | Always fuse → downloadable `.wasm` + `.graph.json` (independent of Run mode) |

Export calls `POST /api/compile_graph` (Vite middleware in `vite.aot_plugin.ts`), which shells to:

```bash
zig-out/bin/mathzig compile-graph -i graph.json -o out.wasm
```

- Downloads **two files**: `*.wasm` then `*.graph.json` (short stagger so browsers that block multiple simultaneous downloads are less likely to drop the sidecar). Allow multiple downloads if prompted.
- Default fuse `outMode` is **`table`** (matches CLI). Params remain runtime args: moving sliders does **not** require re-export.
- Opaque **wasm** nodes (no expression) cannot be fused — export is disabled with a reason; multi-module Compile/Run still works.
- Export failures never block the multi-module editor path. Non-zero `compile-graph` exits map to HTTP **400**; missing binary / spawn failures map to **500**.
- Advanced: **Copy fuse plan** writes the pure lowerer plan JSON into the source panel.

**Note:** Console REPL `load` still means CSV/data import — unrelated to graph compile.

## Build

```bash
bun run --cwd apps/console build
bun run --cwd apps/console preview   # also serves /api/aot_compile and /api/compile_graph
```

## Architecture

- `src/engine/` — UI-free WASM runtime, plot parsing, demos, graph helpers
- `src/engine/graph/` — browser GraphRunner glue (compiler fetch, format, stubs, optimized export helpers)
- `src/state/session.ts` — Solid store + command dispatch
- `src/components/` — shell, REPL, panels, plots
- `src/pages/` — Console + Graph routes
- `vite.aot_plugin.ts` — AOT APIs: `/api/aot_compile` (per-expr) and `/api/compile_graph` (fused export)

Legacy vanilla console is archived at `docs/archive/web_console_legacy/`.
