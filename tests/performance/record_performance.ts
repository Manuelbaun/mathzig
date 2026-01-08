import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

type Mode = "all" | "zig" | "ts";

type RawRow = {
  timestamp: number;
  featureId: string;
  testName: string;
  iterations: number;
  durationMs: number;
  opsPerSec: number;
  memAllocated: number;
  memReserved: number;
  memPeak: number;
};

type AggRow = {
  timestamp: number;
  featureId: string;
  testName: string;
  iterations: number;
  durationMs: number;
  opsPerSec: number;
  memAllocated: number;
  memReserved: number;
  memPeak: number;
  sampleCount: number;
  opsP50: number;
  opsP95: number;
  opsP99: number;
  opsMin: number;
  opsMax: number;
  opsStddev: number;
  durationP50: number;
  durationP95: number;
  durationP99: number;
  durationMin: number;
  durationMax: number;
  durationStddev: number;
  runMode: string;
  gitSha: string;
  cpuModel: string;
  cpuCores: number;
  osInfo: string;
  bunVersion: string;
  zigVersion: string;
  benchIters: string;
  benchBatch: string;
  perfSamples: number;
};

const featureId = process.argv[2] ?? "baseline";
const modeArg = process.argv[3] ?? "all";
const strict = process.env.STRICT === "1";
const samples = Math.max(1, Number(process.env.PERF_SAMPLES ?? "5"));
const warmup = Math.max(0, Number(process.env.PERF_WARMUP ?? "1"));

if (modeArg !== "all" && modeArg !== "zig" && modeArg !== "ts") {
  console.error("Invalid mode. Expected one of: all|zig|ts");
  process.exit(2);
}

const mode = modeArg as Mode;
const logDir = path.resolve(process.cwd(), "tests/artifacts/performance");
const logFile = path.join(logDir, "performance_log.csv");
const header = [
  "timestamp",
  "feature_id",
  "test_name",
  "iterations",
  "duration_ms",
  "ops_per_sec",
  "mem_allocated",
  "mem_reserved",
  "mem_peak",
  "sample_count",
  "ops_p50",
  "ops_p95",
  "ops_p99",
  "ops_min",
  "ops_max",
  "ops_stddev",
  "duration_p50",
  "duration_p95",
  "duration_p99",
  "duration_min",
  "duration_max",
  "duration_stddev",
  "run_mode",
  "git_sha",
  "cpu_model",
  "cpu_cores",
  "os",
  "bun_version",
  "zig_version",
  "bench_iters",
  "bench_batch",
  "perf_samples",
].join(",");

fs.mkdirSync(logDir, { recursive: true });
if (!fs.existsSync(logFile)) {
  fs.writeFileSync(logFile, `${header}\n`, "utf8");
} else {
  migrateHeaderIfNeeded();
}

console.log(`Running MathZig Performance Benchmarks for: ${featureId}`);
console.log(`Mode: ${mode} (STRICT=${strict ? 1 : 0}, SAMPLES=${samples}, WARMUP=${warmup})`);

let status = 0;
const metadata = collectMetadata();

function parseThreadCounts(): number[] {
  const raw = process.env.PERF_THREAD_COUNTS?.trim();
  if (!raw) {
    const maxCores = Math.max(1, os.cpus().length);
    const fallback = [1, maxCores];
    return [...new Set(fallback)].sort((a, b) => a - b);
  }
  const parsed = raw
    .split(",")
    .map((s) => Number(s.trim()))
    .filter((n) => Number.isFinite(n) && n > 0)
    .map((n) => Math.floor(n));
  const deduped = [...new Set(parsed)].sort((a, b) => a - b);
  return deduped.length > 0 ? deduped : [1];
}

