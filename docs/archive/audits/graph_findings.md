# Graph editor — UX, nomenclature, and runtime findings

**Date:** 2026-07-10  
**Scope:** Product graph workbench at `apps/console` route `/graph` (Solid Flow editor + `GraphRunner`).  
**Method:** Read-only code trace, maintained docs, live browser checks on `http://localhost:5173/graph`.  
**Status:** Findings + P0/key-P1 implementation landed (2026-07-10). See §18.

**Product surface:** `apps/console` is the maintained UI (`apps/console/README.md:3-5`). Legacy `web/graph_demo.html` is not the product path.

**Related plan:** `docs/plans/wasm_node_graph/plan.md` (multi-module chained graph).

---

## Executive summary

The graph editor’s primary failure mode is **unclear product intent**, not only visual polish.

Today, one button — **Load** — combines validation, per-node AOT compilation, browser WASM instantiation, runtime setup, and **one immediate execution**. Users reasonably ask whether the graph becomes one WASM module or many, what “Load” means, and what “execute” does. The UI does not answer those questions consistently.

**Observed architecture:**

- The graph is **not** compiled into a single WASM module.
- Each **expression** node is compiled to its **own** WASM module; prebuilt **wasm** nodes are separate modules too.
- The browser **loads and runs** those modules via TypeScript `GraphRunner` (`src/ts/graph/runner.ts`).
- **Tick** / **Auto** are the user-facing “execute” actions; there is no **Execute** button on the graph page.

**Recommended product vocabulary:**

> **Design → Validate → Compile → Run**

Rename **Load** → **Compile graph**, **Tick** → **Run**, **Auto** → **Run continuously**, and reserve **Load** for importing files (graph JSON, `.wasm`, examples).

---

## 1. User workflow vs runtime (what changes require what)

| User action | Runtime effect |
|-------------|----------------|
| Change parameter | Update runtime parameter without recompiling |
| Change graph structure / expression | Mark runtime stale; requires compile again |
| Reset example | Restore example graph and dispose the previous runner |

**Param changes** call `runner.setParam` without recompile (`GraphPage.tsx:170-179`) — correct behavior, but not explained in UI.

**Stale / dirty semantics (observed):**

- Any canvas or inspector edit sets `dirty` (`GraphPage.tsx:86-90`, `onDocumentChange`).
- **Tick** / **Auto** disabled when `dirty()` (`GraphPage.tsx:289-297`).
- Error: “Graph changed since Load — click Load again.” (`GraphPage.tsx:158-160`).
- Status badge: “Dirty — re-Load” when ready but dirty (`GraphPage.tsx:274`).

---

## 2. Runtime semantics (observed)

### 2.1 Label map: what the UI says vs what happens

| UI term | On graph page? | Observed meaning |
|--------|----------------|------------------|
| **Build** | No button | Authoring copy only: “Build graphs on the canvas” (`GraphPage.tsx:259-263`). `bun run build` is the Vite app bundle, not graph compilation. |
| **Compile** | No button | Sub-status during Load: “Compiling…” (`GraphPage.tsx:118`). Actual compile: native `mathzig compile` via Vite middleware (`vite.aot_plugin.ts`), then `WebAssembly.compile` in browser (`compile_cache.ts:49-52`). |
| **Load** | Primary button | **Compound transaction:** stop Auto; `toRunner(doc)`; dispose prior runner; `GraphRunner.load` (validate, topo sort, compile each `expr`, resolve `wasm`, instantiate each compute node, build tick plan); seed inputs to `0`; list params; mark ready; **then `runner.run` once** and show outputs (`GraphPage.tsx:114-150`). |
| **Execute** | No | REPL shortcut only (`SidePanels.tsx:5-8`). Graph uses **Tick** / **Auto**. |
| **Tick** | Button | Single `runner.run({ ...inputValues })` if loaded and not dirty (`GraphPage.tsx:153-168`). |
| **Auto** | Checkbox | `setInterval` every `max(16, 100)` ms calling `runner.run` (`GraphPage.tsx:187-201`). |

**Inference:** “Load” reads like opening a file or bringing an artifact into memory; it actually means **prepare runtime and run once**.

