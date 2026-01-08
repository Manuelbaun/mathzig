# Testing invariants

Full how-to: [`docs/guides/testing.md`](../guides/testing.md) · CLI: [`docs/COMMANDS.md`](../COMMANDS.md)

## One path

```bash
bun run mz
```

Always: **correctness → measure (if green) → record** (progress package + dashboard data).

| Stage | Question | On failure |
|-------|----------|------------|
| Correctness | Right answers? | Exit fail; measure skipped; package still written (`fail`) |
| Measure | How fast? | Soft (`partial`); correctness still drives exit |
| Record | History / regressions? | Always runs |

## Backends

| Backend | Path |
|---------|------|
| `zig_vm` | Native VM (reference) |
| `ts_ffi` | TS → FFI → native lib |
| `ts_wasm_vm` | TS → interpreter WASM |
| `wasm_aot` | Compile expr → AOT wasm → run |

## Feature change checklist

1. Update `tests/parity/cases/*.json` if behavior changed.
2. Zig implementation first.
3. `bun run mz` (or `--quick` / `--skip-measure` while iterating).
4. Open `apps/progress` (after `mz`).

## Artifacts (high level)

| Path | Role |
|------|------|
| `tests/artifacts/runs/<sha>/` | Step logs / summary |
| `tests/artifacts/parity/` | Per-backend CSVs |
| `tests/artifacts/performance/` | Log + snapshots |
| `tests/artifacts/progress/packages/` | Version packages |
| `apps/progress/public/data/` | Dashboard static JSON (incl. `latest_compare.json`) |

## Gone from the daily path

- CLI `feature_id` / `task_id`
- `feature_gate` as recommended entry
- Manual “remember to package / refresh app data”
- Equal alternate modes (`correct` vs `measure` vs hub workflows)
