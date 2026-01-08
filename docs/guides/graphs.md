# Graphs — multi-module, fused, and VM-native

Product model for node graphs. Capability context: [`capabilities.md`](./capabilities.md).  
AOT consumption: [`wasm_aot_usage.md`](./wasm_aot_usage.md). Console: [`web_console.md`](./web_console.md).

---

## Why graphs exist

Users compose simulations and pipelines (rocket, Lorenz, indicator chains) as **nodes + edges**, not one giant expression. MathZig supports that without abandoning the expression engine: each compute node is still an expression (or future opaque wasm), compiled with the same IR.

---

## Three runtimes

```text
GraphDefinition (JSON / editor)
        │
        ├──► GraphRunner (TS)     multi-module WASM, host-mediated edges   [editor]
        ├──► FusedGraphRunner     one WASM, internal edges, tick(...)      [export]
        └──► mathzig graph run    VM-native evaluator                      [CLI / tests]
```

| Runtime | Load `.wasm`? | Best for |
|---------|---------------|----------|
| **Multi-module `GraphRunner`** | Yes, per node | Edit, reload one node, setParam without full recompile |
| **Fused `FusedGraphRunner`** | Yes, one module | Shipped artifact, long chains, fewer host hops |
| **VM-native** | No | Fast correctness oracle, CLI, no wasm toolchain |

Goldens under `tests/graph/goldens/` exercise multi + native_vm + zig_vm oracle. `native_wasm` (pure interpreter of node modules inside Zig) is **phase-2** and expected skip.

---

## Multi-module (editor)

**How**

1. Validate / topo-sort (`src/graph/schema.zig`, `src/ts/graph/topo.ts`)
2. Compile each `expr` node → wasm (console via `/api/aot_compile`)
3. `GraphRunner.load` wires ports; each tick: write inputs → `eval` → read outputs → copy to consumers
4. **Tick plan** optimizes hot path: dense slots, hoisted calls, arity specialization, scalar `Float64Array` lanes
5. **`runBatch`** for pure-scalar lanes (zero per-tick alloc); non-scalar edges stay host-mediated

**Why host-mediated edges**

Non-scalar values (matrix, series, record) need a defined wire protocol and heap ownership. Copying through the host is correct and simple; shared memory was measured not worth it for current matrix-heavy gains (&lt;2×).

**Params**

Runtime ports (`setParam`) change without recompile; structural edits require recompile.

---

## Fused (export)

**How**

```bash
./zig-out/bin/mathzig compile-graph -i graph.json -o out.wasm
# out.wasm + out.graph.json  (mathzig:graph section)
```

1. Lower graph → fuse plan (`src/graph/fuse.zig`)
2. Emit one module with multi in/out values + `tick`
3. Manifest custom section + JSON sidecar
4. TS: `FusedGraphRunner.load` / `compileFused`

**Constraints (v1)**

- `expr` nodes only (no opaque pure-`wasm` nodes)
- Full-value ports: number/boolean + matrix/complex/record/series
- Free vars must be declared ports
- Not the editor hot-reload path

**Why fuse**

Long scalar chains pay multi-module host overhead every edge. Fuse keeps edges inside wasm; measured large speedups on long chains (see fuse plan results under `docs/archive/plans/compile-fuse/` and graph tick baseline).

---

## VM-native

**How:** `mathzig graph run graph.json` — evaluator in `src/graph/runner.zig` / `engine.zig` uses the Zig VM in-process.

**Why:** correctness without wasm compile; goldens `native_vm`; mislabeled historically as “native wasm runner” — it does **not** load `.wasm`.

---

## Console UX

`apps/console` `/graph`:

1. Example → design → validate  
2. Compile mode: **Modules** (default) or **Fused** for run  
3. **Export optimized WASM** always fuses (download `.wasm` + `.graph.json`)

Middleware: `apps/console/vite.aot_plugin.ts` shells to `zig-out/bin/mathzig`.

---

## Verify

```bash
bun run mz                 # includes graph-related tests in suite
# goldens live under tests/graph/
bun tools/bench/graph_tick.ts --help
```

Tripwire (full mz): compares multi-runtime ns/tick to [`docs/reference/graph_tick_baseline.md`](../reference/graph_tick_baseline.md).