### 2.2 One graph module vs many node modules

**Observed: many modules, one orchestrator.**

```text
EditorDocument  →  GraphDefinition  →  GraphRunner (TypeScript)
                         │
         ┌───────────────┼───────────────┐
         ▼               ▼               ▼
   expr node A      expr node B     wasm node C
         │               │               │
         ▼               ▼               ▼
   POST /api/aot_compile (per expr)
         │               │
         ▼               ▼
   mathzig compile   mathzig compile
         │               │
         ▼               ▼
   WASM module A     WASM module B     WASM bytes C
         │               │               │
         ▼               ▼               ▼
   WebAssembly.Instance (one per compute node)
         └───────────────┴───────────────┘
                    eval() per topo step
```

Evidence:

- Per-`expr` compile + instantiate: `src/ts/graph/runner.ts:209-250`.
- Per-`wasm` compile/instantiate: `runner.ts:253-332`.
- In-memory module cache key: compiler `version` + expr + arity (`compile_cache.ts:33-67`, `vite.aot_plugin.ts:41-42`).
- Plan explicitly targets chained modules: `docs/plans/wasm_node_graph/plan.md:1-6,45-51`.

**Live check (example graph):** Reset example → **Load** produced two HTTP 200 responses:

- `/api/aot_compile?params=3` (e.g. `lowpass`)
- `/api/aot_compile?params=2` (e.g. `gain`)

Default graph definition: `apps/console/src/engine/graph/example.ts` (`lowpass`, `gain`, `source`, `prev`).

### 2.3 Where artifacts live

| Stage | Location |
|-------|----------|
| Dev compile cache (disk) | `tests/artifacts/wasm_aot_console/{sha1}.mz` / `.wasm` (`vite.aot_plugin.ts`) |
| Browser module cache | In-memory `Map` in `compile_cache.ts` (global for session) |
| Runtime instances | Held on `GraphRunner` until `dispose()` |

Compile command shape: `zig-out/bin/mathzig compile -i <cache>.mz -o <cache>.wasm` with optional `-p <n>` (`vite.aot_plugin.ts:60-61`). Binary path: `MATHZIG_BIN` or `zig-out/bin/mathzig` (`vite.aot_plugin.ts:19-22`).

### 2.4 Execution protocol (per tick / run)

When the user runs the graph, TypeScript `GraphRunner`:

1. Receives the current graph input values.
2. Processes nodes in topological order.
3. Supplies constants and graph inputs.
4. Invokes each expression/WASM node’s `eval` export.
5. Transfers each output to connected downstream inputs.
6. Collects named graph outputs.
7. Displays them in the Outputs panel.

Host-mediated edges (not shared imported memory by default): `reset_heap()` when exported; non-scalar inputs via `value_transfer.ts`; scalar fast path via dense `Float64Array` slots (`runner.ts:340-361`, tick plan ~`runner.ts:96-145`).

### 2.5 Editor document vs runner IR

| Concept | Type | Notes |
|---------|------|--------|
| Canvas + layout | `EditorDocument` | `{ definition, ui }` — positions, viewport, editor-only output nodes |
| Execution IR | `GraphDefinition` | Nodes, edges `from`/`to`, named `outputs` (`schema.ts`) |
| Export full doc | `exportDocument` | Definition + UI (`editor_adapter.ts`) |
| Export runnable only | `exportRunnerJson` | Normalized definition only |

Output **canvas** nodes are not runtime nodes; they map to `outputs` in the definition (`editor_adapter.ts`, `editor_layout.ts`).

**Quirk:** If runtime `outputs` is empty after normalize, schema can default to exposing every node (`schema.ts:83-100`). Unwired output nodes may be omitted at adapter layer with comment “Load will surface” (`editor_adapter.ts:302-313`).

### 2.6 WASM node import (broken / mismatched promise)

**UI:** Inspector label `wasm URL / data URL` (`GraphInspector.tsx:220-228`).

**Runtime:** `resolveWasmBytes` treats string refs as **Node filesystem paths** via dynamic `node:fs` (`runner.ts` ~1057-1063). Browser serialization to data URLs is not a supported end-to-end path in the product UI.

