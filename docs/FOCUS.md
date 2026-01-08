# FOCUS

## Source of truth

| Doc | Role |
|-----|------|
| [`STATUS.md`](./STATUS.md) | Live criterion status — `bun tools/status_report.ts` |
| [`guides/capabilities.md`](./guides/capabilities.md) | What is implemented, how & why |
| Root [`AGENTS.md`](../AGENTS.md) | Agent contract + daily gate |

```bash
export PATH="$PWD/tools/macos-sdk-shim:$PATH"
bun run mz
bun tools/status_report.ts --check
```

## Product program status

Streams A (AOT), B (graphs), C (hardening) are **implemented** with residual debt tracked in STATUS / `known_failures.json` — not as open checklists.

| Area | Doc |
|------|-----|
| Capabilities | [`guides/capabilities.md`](./guides/capabilities.md) |
| Graphs dual model | [`guides/graphs.md`](./guides/graphs.md) |
| Quality system | [`guides/quality.md`](./guides/quality.md) |
| Testing how-to | [`guides/testing.md`](./guides/testing.md) |
| Historical audits / plans | [`archive/`](./archive/) |

## Residual product debt

| Area | Where |
|------|--------|
| AOT 2-arg `round` | parity skips / STATUS |
| MathJS / rocket quarantine | `tests/known_failures.json` |
| Pure-wasm graph interpreter | phase-2 (`guides/graphs.md`) |
| Optional legacy open notes | `docs/tasks/*.md` + `status_matrix.md` |

## Docs hygiene

1. Keep STATUS honest after meaningful gate runs.  
2. Prefer editing **capabilities / guides** over adding task files.  
3. Optional: close leftover `docs/tasks/*.md` when verified; delete the row from `status_matrix.md`.  
4. Do **not** recreate a parallel task board next to STATUS.