function getCmdOutput(cmd: string[], env?: NodeJS.ProcessEnv) {
  const run = Bun.spawnSync({ cmd, env, stdout: "pipe", stderr: "pipe" });
  const stdout = new TextDecoder().decode(run.stdout ?? new Uint8Array());
  const stderr = new TextDecoder().decode(run.stderr ?? new Uint8Array());
  return { exit: run.exitCode ?? 1, stdout, stderr, text: `${stdout}\n${stderr}` };
}

function parseCsvRows(text: string): RawRow[] {
  const rows: RawRow[] = [];
  for (const line of text.split(/\r?\n/)) {
    if (!line) continue;
    const cols = line.split(",");
    if (cols.length < 9) continue;
    const timestamp = Number(cols[0]);
    const iterations = Number(cols[3]);
    const durationMs = Number(cols[4]);
    const opsPerSec = Number(cols[5]);
    const memAllocated = Number(cols[6]);
    const memReserved = Number(cols[7]);
    const memPeak = Number(cols[8]);
    if (!Number.isFinite(timestamp) || !Number.isFinite(iterations) || !Number.isFinite(durationMs) || !Number.isFinite(opsPerSec)) continue;
    rows.push({
      timestamp,
      featureId: cols[1],
      testName: cols[2],
      iterations,
      durationMs,
      opsPerSec,
      memAllocated: Number.isFinite(memAllocated) ? memAllocated : 0,
      memReserved: Number.isFinite(memReserved) ? memReserved : 0,
      memPeak: Number.isFinite(memPeak) ? memPeak : 0,
    });
  }
  return rows;
}

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return 0;
  const idx = (sorted.length - 1) * p;
  const lo = Math.floor(idx);
  const hi = Math.ceil(idx);
  if (lo === hi) return sorted[lo];
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - lo);
}

function mean(values: number[]): number {
  if (values.length === 0) return 0;
  return values.reduce((a, b) => a + b, 0) / values.length;
}

function stddev(values: number[]): number {
  if (values.length <= 1) return 0;
  const m = mean(values);
  const v = values.reduce((acc, x) => acc + (x - m) * (x - m), 0) / values.length;
  return Math.sqrt(v);
}

function aggregateRows(rawRows: RawRow[], runMode: string): AggRow[] {
  const byTest = new Map<string, RawRow[]>();
  for (const r of rawRows) {
    const key = `${r.featureId}::${r.testName}`;
    const arr = byTest.get(key) ?? [];
    arr.push(r);
    byTest.set(key, arr);
  }

  const out: AggRow[] = [];
  for (const rows of byTest.values()) {
    const base = rows[0];
    const ops = rows.map((r) => r.opsPerSec).sort((a, b) => a - b);
    const durs = rows.map((r) => r.durationMs).sort((a, b) => a - b);
    out.push({
      timestamp: base.timestamp,
      featureId: base.featureId,
      testName: base.testName,
      iterations: base.iterations,
      durationMs: percentile(durs, 0.5),
      opsPerSec: percentile(ops, 0.5),
      memAllocated: Math.max(...rows.map((r) => r.memAllocated)),
      memReserved: Math.max(...rows.map((r) => r.memReserved)),
      memPeak: Math.max(...rows.map((r) => r.memPeak)),
      sampleCount: rows.length,
      opsP50: percentile(ops, 0.5),
      opsP95: percentile(ops, 0.95),
      opsP99: percentile(ops, 0.99),
      opsMin: ops[0] ?? 0,
      opsMax: ops[ops.length - 1] ?? 0,
      opsStddev: stddev(ops),
      durationP50: percentile(durs, 0.5),
      durationP95: percentile(durs, 0.95),
      durationP99: percentile(durs, 0.99),
      durationMin: durs[0] ?? 0,
      durationMax: durs[durs.length - 1] ?? 0,
      durationStddev: stddev(durs),
      runMode,
      ...metadata,
      perfSamples: samples,
    });
  }
  return out;
}