Node chrome shows `no manifest` when manifest missing (`MzNodes.tsx:173-175`) — opaque vs actionable guidance.

### 2.7 Browser inputs vs schema richness

- Run panel: numeric sliders only for graph inputs (`GraphPage.tsx:347-380`), seeded to `0` on load (`GraphPage.tsx:92-103`).
- Editor supports many **port kinds** (matrix, series, etc.) but product browser path is **scalar-first** (`apps/console/README.md:47`).

---

## 3. Why “Load” is confusing

User-facing descriptions contradict one another:

- “Load to compile”
- “Load to compile & run”
- “Load to run”
- “Loading…”
- “Compiling…”
- “Ready”
- “Load failed”
- “Dirty — re-Load”

Sources: `GraphPage.tsx`, `GraphCanvas.tsx` (see nomenclature inventory §5).

The term **Load** currently means several things depending on context:

- Compile source.
- Load WASM bytes.
- Instantiate WASM.
- Build the execution plan.
- Initialize runtime parameters.
- Execute once.

One action should have one predictable intent.

**Product collision — two unrelated meanings of “load”:**

1. **Import a CSV file** — Console REPL: `autocomplete_catalog.ts:27-30`, `ExprEditor.tsx:61-63` placeholder “load…”.
2. **Compile, instantiate, and execute a graph** — graph primary button.

---

## 4. Recommended terminology

### 4.1 Vocabulary replacement table

| Current | Recommended | Reason |
|---------|-------------|--------|
| Visual workbench | **Graph editor** | Direct and recognizable |
| Load (primary) | **Compile graph** | Dominant user intent |
| Loading… | **Compiling graph…** | Describes actual work |
| Load failed | **Compilation failed** / **Graph invalid** / **Runtime initialization failed** | Preserve failure stage |
| Tick | **Run once** / **Run** | “Tick” only fits time-stepped simulations |
| Auto | **Run continuously** | States the behavior |
| Dirty — re-Load | **Changes not compiled** | Standard dev-tool vocabulary |
| Ready | **Compiled, ready to run** | Identifies what is ready |
| Run inputs | **Inputs** | “Run inputs” is not established terminology |
| Params | **Parameters** | Avoid abbreviation in primary UI |
| Expr | **Expression** | Clearer for mixed audiences |
| Const | **Constant** | Same |
| Wasm | **WASM module** | Names the artifact |
| JSON (panel) | **Graph source** | Content over format |
| Apply JSON → canvas | **Import graph source** | Action-oriented |
| Export runner JSON | **Export executable graph** | “Runner” is internal |
| Reset example | **Restore example** | Shorter, same intent |
| Port kind | **Value type** | “Kind” is implementation language |
| in / out | **Named input/output ports** | Use names where available |
| wasm URL / data URL | **Import WASM file** | Until URL path works |

### 4.2 Keep “Load” only for artifacts

Reasonable uses:

- Load graph file
- Load WASM file
- Load example
- Load saved project

**Not** for compilation or execution.

---

## 5. Nomenclature inventory (current strings)

### 5.1 Actions and status

| Location | Strings |
|----------|---------|
| `GraphPage.tsx` | Load, Loading…, Tick, Auto, Reset example, Export runner JSON, JSON, Hide JSON, Apply JSON → canvas, Compiling…, Ready, Load failed, Dirty — re-Load, Edit graph · Load to compile, Example restored — Load to run, Imported JSON — Load to run, Load the graph first., Graph changed since Load — click Load again. |
| `GraphCanvas.tsx` | Edit on canvas · Load to compile & run, Updated …, Wire … → …, Selected …, `N nodes · M edges`, connect errors |
| `GraphPalette.tsx` | + Input/Const/Expr/Wasm/Output, tooltip Add {label} node |
| `Header.tsx` | Nav: Console, Graph |

### 5.2 Node chrome (`MzNodes.tsx`)

Headers: `input`, `const`, `expr`, `wasm`, `output` (lowercase). Ports: `in`, `out`, `name:kind`. Wasm: `base64 wasm`, `no manifest`.

### 5.3 Inspector (`GraphInspector.tsx`)

