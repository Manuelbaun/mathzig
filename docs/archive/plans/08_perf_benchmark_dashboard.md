# Plan 08: MathZig Performance Benchmark Dashboard

**Priority:** 🟡 Infrastructure · **Last updated:** 2026-07-07 · **Status:** Phase 1 complete

---

## Purpose

Establish a **manifest-driven benchmark suite** with **version snapshots** and a **static dashboard** for comparing MathZig performance across feature implementations and git tags — inspired by [Benchmarks Game](https://benchmarksgame-team.pages.debian.net/benchmarksgame/) and [JS Framework Benchmark](https://krausest.github.io/js-framework-benchmark/).

Goals:

- **Y-axis:** benchmark metrics (ops/s, ms, ratios)
- **X-axis:** snapshots (git tag, feature_id + SHA)
- **Reference baselines:** plain Zig and C for mandelbrot, binarytree, vecdot, gemm
- **Workflow:** integrate after correctness gates (vm-baseline → test → parity → bench)

---

## Current State (Before)

| Piece | Location | Gap |
|-------|----------|-----|
| Zig runner | `tests/performance/perf_runner.zig` | Ad-hoc benches, no manifest |
| TS runner | `tests/performance/perf_runner.ts` | Separate naming (`ffi_*`) |
| VM micro-bench | `tests/performance/vm_micro_bench.zig` | Not in CSV pipeline |
| Orchestrator | `tests/performance/record_performance.ts` | Flat CSV only |
| Compare | `tools/testing/compare_perf.ts` | Pairwise markdown, no trends |
| Storage | `performance_log.csv` | No structured snapshots |

---

## Target Architecture

```
bench/
  manifest.json              # benchmark catalog + aliases
  refs/                      # plain Zig/C reference implementations
tools/bench/
  run.ts                     # orchestrate capture → snapshot
  import_csv.ts              # backfill snapshots from legacy CSV
  build_index.ts             # snapshot registry
  build_dashboard.ts         # static HTML dashboard
tests/artifacts/performance/
  index.json                 # all snapshots (X-axis)
  snapshots/<id>.json        # structured results per run
  dashboard/index.html       # trend + compare UI
  performance_log.csv          # legacy flat log (kept)
```

---

## Benchmark Catalog (Phase 1)

### Tiers

| Tier | When | Benchmarks |
|------|------|------------|
| `smoke` | Feature gate quick check | `arith.scalar`, `arith.batch_simd`, `ref.mandelbrot`, `ref.binarytree` |
| `standard` | Before merge | All hot + vm + kernels |
| `full` | Release tags | + DSL, bindings matrix, all ref sizes |

### Stable IDs

| ID | Description | Backends |
|----|-------------|----------|
| `arith.scalar` | VM number-only fast path | `mathzig_zig`, `mathzig_ffi`, `native_js` |
| `arith.batch_simd` | SIMD batch evaluation | `mathzig_zig`, `mathzig_ffi` |
| `complex.div_batch` | Complex SIMD division | `mathzig_zig`, `mathzig_ffi` |
| `vm.index.dynamic` | Dynamic vector indexing | `mathzig_zig` |
| `vm.index.const` | Constant vector indexing | `mathzig_zig` |
| `kernel.vecdot` | vecDot kernel (size param) | `mathzig_zig`, `ref_zig` |
| `kernel.gemm` | gemm 100×100 | `mathzig_zig` |
| `timeseries.agg` | SIMD aggregations 1M | `mathzig_zig` |
| `ode.harmonic` | ODE solve 10k steps | `mathzig_zig` |
| `ode.lorenz` | Lorenz 5k steps | `mathzig_zig` |
| `ref.mandelbrot` | Mandelbrot iteration count | `ref_zig`, `ref_c` |
| `ref.binarytree` | BST search | `ref_zig`, `ref_c` |

Legacy CSV names map via `aliases` in manifest (e.g. `zig_arithmetic_scalar_fast_t1` → `arith.scalar`).

---

## Snapshot Model

```json
{
  "id": "v0.3.0",
  "git_tag": "v0.3.0",
  "git_sha": "df8c345",
  "feature_id": "0079_vm_hotpaths",
  "recorded_at": "2026-07-07T14:30:00Z",
  "machine_id": "darwin-arm64-m1pro",
  "tier": "standard",
  "results": [
    {
      "bench_id": "ref.binarytree",
      "backend": "ref_zig",
      "threads": 1,
      "score": 1250000,
      "unit": "ops/s",
      "ops_p50": 1250000,
      "sample_count": 5
    }
  ]
}
```

**Snapshot kinds:**

- **release** — git tag (`v0.x.y`), primary X-axis points
- **dev** — `feature_id` + short SHA, plotted as secondary points

**Cross-machine rule:** compare only within same `machine_id`; dashboard warns on mix.

---

## Dashboard UI

Generated static site at `tests/artifacts/performance/dashboard/index.html`.

### Views

1. **Overview table** — latest snapshot: benchmark × backend, ratio vs `ref_zig`, Δ% vs previous tag
2. **Trend charts** — X = snapshots (ordered), Y = score; one chart per benchmark; lines per backend
3. **Regression board** — red/green vs previous snapshot (thresholds from `compare_perf.ts`)

### Commands

```bash
bun run bench -- --feature my_feature --tier smoke
bun run bench:import          # backfill snapshots from existing CSV
bun run bench:dashboard       # regenerate HTML
bun run bench:open            # build + open in browser
```

---

## Workflow Integration

Gate order (unchanged from `Agents.md`):

1. Parity cases
2. `zig build vm-baseline`
3. `zig build test`
4. `bun test`
5. Parity `--quick` / `--full`
6. **`bun run bench -- --tier smoke`** (new)
7. **`bun run bench -- --tier standard`** (before done)
8. On tag: **`bun run bench:snapshot -- --tag v0.x.y --tier full`**

---

## Implementation Phases

### Phase 1 — Foundation ✅

- [x] Plan document (`docs/plans/08_perf_benchmark_dashboard.md`)
- [x] `bench/manifest.json`
- [x] Reference benches: mandelbrot + binarytree (Zig + C)
- [x] `tools/bench/` (`run.ts`, `import_csv.ts`, `build_index.ts`, `build_dashboard.ts`)
- [x] `package.json` scripts (`bench`, `bench:dashboard`, `bench:open`, `bench:import`, `bench:refs`)
- [x] Backfill from existing `performance_log.csv`
- [x] Static dashboard with overview table + trend charts (Chart.js)

### Phase 2 — Unified runner

- [ ] Single `bench_runner` executable driven by manifest
- [ ] Fold `vm_micro_bench.zig` into manifest
- [ ] Normalize thread count as dimension (not in test name)
- [ ] `feature_gate.ts` calls `bench --tier smoke`

### Phase 3 — Release snapshots

- [ ] Git tag convention + `bench:snapshot --tag`
- [ ] CI artifact upload on tag push
- [ ] Ratio columns: `mathzig / ref_zig`

### Phase 4 — DSL reference variants

- [ ] MathZig DSL wrappers for mandelbrot/binarytree when meaningful
- [ ] WASM binding tier in manifest

---

## Verification

```bash
bun run bench:import
bun run bench:dashboard
bun run bench:open

# Fresh capture (requires perf-tools build):
zig build -Dperf-tools=true -Doptimize=ReleaseFast
bun run bench -- --feature bench_smoke --tier smoke
bun run bench:dashboard
```

---

## Related Docs

- [testing.md](../guides/testing.md) — feature gate workflow
- [compare_perf.ts](../../tools/testing/compare_perf.ts) — pairwise regression thresholds
- [record_performance.ts](../../tests/performance/record_performance.ts) — legacy orchestrator