function appendAggRows(rows: AggRow[]) {
  for (const r of rows) {
    fs.appendFileSync(
      logFile,
      [
        r.timestamp,
        r.featureId,
        r.testName,
        r.iterations,
        r.durationMs.toFixed(4),
        r.opsPerSec.toFixed(2),
        r.memAllocated,
        r.memReserved,
        r.memPeak,
        r.sampleCount,
        r.opsP50.toFixed(2),
        r.opsP95.toFixed(2),
        r.opsP99.toFixed(2),
        r.opsMin.toFixed(2),
        r.opsMax.toFixed(2),
        r.opsStddev.toFixed(4),
        r.durationP50.toFixed(4),
        r.durationP95.toFixed(4),
        r.durationP99.toFixed(4),
        r.durationMin.toFixed(4),
        r.durationMax.toFixed(4),
        r.durationStddev.toFixed(4),
        r.runMode,
        r.gitSha,
        quoteCsv(r.cpuModel),
        r.cpuCores,
        r.osInfo,
        r.bunVersion,
        r.zigVersion,
        r.benchIters,
        r.benchBatch,
        r.perfSamples,
      ].join(",") + "\n"
    );
  }
}

function quoteCsv(value: string): string {
  if (!value.includes(",") && !value.includes('"')) return value;
  return `"${value.replaceAll('"', '""')}"`;
}