Inspector, Select a node on the canvas., name, kind, value (JSON), expr, Input ports, + Add input, params (k=v, …), output kind, wasm URL / data URL, manifest JSON (advanced), output name.

### 5.4 Cross-surface conflicts

| Term | Graph | Console REPL |
|------|-------|----------------|
| Run / Execute | Tick (no Execute) | Run button; shortcut label Execute |
| Load | Compile graph | CSV import command `load` |

---

## 6. Recommended runtime state model

The interface needs an explicit state machine. Today users infer state from “Ready,” “Dirty,” disabled buttons, and distant errors.

### 6.1 States (logical)

```text
Draft → (Validate) → Invalid | Compiling → CompileFailed | Ready
Ready → Running → Ready | RuntimeFailed
Ready → Stale (structural/expr edit) → Compiling
Ready → Ready (runtime input change; parameter change without recompile)
```

### 6.2 State-specific UI

**Draft**

- Status: *Graph has not been compiled*
- Primary: **Compile graph**
- Summary: *6 nodes, 5 connections, 2 expression modules*

**Invalid**

- Status: *2 graph issues*
- Problems **inline** on nodes/ports **and** in a compact Problems panel.
- Prefer: *Connect a Number value to expr_1.x.*
- Not: *Expr node 'expr_1' input 'x' is not connected.* (internal naming without visual location)

**Compiling**

- *Compiling module 1 of 2: lowpass*
- *Compiling module 2 of 2: gain*
- *Instantiating graph runtime*

Answers whether one or multiple modules are compiled.

**Ready**

- *Compiled: 2 WASM modules loaded in this browser*
- Actions: Run, Run continuously, Recompile when needed, optional Download artifacts

**Stale**

- *Graph changed since compilation*
- Primary: **Recompile graph**
- Run controls disabled with explanation **next to** controls, not only a distant badge.

**Runtime error**

- Separate from compile errors: *Run failed in gain: expected a finite number from lowpass.out.*
- Today `GraphPage.tsx:138-147` collapses validation, compile, instantiate, and initial-run into generic **Load failed** — destroys diagnostic context.

### 6.3 Implicit run on compile

Current **Load** also runs once (`GraphPage.tsx:126-137`). Prefer separate **Compile** and **Run**, or label explicitly **Compile and run**.

### 6.4 Compilation summary copy

> This graph will compile **2** math expressions into **2** WASM modules and load **2** runtime instances in this browser. Existing WASM nodes are loaded separately.

---

## 7. Major interaction problems

### 7.1 P0 — Canvas initially renders empty

**Repro (live):** Large empty canvas; default example exists in state. Adding one Expression node revealed six existing nodes plus the new node.

**Cause:**

```tsx
<Show when={canvasKey()} keyed>
```

```ts
const [canvasKey, setCanvasKey] = createSignal(0);
```

`0` is falsy → canvas not mounted (`GraphPage.tsx:39-42`, `315-327`).

**Impact:** Status implies editable graph; **Load** operates on hidden document; first paint is deceptive.

**Recommendation:** Fix before visual polish — render initial graph or intentional guided empty state; no hidden graph behind empty canvas.

### 7.2 P0 — New nodes at arbitrary coordinates

```ts
x: 80 + (nodes.length % 4) * 40,
y: 80 + nodes.length * 24,
```

(`GraphCanvas.tsx:320-331`). Nodes ≥148×72 (`theme.css:48-52`). Overlap likely; ignores viewport, cursor, zoom, pan.

**Better placement:**

1. Drag from palette to canvas (drop at intent).
2. Double-click canvas → searchable node menu at pointer.
3. Keyboard → command menu at viewport center.

Toolbar adds: viewport center + collision-aware offset. After add: select node, focus key field, pan to reveal, Escape to undo accidental add.

### 7.3 P0 — Unwired expr breaks compile without guidance

Default expr: `expr: "x"`, `inputs: ["x"]` (`GraphCanvas.tsx:252-263`). **Load** → `Expr node 'expr_1' input 'x' is not connected.` (live repro).

Compile still offered; no node/port error; “Load failed” suggests file load failure.

