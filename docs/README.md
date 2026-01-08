# MathZig documentation

## Live (read these)

| Path | Role |
|------|------|
| [`../AGENTS.md`](../AGENTS.md) | Agent contract (`CLAUDE.md` / `GEMINI.md` → symlink) |
| [`STATUS.md`](./STATUS.md) | **Live criterion status** — `bun tools/status_report.ts` |
| [`FOCUS.md`](./FOCUS.md) | What matters now |
| [`ROADMAP.md`](./ROADMAP.md) | Strategic summary (not a test gate) |
| [`COMMANDS.md`](./COMMANDS.md) | CLI + artifact paths |
| [`MATHZIG_STYLE.md`](./MATHZIG_STYLE.md) | Coding style |
| [`ZIG_CHEATSHEET.md`](./ZIG_CHEATSHEET.md) | Zig 0.15+ project notes |
| [`memory/`](./memory/) | Durable agent decisions / gotchas |
| [`guides/`](./guides/) | How-to + **what we built** |
| [`internals/`](./internals/) | Subsystem deep dives + source map |
| [`reference/`](./reference/) | API notes + graph tick baseline |

### Guides

| Guide | Topic |
|-------|--------|
| [`guides/capabilities.md`](./guides/capabilities.md) | **What is implemented, how & why** |
| [`guides/verification.md`](./guides/verification.md) | **Real verification pass** (code + tests vs claims) |
| [`guides/overview.md`](./guides/overview.md) | Architecture + tree |
| [`guides/testing.md`](./guides/testing.md) | `bun run mz` + parity policy |
| [`guides/quality.md`](./guides/quality.md) | Gate, quarantine, STATUS, progress |
| [`guides/web_console.md`](./guides/web_console.md) | Product UI (`apps/console`) |
| [`guides/wasm_aot_usage.md`](./guides/wasm_aot_usage.md) | AOT / fused modules (consumption) |
| [`guides/workflow.md`](./guides/workflow.md) | Multi-agent orchestration (for **new** work) |
| [`guides/ode_solver.md`](./guides/ode_solver.md) | ODE |
| [`guides/guide_timeseries.md`](./guides/guide_timeseries.md) | Time series |
| [`guides/generators.md`](./guides/generators.md) | Generators |
| [`guides/optimization.md`](./guides/optimization.md) | Optimization notes |

### Product (repo root)

| Doc | Role |
|-----|------|
| [`../PRODUCT.md`](../PRODUCT.md) | Users, purpose, brand |
| [`../DESIGN.md`](../DESIGN.md) | Console design system |

## Backlog & archive (not the board)

| Path | Role |
|------|------|
| [`tasks/`](./tasks/) | Optional legacy open notes + `status_matrix.md` only |
| [`archive/`](./archive/) | Plans, audits, missions, research (retired) |

**Do not** treat `tasks/` or `archive/` as live status. Use `STATUS.md` + `guides/capabilities.md`.

Closed task/spec markdown trees were **removed** after their substance was folded into the guides above. Graph tick numbers live in [`reference/graph_tick_baseline.md`](./reference/graph_tick_baseline.md).

## Layout

```text
docs/
  README.md           ← this map
  STATUS.md           ← generated live status
  FOCUS.md
  ROADMAP.md
  COMMANDS.md
  MATHZIG_STYLE.md
  ZIG_CHEATSHEET.md
  memory/             ← agent durable memory
  guides/             ← how-to + capabilities
  internals/          ← deep technical
  reference/          ← API + baselines
  tasks/              ← optional open backlog notes only
  archive/            ← retired material
```
