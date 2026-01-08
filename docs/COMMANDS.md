# MathZig commands

> **One way to test:** `bun run mz`. Protocol: [`AGENTS.md`](../AGENTS.md) · how-to: [`docs/guides/testing.md`](./guides/testing.md)

## Daily path

```bash
bun run mz
bun run mz where              # where data lands
bun run mz -- --quick         # parity quick (still records)
bun run mz -- --skip-measure  # skip perf
```

No feature_id / task_id. **Automatic tag** = `{branch}__{UTC_time}__{short_sha}[__dirty]`.

CLI implementation: `tools/mz/cli.ts` · pipeline: `tools/testing/pipeline.ts`

## Dashboard

```bash
cd apps/progress && bun run dev
```

Data is written by `mz` into `apps/progress/public/data/`.

## Artifact locations

| Path | Description |
|------|-------------|
| `tests/artifacts/runs/<git-sha>/` | Per-run steps.json, summary, logs |
| `tests/artifacts/parity/` | Parity CSVs per backend |
| `tests/artifacts/performance/performance_log.csv` | Append-only perf CSV |
| `tests/artifacts/performance/snapshots/` | Perf snapshots |
| `tests/artifacts/progress/packages/` | Versioned progress packages |
| `apps/progress/public/data/` | Dashboard static JSON |

## Status report (docs truth)

```bash
bun tools/status_report.ts           # rewrite docs/STATUS.md
bun tools/status_report.ts --check   # same-revision idempotence
bun run test:parity:coverage         # honest catalog skip/runnable report
```

`docs/STATUS.md` is the single criterion-level status source (do not hand-edit).

## Not the daily path

Legacy hub / feature-gate / measure-with-id tools under `tools/hub`, `tools/testing/feature_gate.ts`, etc. Prefer `bun run mz`.

## Adversarial inputs

Default-seed fuzzers + regression corpora run inside the mandatory `bun test` /
`zig build test` path (via `mz`).

**Nightly deep run** (not part of the daily gate):

```bash
export PATH="$PWD/tools/macos-sdk-shim:$PATH"
bun tools/testing/adversarial_deep.ts
bun tools/testing/adversarial_deep.ts --seed=0x4d415448 --count=5000 --deadline-ms=120000
```

Surfaces / corpora: `tests/adversarial/README.md`.

## Native CLI (selected)

```bash
zig build   # → zig-out/bin/mathzig
```

| Command | Purpose |
|---------|---------|
| `mathzig compile -i expr.mz -o out.wasm` | Single-expression AOT |
| `mathzig compile --node …` | Single-node module + `.node.json` |
| `mathzig compile-graph -i graph.json -o out.wasm` | **Fused graph** → one module + `.graph.json` |
| `mathzig graph run graph.json` | VM-native graph evaluator v1 (in-process VM; no .wasm load) |

### `compile-graph`

```bash
./zig-out/bin/mathzig compile-graph -i graph.json -o out.wasm
# writes out.wasm + out.graph.json  (sidecar == mathzig:graph section bytes)
./zig-out/bin/mathzig compile-graph -i graph.json -o out.wasm -v --out-mode named_exports
./zig-out/bin/mathzig compile-graph -i graph.json -o out.wasm --standalone   # hard-error if env imports needed
./zig-out/bin/mathzig compile-graph -i graph.json -o out.wasm --export-node-helpers
```

| Flag | Meaning |
|------|---------|
| `-i` / `--input` | Graph JSON path |
| `-o` / `--output` | Output `.wasm` path |
| `-v` / `--verbose` | Plan summary + bytecode dumps |
| `-s` / `--standalone` | Hard-error if any host import would be required |
| `--out-mode` | `table` (**CLI default**) or `named_exports` |
| `--export-node-helpers` | Also export `n_<id>` per compute node |

v1 fuse: `expr` graphs with multi **values** (number/boolean plus matrix/complex/record/series on ports). Opaque `wasm` nodes and free vars not in declared ports are rejected. Editor hot path stays multi-module `GraphRunner`.

**Default note:** CLI defaults to `out_mode=table`. TS `compileFused(def)` defaults to **`table` when the graph has any non-scalar port**, and `named_exports` for pure-scalar graphs (historical goldens). Pass `{ outMode: "table" | "named_exports" }` to force either mode.

Consumption: [`docs/guides/wasm_aot_usage.md`](./guides/wasm_aot_usage.md).