**Recommendation:** Continuous validation; disable compile when statically invalid; visible required-port affordances.

### 7.4 P1 — Connections hard to understand

- Handles 10×10 px (`theme.css:112-121`); `connectionRadius={24}` (`GraphCanvas.tsx:190`).
- A11y: every handle named **Handle**.
- No edge labels; delete via Backspace/Delete undocumented; no reconnect; no “drag connection here” empty affordance.

**Recommended behavior:**

- Visible port 14–16 px; interaction target 28–32 px.
- Accessible names: *lowpass, input x, number* / *gain, output, number*
- On drag: dim incompatible, highlight compatible, show type at cursor; invalid hover shows reason before release.
- Edge click: source, destination, type, delete; endpoint drag to reconnect.
- Drop on empty canvas → filtered node picker (*Add a number-compatible node*).
- Distinguish required / connected / optional / type mismatch.

### 7.5 P1 — Palette mixes roles

Flat: Input, Const, Expr, Wasm, Output — mixes **interface** (input/output), **computation** (expression, WASM), **values** (constant).

**Recommended:** Add-node menu with categories; each item explains runtime meaning (e.g. *Math expression: compiled into its own WASM module*).

### 7.6 P1 — Inspector implementation jargon

Examples: `expr`, `params (k=v, …)`, `kind`, `manifest JSON (advanced)`, `wasm URL / data URL`, `{id} · {mzType}` (`GraphInspector.tsx`).

Separate stable **parameters** (change without recompile) from **input ports**; avoid fragile `k=v` as primary control.

### 7.7 P1 — Tick / Auto vs graph model

**Tick** implies simulation clock; default graph is stateless — Auto at 100 ms repeats same result.

**Auto** ambiguous (auto-compile? auto-run?).

Prefer **Run** / **Run continuously**, or **Re-run when inputs or parameters change**. If continuous execution stays, show frequency, run count, last duration, reason.

### 7.8 P1 — Outputs disconnected from execution

No timestamp, duration, run number, stale state, per-output source, change indication.

After edit, mark stale or clear:

```text
Results from previous compilation
Recompile the graph to update them.
```

Recommended header: `Run 14 · 0.42 ms · inputs changed 2 s ago`

### 7.9 P2 — Identity copy fragmentation

“Node graph”, “Visual workbench”, “Solid Flow”, “GraphRunner”, “AOT” in hero (`GraphPage.tsx:255-262`). Conflicts with `PRODUCT.md` / `DESIGN.md` directness.

---

## 8. Existing WASM node problem

UI promises `wasm URL / data URL`; runtime string path ≈ Node `fs` — not reliable browser URL/data-URL loading.

**Near-term:**

- Rename to **External WASM module**.
- No free-form URL field until both forms work.
- Prefer file picker → read bytes in browser → parse manifest → show ports → compatibility errors before add.

Example failure copy:

> This module does not expose MathZig graph metadata. Compile it with `mathzig compile --node`, or provide a compatible manifest.

Better than *no manifest* alone.

---

## 9. One graph module vs multiple node modules (product choice)

### 9.1 Current model: multiple modules

**Advantages:** Per-expr recompile/cache; params without recompile; compose existing WASM; visible boundaries match modules.

**Costs:** Host value transfer; multiple instances/memories; JS orchestration; non-scalar copy/encode; per-node errors/perf attribution.

### 9.2 Alternative: whole graph → one module

**Advantages:** Cross-node optimization; fewer instances; less host transfer; single artifact; potentially faster.

**Costs:** Any edit recompiles whole graph; harder third-party composition; node boundaries ≠ module boundaries; incremental compile harder.

### 9.3 Recommendation

**Keep multi-module** for the editor (compositional intent). Make it explicit in UI (module count, progress, post-compile summary).

Optional future export (only when implemented):

```text
Export
  Graph package          JSON + individual WASM modules
  Optimized WASM module  Compile the complete graph as one module
```

---

## 10. Recommended editor layout

