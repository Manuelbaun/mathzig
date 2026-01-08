#!/usr/bin/env bun
/**
 * Performance measurement only — run AFTER correctness is green.
 *
 * What it measures (not the same as correctness):
 *   - How fast microbenchmarks run (ops/s), not whether answers are right.
 *   - Zig native runner: arith, SIMD batches, kernels, ODE, timeseries, etc.
 *   - Optional TS/FFI runner for host-path speed.
 *   - Does NOT re-run parity cases for speed (that would mix correctness + perf).
 *
 * Usage:
 *   bun tools/testing/measure.ts <feature_id> [zig|ts|all]
 *
 * Env:
 *   PERF_SAMPLES   default 5
 *   PERF_WARMUP    default 1
 *
 * Writes:
 *   tests/artifacts/performance/performance_log.csv  (append)
 *   tests/artifacts/performance/env_checks/<feature_id>.json
 *
 * Optional snapshot for trends:
 *   bun tools/bench/run.ts --feature <feature_id> --mode zig --tier smoke --skip-perf
 *   (if you already recorded CSV; or omit --skip-perf to record+snapshot)
 */
const featureId = process.argv[2];
const mode = process.argv[3] ?? "zig";

if (!featureId || process.argv.length > 4) {
  console.error(`Usage: bun tools/testing/measure.ts <feature_id> [zig|ts|all]

Measures SPEED (ops/s), not correctness.
Run correctness first:
  bun tools/testing/correctness.ts
`);
  process.exit(2);
}

if (mode !== "zig" && mode !== "ts" && mode !== "all") {
  console.error(`Invalid mode ${mode}; use zig|ts|all`);
  process.exit(2);
}

console.log(`\nMathZig measure (perf only)`);
console.log(`feature_id: ${featureId}`);
console.log(`mode:       ${mode}`);
console.log(`\nWhat this measures:`);
console.log(`  Throughput of fixed microbenchmarks (scalar arith, SIMD, gemm, …).`);
console.log(`  Not: parity cases, not full test suite, not packaging.\n`);

const res = Bun.spawnSync({
  cmd: ["bun", "tests/performance/record_performance.ts", featureId, mode],
  cwd: process.cwd(),
  env: process.env,
  stdout: "inherit",
  stderr: "inherit",
});

const code = res.exitCode ?? 1;
if (code === 0) {
  console.log(`\nPerf rows appended → tests/artifacts/performance/performance_log.csv`);
  console.log(`Compare later: bun tools/testing/compare_perf.ts <baseline> ${featureId} 5 ${mode}`);
} else {
  console.error(`\nMeasure failed (exit ${code}).`);
}
process.exit(code);
