# Spec 06 — Product export (editor stays multi-module)

**Depends on:** 04, 05  
**Unblocks:** user-facing “optimized module” story  
**Scope:** console / docs UX only; no change to interactive multi-module semantics

## Goal

Make the dual model explicit in product:

- **Compile graph** (editor) = multi-module prepare (existing)  
- **Export optimized WASM** = fuse → one module (new)

Aligns with `docs/graph_findings.md` §9.3.

## Todos

- [x] Console: action **Export optimized WASM** (download `.wasm` + optional `.graph.json`)
- [x] Wire to `compile-graph` via Vite middleware or existing AOT plugin pattern (`vite.aot_plugin.ts`)
- [x] UI copy: explain multi-module at runtime vs single-module export
- [x] Show module count after multi compile; after export show “1 fused module · N outputs”
- [x] Disable export when graph has unsupported nodes (`wasm` without expr, etc.) with reason
- [x] Optional: “Copy fuse plan / graph JSON” advanced
- [x] Docs snippet in `apps/console` README or web console guide

## Do NOTs

- Do **not** switch **Run / Tick** to fused-only without an explicit mode toggle (default remains multi-module).
- Do **not** force full re-fuse on every param slider move (params are runtime args).
- Do **not** use “Load” to mean export.
- Do **not** block editor work if fuse compile fails; multi-module path stays available.
- Do **not** expand scope into full visual redesign (see graph_findings for UX; only export entry here).

## Tests

| ID | Test | Expected |
|----|------|----------|
| T1 | API/middleware compile-graph with fixture | 200 + wasm bytes |
| T2 | Unsupported graph | 4xx + message listing reason |
| T3 | Manual/e2e smoke: export then `FusedGraphRunner` in bun | values ≡ editor multi run |
| T4 | Param change without re-export | multi path; export artifact still needs new run args not recompile for params |

```bash
# middleware / unit
bun test apps/console/...   # if present
# manual checklist in PR description
```

## Expected outcomes

- [x] User can download **one** wasm with multi input/output **values**  
- [x] Editor interactive path still one-node-one-module  
- [x] Vocabulary matches findings (export ≠ run)  

### Landed (2026-07-10)

| Surface | Path |
|---------|------|
| Middleware | `POST /api/compile_graph` in `apps/console/vite.aot_plugin.ts` → `mathzig compile-graph` |
| Response | JSON `{ wasmBase64, graphJson, meta }` |
| Client helpers | `apps/console/src/engine/graph/export_optimized.ts` |
| UI | Graph page toolbar + File menu **Export optimized WASM**; Runtime model panel |
| Tests | `apps/console/vite.aot_plugin.test.ts` (T1–T3), `export_optimized.test.ts` |