```text
┌─────────────────────────────────────────────────────────────────┐
│ Graph editor    [status: Changes not compiled]   [Compile graph] │
├──────────┬────────────────────────────────────┬─────────────────┤
│ Add node │           Canvas                    │ Inspector       │
│ (grouped)│                                    │                 │
├──────────┴────────────────────────────────────┴─────────────────┤
│ Run: [Run] [Run continuously]  Inputs | Parameters | Results    │
│ Compiled: N modules · Last run: X ms                            │
└─────────────────────────────────────────────────────────────────┘
```

- Left: what can I add?
- Center: how is it connected?
- Right: what is selected?
- Bottom: how do I execute and what happened?
- Top: is the visible graph compiled?

Move raw JSON to **Advanced → Graph source**; primary toolbar = compile/run/reset/import/export, not IR names.

---

## 11. First-run and empty-state experience

Replace implementation-heavy hero:

> Build graphs on the canvas (Solid Flow). Load compiles expr nodes via AOT and runs them with GraphRunner.

With:

> Connect inputs to expression nodes, compile the graph, then run it in your browser.

Example graph:

> This example compiles lowpass and gain into two WASM modules. Change the input or parameters, then run the graph.

Genuinely empty graph: guided template or explicit “start from blank” — not an unexplained empty canvas.

---

## 12. Accessibility findings (observed live)

- Graph handles: buttons named only **Handle**.
- Relationships not semantic in a11y tree.
- Heavy mouse dependency; Backspace/Delete delete not communicated.
- Port compatibility largely by color (`theme.css:129-150`).
- Icon controls rely on `title` attributes.

**Required:**

- Node labels: *Expression node lowpass*
- Port labels: *Input x, number, connected from source*
- Keyboard connect: select source port → choose destination → confirm
- Accessible graph outline / edge list
- Text type labels; do not rely on color alone
- Remove controls: *Remove input port x*
- Focus-visible on nodes, edges, handles, toolbar, inspector

---

## 13. Implementation priority

### P0 — Correctness and intent

1. Fix initial blank-canvas (`canvasKey` / `Show when`).
2. Rename Load → Compile graph; Tick → Run; Auto → Run continuously (or remove until time-step graphs exist).
3. Split errors: graph invalid / compilation failed / instantiation failed / run failed.
4. Continuous validation + inline node/port errors.
5. WASM import: browser file loading or remove unsupported wording.
6. Do not run implicitly on compile, or name **Compile and run**; prefer separate Compile and Run.

### P1 — Core editor handling

1. Pointer-aware placement; drag-to-canvas; double-click insert; collision avoidance.
2. Select/focus new nodes; larger port targets; connect preview; compatible/incompatible highlights.
3. Edge select, delete, reconnect; undo/redo; multi-select; align/distribute; auto-layout.
4. Inspector copy pass (§4).
5. Module count, per-module compile progress, last run duration, stale results.
6. Explain: each expression node → own WASM module; parameters change without recompile.

### P2 — Product maturity

1. Searchable palette / command menu; Problems panel; graph outline.
2. Import/export menus (document + layout, executable graph, WASM package).
3. Per-node profiling; whole-graph export mode only when implemented.
4. Execution modes: run once, run on input change, run continuously, simulation tick (stateful graphs only).

---

## 14. Proposed final copy (reference strings)

**Header:** Graph editor — *Connect values and computations, compile the graph to WASM, then run it in this browser.*

**Before compile:** *Not compiled · 2 expression nodes → 2 WASM modules* · **Compile graph**

**Progress:** *Compiling lowpass · module 1 of 2*

**Success:** *Compiled · 2 WASM modules loaded in this browser* — Run · Run continuously · Recompile after edits

**Stale:** *Changes not compiled*

**Validation:** *1 required connection is missing* — *Connect a Number value to expr_1.x.*

**WASM import:** *Import WASM module* — *Choose a MathZig-compatible .wasm file. Its node manifest defines inputs, parameters, and output.*

---

## 15. Direct answers (FAQ)

