# Tools

## Test CLI: `mz` (one way only)

```bash
bun run mz
```

Full pipeline: correctness (all backends) → measure all → always record progress package + dashboard data.

- No feature_id / task_id
- Identity = `{branch}__{UTC_time}__{short_sha}` (e.g. `main__20260710T121506Z__8e2bed8`)
- Implementation: `tools/testing/pipeline.ts`, CLI: `tools/mz/cli.ts`
- Meaning: `docs/guides/testing.md`
- Protocol: `AGENTS.md`

```bash
bun run mz where              # artifact paths
bun run mz -- --quick         # faster parity while iterating
bun run mz -- --skip-measure  # skip perf
```

## Progress dashboard data

Written automatically at the end of every `mz` run:

- packages: `tests/artifacts/progress/packages/`
- UI data: `apps/progress/public/data/`

```bash
cd apps/progress && bun run dev
```

## Status report

```bash
bun tools/status_report.ts
bun tools/status_report.ts --check
```

Writes `docs/STATUS.md` from inventory + artifacts (strict gate JSON, parity CSVs, graph goldens, quarantine).

## Other tools (not daily path)

| Path | Role |
|------|------|
| `tools/status_report.ts` | Generate `docs/STATUS.md` |
| `tools/testing/parity_case_coverage.ts` | Catalog coverage (skip/runnable %); `bun run test:parity:coverage` |
| `tools/testing/correctness.ts` | Correctness stages only (escape) |
| `tools/testing/measure.ts` | Perf only (escape) |
| `tools/testing/feature_gate.ts` | Legacy multi-option gate |
| `tools/progress/*` | Package / app-data builders |
| `tools/bench/*` | Snapshot / bench utilities |
| `tools/hub/*` | Legacy hub catalog (superseded by `mz`) |
