# Tests

**Daily runner (one way only):** `bun run mz`  
See **AGENTS.md** and **docs/guides/testing.md**. No feature/task ids — always records progress.

---

## Structure

```text
tests/
├── parity/
│   ├── cases/            # Canonical cross-backend parity vectors (JSON)
│   ├── backends/         # zig_vm, ts_ffi, ts_wasm_vm, wasm_aot
│   ├── compare.ts        # Value comparison policy
│   └── cli.ts            # Canonical parity runner (invoked by mz)
├── ts/
│   ├── parity/           # Supplemental TS harness/backend tests
│   └── simulations/      # Scenario-specific TS tests
├── zig/
│   ├── core/             # VM baseline, safety, core execution
│   ├── parser/           # Parser/AST/LaTeX
│   ├── types/            # Units/matrix/record/value types
│   ├── functions/        # ODE and function-level tests
│   ├── timeseries/       # Time-series scenarios
│   ├── diagnostics/      # Error / diagnostics
│   ├── backends/wasm/    # Zig-side WASM backend tests
│   └── …                 # io / dsl / probability / fuzz / …
├── performance/
│   ├── perf_runner.zig / perf_runner.ts
│   ├── timeseries_benchmark.zig
│   └── record_performance.ts
├── fixtures/             # Shared fixtures
├── scripts/              # Manual scenario scripts (.mzig, data)
└── artifacts/            # Generated outputs (gitignored except .gitkeep)
    ├── runs/             # Per-run steps + logs (keyed by git sha)
    ├── parity/           # Parity CSVs
    ├── performance/      # Perf log + snapshots
    └── progress/         # Progress packages
```

---

## What each part does

| Path | Role |
|------|------|
| `parity/cases/*.json` | Canonical cross-backend correctness vectors |
| `parity/cli.ts` | Loads cases, runs backends, writes parity artifacts |
| `ts/parity/*.test.ts` | Supplemental harness/backend tests only |
| `zig/**` | Zig-native correctness/safety; `core/vm_baseline_test.zig` is the core gate |
| `performance/*` | Throughput measurement helpers used by the pipeline |
| `scripts/*` | Manual exploratory scenarios |

---

## How to run

### Daily (required)

```bash
bun run mz
bun run mz -- --quick
bun run mz -- --skip-measure
bun run mz where
```

### After `mz`

```bash
cd apps/progress && bun run dev
```

### Narrow escapes (maintainers)

```bash
export PATH="$PWD/tools/macos-sdk-shim:$PATH"   # macOS if needed

zig build vm-baseline --summary all
zig build test --summary all
bun tests/parity/cli.ts --quick
bun tests/parity/cli.ts --full
```

Do **not** use legacy `feature_gate.ts` / hub workflows for daily work. See `tools/README.md`.

---

## Output locations

| Path | Description |
|------|-------------|
| `tests/artifacts/runs/<git-sha>/` | steps.json, summary, logs |
| `tests/artifacts/parity/` | `{tag}_{backend}.csv` (tag from automatic mz identity) |
| `tests/artifacts/performance/performance_log.csv` | Append-only perf CSV |
| `tests/artifacts/performance/snapshots/` | Perf snapshots |
| `tests/artifacts/progress/packages/` | Versioned progress packages |
| `apps/progress/public/data/` | Dashboard JSON (written by mz) |

---

## Rules

- Zig VM is source-of-truth baseline.
- Add new cross-backend coverage to `tests/parity/cases/*.json`.
- Use `tests/parity/cli.ts` as the parity runner; `mz` is the orchestrator.
- Keep `tests/ts/parity` for supplemental harness behavior only.
- Keep generated files under `tests/artifacts/` out of git (except `.gitkeep`).
- Correctness first: only interpret perf after correctness is green.

## Feature protocol

1. Add/update parity JSON when behavior changes.  
2. Commit.  
3. `bun run mz`.  
4. Check progress dashboard.  