| Question | Answer |
|----------|--------|
| What does **Compile graph** mean? | Validate graph, compile each expr (and wasm) node to WASM, instantiate modules in the browser, init inputs/params. Does **not** run automatically. |
| What does **Run** do? | `GraphRunner.run` / `runProfiled`: topo order, constants/inputs, `eval` per compute node, wire outputs, collect named outputs; shows results + optional per-node timings. |
| One WASM module for whole graph? | **No.** |
| Multiple modules? | **Yes** — one per expr compile + per wasm node. |
| Loaded in frontend? | **Yes** — `WebAssembly.Module` / `Instance` in browser. |
| Can frontend run it? | **Yes** — Run, Run continuously, Run on input change. |
| What should UX say? | *Each Math Expression node is compiled into its own WASM module. The modules are loaded into this browser and connected by the graph runtime. Compile after changing the graph, then Run with the current inputs.* |

---

## 16. Key source files (audit index)

| Area | Path |
|------|------|
| Page / Load-Tick-Auto | `apps/console/src/pages/GraphPage.tsx` |
| Canvas / placement / connect | `apps/console/src/components/graph/GraphCanvas.tsx` |
| Palette | `apps/console/src/components/graph/GraphPalette.tsx` |
| Inspector | `apps/console/src/components/graph/GraphInspector.tsx` |
| Node views | `apps/console/src/components/graph/nodes/MzNodes.tsx` |
| Theme / handles | `apps/console/src/components/graph/theme.css` |
| Adapter / export | `apps/console/src/engine/graph/editor_adapter.ts` |
| Example graph | `apps/console/src/engine/graph/example.ts` |
| Browser AOT fetch | `apps/console/src/engine/graph/compiler.ts` |
| Vite compile API | `apps/console/vite.aot_plugin.ts` |
| Runner / instantiate | `src/ts/graph/runner.ts` |
| Compile cache | `src/ts/graph/compile_cache.ts` |
| Schema | `src/ts/graph/schema.ts` |
| Console README | `apps/console/README.md` |
| Architecture plan | `docs/plans/wasm_node_graph/plan.md` |

---

## 17. Verification notes

- Code read + `GraphRuntimeTrace` / `GraphCopyAudit` task outputs (2026-07-10). `GraphUXAudit` did not complete (usage limit).
- Live: `bun run dev` in `apps/console`, `/graph` — empty initial canvas, unwired expr error, reset+load with 2× `/api/aot_compile`, inputs/params/outputs populated.
- Findings doc only — parity/full test gates not run.

---

## 18. Acceptance criteria

Implementation status (2026-07-10, full P1/P2 pass):

### P0 / original acceptance
- [x] Default example visible on first load.
- [x] **Compile graph** + separate **Run**; compile does not run implicitly.
- [x] Compile/run/stale vocabulary; REPL `load` unchanged for CSV.
- [x] Pre-compile module count; per-module compile progress via `GraphRunner.load({ onProgress })`.
- [x] Continuous validation + Problems panel; compile disabled when blocking; inline node/port errors.
- [x] WASM UI: browser file picker + data URL; `resolveWasmBytes` supports data/http(s).
- [x] Tick → **Run**; continuous / on-change run modes.
- [x] Outputs marked stale after dirty; run count + duration + per-node timing.
- [x] Descriptive a11y names on ports/nodes.
- [x] `apps/console/README.md` graph section updated.

### P1 editor handling
- [x] Drag-from-palette drop on canvas; double-click insert menu; collision-aware placement; focus new node.
- [x] Compatible/incompatible port highlight while connecting; required-port affordances.
- [x] Edge select, delete, reconnect (`reconnectable` edges).
- [x] Undo/redo (⌘Z / ⌘⇧Z); multi-select (Shift / ⌘); align / distribute / auto-layout.
- [x] Inspector copy + structured parameters UI.

### P2 product maturity
- [x] Searchable command menu (⌘K); Problems + graph outline docks.
- [x] Import/export menus (file, executable graph, full document, source panel).
- [x] Per-node profiling (`runProfiled`); execution modes: once / on change / continuous.
- [ ] Whole-graph single-module export — still out of scope (architecture unchanged).

---

## 19. Out of scope

- Implementing fixes in code (this document).
- Changing `GraphRunner` multi-module architecture.
- Whole-graph single-module compilation (until product implements it).
- Parity / Zig test protocol (`specs/README.md`).

---

*End of findings.*