function formatOps(n: number): string {
  if (!Number.isFinite(n)) return "?";
  if (n >= 1e9) return `${(n / 1e9).toFixed(2)}G/s`;
  if (n >= 1e6) return `${(n / 1e6).toFixed(2)}M/s`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(2)}k/s`;
  return `${n.toFixed(1)}/s`;
}

function runSuiteWithSampling(label: string, cmd: string[], env?: NodeJS.ProcessEnv): number {
  console.log(`\n  ── measure suite: ${label} ──`);
  console.log(`     cmd: ${cmd.join(" ")}`);

  for (let i = 0; i < warmup; i += 1) {
    console.log(`     warmup ${i + 1}/${warmup}…`);
    const warm = getCmdOutput(cmd, env);
    if (warm.exit !== 0) {
      if (warm.stderr) process.stderr.write(warm.stderr);
      console.error(`  ✗ ${label} warmup ${i + 1}/${warmup} failed`);
      return warm.exit;
    }
    console.log(`     warmup ${i + 1}/${warmup}: ok`);
  }

  const allRows: RawRow[] = [];
  for (let i = 0; i < samples; i += 1) {
    console.log(`     sample ${i + 1}/${samples}…`);
    const res = getCmdOutput(cmd, env);
    if (res.exit !== 0) {
      if (res.stderr) process.stderr.write(res.stderr);
      console.error(`  ✗ ${label} sample ${i + 1}/${samples} failed`);
      return res.exit;
    }
    const rows = parseCsvRows(res.text);
    console.log(`     sample ${i + 1}/${samples}: ${rows.length} bench rows`);
    allRows.push(...rows);
  }

  if (allRows.length === 0) {
    console.error(`  ✗ ${label} produced no CSV rows`);
    return 1;
  }

  const agg = aggregateRows(allRows, label);
  appendAggRows(agg);

  console.log(`  ✓ ${label} recorded (${samples} samples, ${agg.length} benches):`);
  for (const row of agg) {
    console.log(
      `     • ${row.testName.padEnd(40).slice(0, 40)}  ${formatOps(row.opsP50).padStart(10)}  (p50)`
    );
  }
  return 0;
}

console.log(`\n▶ measure: env check`);
const envCheck = getCmdOutput(["bun", "tests/performance/perf_env_check.ts", featureId], process.env);
if (envCheck.stdout.trim().length > 0) console.log(envCheck.stdout.trim());
if (envCheck.exit !== 0) {
  if (process.env.PERF_ENV_STRICT === "1") {
    console.error("✗ measure: perf environment check failed.");
    status = 1;
  } else {
    console.warn("⚠ measure: perf environment check reported issues (non-strict mode).");
  }
} else {
  console.log(`✓ measure: env check ok`);
}

if (mode === "all" || mode === "zig") {
  console.log(`\n▶ measure: zig ReleaseFast build`);
  const baseZigEnv = {
    ...process.env,
    ZIG_CACHE_DIR: process.env.ZIG_CACHE_DIR ?? ".zig-cache",
    ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? ".zig-global-cache",
  };
  const build = Bun.spawnSync({
    cmd: ["zig", "build", "-Doptimize=ReleaseFast"],
    env: baseZigEnv,
    stdout: "inherit",
    stderr: "inherit",
  });

  if (build.exitCode === 0) {
    console.log(`✓ measure: zig build ok`);
    const threadCounts = parseThreadCounts();
    console.log(`▶ measure: zig thread matrix [${threadCounts.join(", ")}]`);
    for (const count of threadCounts) {
      console.log(`\n▶ measure: zig threads=${count}`);
      const env = {
        ...baseZigEnv,
        MATHZIG_THREADS: String(count),
        MATHZIG_LABEL_SUFFIX: `_t${count}`,
      };
      if (runSuiteWithSampling(`zig_t${count}`, ["./zig-out/bin/perf_runner", featureId], env) !== 0) {
        status = 1;
      }
      if (
        runSuiteWithSampling(
          `zig_ts_bench_t${count}`,
          ["./zig-out/bin/ts_benchmark", featureId],
          env
        ) !== 0
      ) {
        status = 1;
      }
    }
  } else {
    console.error("✗ measure: zig build failed");
    status = 1;
  }
}

if (mode === "all" || mode === "ts") {
  console.log(`\n▶ measure: TypeScript / FFI benches`);
  const tsExit = runSuiteWithSampling(
    "ts",
    ["bun", "tests/performance/perf_runner.ts", featureId],
    process.env
  );
  if (tsExit !== 0) {
    console.error("✗ measure: TypeScript performance runner failed");
    if (strict) status = 1;
  }
}

if (status !== 0) {
  console.error("\n✗ Performance run completed with errors.");
  process.exit(status);
}

console.log(`\n✓ All performance data appended to ${path.relative(process.cwd(), logFile)}`);

function collectMetadata() {
  const cpus = os.cpus();
  const cpuModel = cpus[0]?.model ?? "unknown";
  const cpuCores = cpus.length;
  const osInfo = `${process.platform}-${process.arch}`;
  const bunVersion = Bun.version;
  const zigVersion = getCmdOutput(["zig", "version"]).stdout.trim() || "unknown";
  const gitSha = getCmdOutput(["git", "rev-parse", "--short", "HEAD"]).stdout.trim() || "unknown";
  return {
    gitSha,
    cpuModel,
    cpuCores,
    osInfo,
    bunVersion,
    zigVersion,
    benchIters: process.env.BENCH_ITERS ?? "",
    benchBatch: process.env.BENCH_BATCH ?? "",
  };
}

function migrateHeaderIfNeeded() {
  const text = fs.readFileSync(logFile, "utf8");
  const lines = text.split(/\r?\n/).filter(Boolean);
  if (lines.length === 0) {
    fs.writeFileSync(logFile, `${header}\n`, "utf8");
    return;
  }
  if (lines[0] === header) return;

  const migrated: string[] = [header];
  for (let i = 1; i < lines.length; i += 1) {
    const cols = lines[i].split(",");
    if (cols.length < 9) continue;
    migrated.push([
      cols[0], cols[1], cols[2], cols[3], cols[4], cols[5], cols[6], cols[7], cols[8],
      "1", cols[5], cols[5], cols[5], cols[5], cols[5], "0",
      cols[4], cols[4], cols[4], cols[4], cols[4], "0",
      "legacy", "", "", "", "", "", "", "", "", "1",
    ].join(","));
  }
  fs.writeFileSync(logFile, `${migrated.join("\n")}\n`, "utf8");
}
