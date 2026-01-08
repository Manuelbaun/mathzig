# Decisions (frozen)

## Engine & correctness

- **Zig VM is the source of truth.** Cross-backend behavior must match it on shared parity cases.
- **Parity backends:** `zig_vm`, `ts_ffi`, `ts_wasm_vm`, `wasm_aot` (plus standalone AOT when explicitly run).
- **Canonical cases:** `tests/parity/cases/*.json`. Supplemental harness tests under `tests/ts/parity/` do not replace JSON vectors.
- **Single comparison policy:** `tests/parity/compare.ts` only. Do not loosen tolerances to green failures.
- **Daily gate:** only `bun run mz`. No `feature_id` / `task_id` on the daily path. Auto tag: `{branch}__{UTC_time}__{short_sha}[__dirty]`.
- **Quarantine known fails** in `tests/known_failures.json` (strict bun gate). Unexpected fail/pass = fail.
- **Standalone AOT skip budget** may only shrink (`tools/testing/standalone_skip_budget.ts`).

## Product surfaces

- **Product web UI:** `apps/console` (SolidJS). REPL + `/graph`.
- **Progress UI:** `apps/progress`, fed automatically by `mz` → `apps/progress/public/data/`.
- **Not product UI:** `web/` (WASM/graph demo artifacts only). Legacy vanilla console was under `docs/archive/web_console_legacy/` (removed from tree when empty).
- **TUI:** `src/tui` → `zig build run`.
- **CLI:** `src/main.zig` → `zig-out/bin/mathzig` (REPL, `compile`, `compile-graph`, `graph run`).

## Graphs

- **Editor hot path:** multi-module `GraphRunner` (one wasm per compute node).
- **Fused export:** `mathzig compile-graph` → one module + `.graph.json`; load with `FusedGraphRunner`.
- **VM-native graph:** `mathzig graph run` evaluates in-process without loading `.wasm`.
- **Pure-wasm node interpreter** = phase-2 (not the current product default).

## Specs & docs board

- Streams **A/B/C are implemented**; residual debt is in `docs/STATUS.md` / `tests/known_failures.json`, not task checklists.
- **Live status board:** `docs/STATUS.md` only (`bun tools/status_report.ts`). Do not hand-edit.
- **What/how/why:** `docs/guides/capabilities.md` (and graphs/quality guides).
- **Focus:** `docs/FOCUS.md`. Strategy summary: `docs/ROADMAP.md` (not a second test gate). Docs map: `docs/README.md`.
- **Historical missions / plans / research** live under `docs/archive/` and are not the operational workflow.

## Codegen & ownership

- **Generated bindings:** never hand-edit `src/bindings/generated/*`; regenerate with `zig build gen-bindings`.
- **ABI definition input:** `src/api_definition.zig` (and related codegen tools under `tools/bindings/`).
- **Expression memory:** prefer `ChunkArena` for AST/bytecode lifetime; explicit allocators for long-lived values.
