# MathZig — agent contract

Single source of truth for how agents work in this repo.  
`CLAUDE.md` and `GEMINI.md` are symlinks here.

## What this is

High-performance mathematical expression engine:

- Zig native VM (source of truth)
- Bun FFI + WASM interpreter + WASM AOT
- Graphs: multi-module editor path + fused `compile-graph`
- Product UI: `apps/console` (not `web/`)
- Progress dashboard: `apps/progress`

## Hard rules

| Rule | Detail |
|------|--------|
| **Git** | No commits unless the user asks |
| **Runtime** | Bun for TS (`bun run`, `bun test`); Zig for native |
| **Daily test path** | **`bun run mz` only** — no `feature_id` / `task_id`, no alternate gates |
| **Zig baseline** | Correctness source of truth; other backends match parity cases |
| **Bindings** | Never hand-edit `src/bindings/generated/*` — run `zig build gen-bindings` |
| **tmp** | Use `./tmp`, not `/tmp` |
| **Product UI** | `apps/console`; copy WASM to `apps/console/public/` |
| **macOS** | If needed: `export PATH="$PWD/tools/macos-sdk-shim:$PATH"` |

## Feature protocol (mandatory)

**Correctness first, performance second — both inside `mz`.**

1. Add/update parity JSON in `tests/parity/cases/*.json` when behavior changes.
2. Implement in **Zig first**.
3. Run **`bun run mz`** (full set records always).
4. Check `apps/progress` for green correctness and non-regression on perf.

```bash
bun run mz                     # full correctness → measure → record
bun run mz -- --quick          # faster parity while iterating (still records)
bun run mz -- --skip-measure   # correctness + package only
bun run mz where               # artifact paths
```

Optional flags only: `--quick`, `--skip-measure`, `--samples`, `--warmup`.

**Automatic run tag:** `{branch}__{UTC_time}__{short_sha}[__dirty]`  
Example: `main__20260710T121506Z__8e2bed8`

Pipeline implementation: `tools/testing/pipeline.ts` · CLI: `tools/mz/cli.ts`

## Programming standards (summary)

- **Style:** [`docs/MATHZIG_STYLE.md`](docs/MATHZIG_STYLE.md) — Tiger-style asserts, simplicity, mechanical sympathy
- **Memory:** `ChunkArena` for expression work; explicit ownership for long-lived values
- **Parity:** backends `zig_vm`, `ts_ffi`, `ts_wasm_vm`, `wasm_aot`; compare **only** via `tests/parity/compare.ts`
- **Console WASM:**
  ```bash
  zig build -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
  cp zig-out/bin/mathzig_wasm.wasm apps/console/public/
  ```
- Do **not** invent alternate daily test entrypoints
- Do **not** loosen `compare.ts` to green a failing case
- Do **not** treat legacy task notes as the live status board

## Where to find what

| Need | Path |
|------|------|
| **Docs map** | [`docs/README.md`](docs/README.md) |
| **What we built (how/why)** | [`docs/guides/capabilities.md`](docs/guides/capabilities.md) |
| **Durable decisions / gotchas** | [`docs/memory/`](docs/memory/) |
| **How-to guides** | [`docs/guides/`](docs/guides/) |
| Testing (mz + parity schema) | [`docs/guides/testing.md`](docs/guides/testing.md) |
| Quality / gate design | [`docs/guides/quality.md`](docs/guides/quality.md) |
| Graphs | [`docs/guides/graphs.md`](docs/guides/graphs.md) |
| Architecture / tree | [`docs/guides/overview.md`](docs/guides/overview.md) |
| Console / graph UI | [`docs/guides/web_console.md`](docs/guides/web_console.md) |
| AOT consumption | [`docs/guides/wasm_aot_usage.md`](docs/guides/wasm_aot_usage.md) |
| Multi-agent workflow | [`docs/guides/workflow.md`](docs/guides/workflow.md) |
| CLI + artifacts | [`docs/COMMANDS.md`](docs/COMMANDS.md) |
| **Live status** | [`docs/STATUS.md`](docs/STATUS.md) — `bun tools/status_report.ts` |
| **Current focus** | [`docs/FOCUS.md`](docs/FOCUS.md) |
| Strategy summary | [`docs/ROADMAP.md`](docs/ROADMAP.md) |
| Style | [`docs/MATHZIG_STYLE.md`](docs/MATHZIG_STYLE.md) |
| Zig notes | [`docs/ZIG_CHEATSHEET.md`](docs/ZIG_CHEATSHEET.md) |
| Source map | [`docs/internals/source_architecture.md`](docs/internals/source_architecture.md) |
| Graph tick baseline | [`docs/reference/graph_tick_baseline.md`](docs/reference/graph_tick_baseline.md) |
| Product / design | [`PRODUCT.md`](PRODUCT.md), [`DESIGN.md`](DESIGN.md) |
| Optional open backlog notes | [`docs/tasks/`](docs/tasks/) (not the daily board) |
| Archive | [`docs/archive/`](docs/archive/) |

## Report command

When the user says **Report** / **REPORT** / **report**: describe intent, current state, desired output, and approach — then wait for instruction.

## Do not

- Commit without being asked
- Use `feature_gate`, hub workflows, or task-id performance scripts as the daily path
- Treat `docs/archive/missions/` or historical `docs/tasks/*` as the active workflow
- Treat `web/` as the product UI
- Hand-edit generated bindings
- Put tmp files under `/tmp`
