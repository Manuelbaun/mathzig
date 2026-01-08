#!/usr/bin/env bun
/**
 * Structured performance compare SoT for progress packages.
 *
 * Can compare:
 * - two feature_ids via performance_log.csv
 * - two snapshot/package performance payloads
 *
 * Resolves bench_id/backend/threads via tools/bench/manifest when possible.
 * Prefer manifest.regression_threshold_pct; else hot/integration heuristics
 * (same spirit as tools/testing/compare_perf.ts).
 *
 * Machine isolation: when both sides expose a machine_id and they differ,
 * refuse unless allow_cross_machine=true (warns even then). CSV-only feature_id
 * compares without machine metadata log a soft note — filter via machine_id when known.
 *
 * Does not replace compare_perf.ts (markdown CLI remains); this emits structured JSON.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { benchById, resolveBackend, resolveBenchId, resolveThreads } from "../bench/manifest.ts";
import { parseCsvText } from "../bench/parse.ts";
import type { BenchResult, Snapshot } from "../bench/types.ts";
import { writeJsonAtomic } from "../testing/feature_gate_steps.ts";
import { PERF_LOG, ROOT } from "./paths.ts";
import type {
  PerformanceCompareDocument,
  PerformanceCompareRow,
  PerformanceDocument,
  ThresholdSource,
} from "./types.ts";

export type Suite = "all" | "zig" | "ts";

export type CompareScoreRow = {
  test_name: string;
  score: number;
  ops_stddev?: number;
  sample_count?: number;
  bench_id?: string;
  backend?: string;
  threads?: number;
};

export type CompareInput = {
  baseline_feature_id: string;
  after_feature_id: string;
  baseline_version_id?: string | null;
  after_version_id?: string | null;
  /** Preferred single machine for the compare (and CSV filter when present). */
  machine_id?: string | null;
  /** Explicit per-side machines when comparing packages/snapshots. */
  baseline_machine_id?: string | null;
  after_machine_id?: string | null;
  /**
   * When false (default), refuse compare if both sides have distinct non-empty machine_ids.
   * When true, still warn but proceed.
   */
  allow_cross_machine?: boolean;
  suite?: Suite;
  max_regression_pct?: number;
  /** Rows keyed by test_name; if omitted, load from performance_log.csv */
  baseline_rows?: CompareScoreRow[];
  after_rows?: CompareScoreRow[];
  csv_path?: string;
  out_json?: string | null;
};

const HOT_THRESHOLD = Number(process.env.PERF_THRESH_HOT ?? "3");
const INTEGRATION_THRESHOLD = Number(process.env.PERF_THRESH_INTEGRATION ?? "8");
const UNSTABLE_CV = Number(process.env.PERF_UNSTABLE_CV ?? "0.10");
const ABS_DROP_OPS = Number(process.env.PERF_ABS_DROP_OPS ?? "1000");

function suiteMatch(testName: string, suite: Suite): boolean {
  if (suite === "all") return true;
  if (suite === "zig") return testName.startsWith("zig_");
  return testName.startsWith("ffi_") || testName.startsWith("native_") || testName.startsWith("ts_");
}

function resolveThreshold(
  testName: string,
  benchId: string,
  defaultPct: number
): { threshold_pct: number; threshold_source: ThresholdSource; class: string } {
  const def = benchById(benchId);
  if (def && Number.isFinite(def.regression_threshold_pct)) {
    return {
      threshold_pct: def.regression_threshold_pct,
      threshold_source: "manifest",
      class: def.suite || "manifest",
    };
  }

  const t = testName.toLowerCase();
  if (t.includes("arithmetic") || t.includes("vecdot") || t.includes("matrix") || t.includes("bench")) {
    return { threshold_pct: HOT_THRESHOLD, threshold_source: "heuristic_hot", class: "hot" };
  }
  if (t.includes("timeseries") || t.includes("ode") || t.includes("integration")) {
    return {
      threshold_pct: INTEGRATION_THRESHOLD,
      threshold_source: "heuristic_integration",
      class: "integration",
    };
  }
  return { threshold_pct: defaultPct, threshold_source: "cli_max", class: "default" };
}

function identityFor(row: CompareScoreRow): {
  test_name: string;
  bench_id: string;
  backend: string;
  threads: number;
} {
  const test_name = row.test_name;
  const bench_id = row.bench_id ?? resolveBenchId(test_name);
  const backend = row.backend ?? resolveBackend(test_name);
  const threads = row.threads ?? resolveThreads(test_name);
  return { test_name, bench_id, backend, threads };
}

type Agg = {
  score: number;
  stddev: number;
  samples: number;
  count: number;
  bench_id?: string;
  backend?: string;
  threads?: number;
};

function aggregate(rows: CompareScoreRow[]): Map<string, Agg> {
  const map = new Map<string, Agg>();
  for (const r of rows) {
    const prev = map.get(r.test_name) ?? {
      score: 0,
      stddev: 0,
      samples: 0,
      count: 0,
      bench_id: r.bench_id,
      backend: r.backend,
      threads: r.threads,
    };
    prev.score += r.score;
    prev.stddev += r.ops_stddev ?? 0;
    prev.samples += r.sample_count ?? 1;
    prev.count += 1;
    if (r.bench_id) prev.bench_id = r.bench_id;
    if (r.backend) prev.backend = r.backend;
    if (r.threads != null) prev.threads = r.threads;
    map.set(r.test_name, prev);
  }
  for (const v of map.values()) {
    v.score /= v.count;
    v.stddev /= v.count;
    v.samples /= v.count;
  }
  return map;
}

function loadRowsFromCsv(
  featureId: string,
  suite: Suite,
  csvPath: string,
  machineFilter?: string | null
): CompareScoreRow[] {
  if (!fs.existsSync(csvPath)) {
    throw new Error(`Missing performance CSV: ${csvPath}`);
  }
  const text = fs.readFileSync(csvPath, "utf8");
  const parsed = parseCsvText(text);
  const out: CompareScoreRow[] = [];
  const machines = new Set<string>();
  for (const row of parsed) {
    if (row.featureId !== featureId) continue;
    if (!suiteMatch(row.testName, suite)) continue;
    const score = row.opsP50 ?? row.opsPerSec;
    if (!Number.isFinite(score)) continue;
    // Reconstruct machine_id the same way snapshots do when env columns present.
    const rowMachine =
      row.cpuModel && row.osInfo
        ? `${row.osInfo}-${row.cpuModel}`.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "")
        : null;
    if (rowMachine) machines.add(rowMachine);
    if (machineFilter && rowMachine && rowMachine !== machineFilter) continue;
    out.push({
      test_name: row.testName,
      score,
      ops_stddev: row.opsStddev,
      sample_count: row.sampleCount ?? row.perfSamples ?? 1,
    });
  }
  if (!machineFilter && machines.size > 1) {
    console.warn(
      `compare_performance: feature_id=${featureId} has rows from multiple machines (${[...machines].join(", ")}); ` +
        `pass machine_id to filter. Silent multi-machine mixing is discouraged.`
    );
  }
  return out;
}

/**
 * Resolve effective baseline/after machine ids and enforce isolation policy.
 * Returns the single machine_id to record on the compare document (or null).
 */
export function resolveCompareMachineIds(input: CompareInput): {
  baseline: string | null;
  after: string | null;
  effective: string | null;
  cross_machine: boolean;
} {
  const baseline = input.baseline_machine_id ?? input.machine_id ?? null;
  const after = input.after_machine_id ?? input.machine_id ?? null;
  const cross =
    !!baseline &&
    !!after &&
    baseline !== after;
  return {
    baseline: baseline ?? null,
    after: after ?? null,
    effective: !cross ? (after ?? baseline ?? null) : null,
    cross_machine: cross,
  };
}

/** Convert bench snapshot / package performance results → compare rows. */
export function resultsToCompareRows(results: BenchResult[]): CompareScoreRow[] {
  return results.map((r) => ({
    test_name: r.raw_test_name,
    score: r.ops_p50 ?? r.score,
    ops_stddev: r.ops_stddev,
    sample_count: r.sample_count,
    bench_id: r.bench_id,
    backend: r.backend,
    threads: r.threads,
  }));
}

export function performanceDocToRows(doc: PerformanceDocument | Snapshot): CompareScoreRow[] {
  if ("results" in doc && Array.isArray(doc.results)) {
    if ("status" in doc && doc.status !== "ok" && doc.status !== undefined) {
      return [];
    }
    return resultsToCompareRows(doc.results as BenchResult[]);
  }
  return [];
}

export function comparePerformance(input: CompareInput): PerformanceCompareDocument {
  const suite: Suite = input.suite ?? "all";
  const maxPct = input.max_regression_pct ?? 5;
  const csvPath = input.csv_path ?? PERF_LOG;
  const allowCross = input.allow_cross_machine === true;
  const machines = resolveCompareMachineIds(input);

  if (machines.cross_machine) {
    const msg =
      `compare_performance: cross-machine compare ` +
      `(baseline=${machines.baseline}, after=${machines.after}). ` +
      `Pass allow_cross_machine=true to override.`;
    if (!allowCross) {
      throw new Error(msg);
    }
    console.warn(msg);
  }

  const machineFilter = machines.effective;
  const baselineRows =
    input.baseline_rows ??
    loadRowsFromCsv(input.baseline_feature_id, suite, csvPath, machineFilter);
  const afterRows =
    input.after_rows ?? loadRowsFromCsv(input.after_feature_id, suite, csvPath, machineFilter);

  const base = aggregate(baselineRows);
  const after = aggregate(afterRows);
  const testNames = [...new Set([...base.keys(), ...after.keys()])].sort((a, b) =>
    a.localeCompare(b)
  );

  const rows: PerformanceCompareRow[] = [];
  let failure_count = 0;

  for (const testName of testNames) {
    const b = base.get(testName);
    const a = after.get(testName);
    const sample: CompareScoreRow = {
      test_name: testName,
      score: 0,
      bench_id: a?.bench_id ?? b?.bench_id,
      backend: a?.backend ?? b?.backend,
      threads: a?.threads ?? b?.threads,
    };
    const id = identityFor(sample);
    const { threshold_pct, threshold_source, class: cls } = resolveThreshold(
      testName,
      id.bench_id,
      maxPct
    );

    if (b && !a) {
      rows.push({
        test_name: testName,
        bench_id: id.bench_id,
        backend: id.backend,
        threads: id.threads,
        baseline_score: b.score,
        after_score: null,
        pct_delta: null,
        threshold_pct,
        threshold_source,
        status: "MISSING_AFTER",
        class: cls,
      });
      continue;
    }
    if (!b && a) {
      rows.push({
        test_name: testName,
        bench_id: id.bench_id,
        backend: id.backend,
        threads: id.threads,
        baseline_score: null,
        after_score: a.score,
        pct_delta: null,
        threshold_pct,
        threshold_source,
        status: "NEW_IN_AFTER",
        class: cls,
      });
      continue;
    }
    if (!b || !a) continue;

    const delta = a.score - b.score;
    const pct = b.score === 0 ? 0 : (delta / b.score) * 100;
    const cvAfter = a.score === 0 ? 0 : a.stddev / a.score;
    const relRegression = pct < -threshold_pct;
    const absRegression = delta < -Math.abs(ABS_DROP_OPS);
    const unstable = a.samples >= 3 && cvAfter > UNSTABLE_CV;

    let status: PerformanceCompareRow["status"] = "OK";
    if (relRegression) status = "REGRESSION_REL";
    else if (absRegression) status = "REGRESSION_ABS";
    else if (unstable) status = "UNSTABLE";

    if (status !== "OK") failure_count += 1;

    rows.push({
      test_name: testName,
      bench_id: id.bench_id,
      backend: id.backend,
      threads: id.threads,
      baseline_score: b.score,
      after_score: a.score,
      pct_delta: pct,
      threshold_pct,
      threshold_source,
      status,
      cv_after: cvAfter,
      class: cls,
    });
  }

  const doc: PerformanceCompareDocument = {
    schema_version: 1,
    baseline_version_id: input.baseline_version_id ?? null,
    after_version_id: input.after_version_id ?? null,
    baseline_feature_id: input.baseline_feature_id,
    after_feature_id: input.after_feature_id,
    machine_id: machines.effective ?? input.machine_id ?? null,
    suite,
    source_module: "tools/progress/compare_performance.ts",
    max_regression_pct: maxPct,
    rows,
    failure_count,
  };

  if (input.out_json) {
    const outPath = path.isAbsolute(input.out_json)
      ? input.out_json
      : path.resolve(ROOT, input.out_json);
    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    writeJsonAtomic(outPath, doc);
  }

  return doc;
}

function usage(): never {
  console.error(
    "Usage: bun tools/progress/compare_performance.ts <baseline_feature_id> <after_feature_id> [max_regression_pct] [suite]"
  );
  process.exit(2);
}

if (import.meta.main) {
  const baselineId = process.argv[2];
  const afterId = process.argv[3];
  const maxRegressionPct = Number(process.argv[4] ?? "5");
  const suite = (process.argv[5] ?? "all") as Suite;

  if (!baselineId || !afterId) usage();
  if (!Number.isFinite(maxRegressionPct)) usage();
  if (suite !== "all" && suite !== "zig" && suite !== "ts") usage();

  const outJson = path.resolve(
    ROOT,
    "tests/artifacts/performance",
    `${afterId}_vs_${baselineId}.json`
  );

  const doc = comparePerformance({
    baseline_feature_id: baselineId,
    after_feature_id: afterId,
    suite,
    max_regression_pct: maxRegressionPct,
    out_json: outJson,
  });

  console.log(
    JSON.stringify(
      {
        out: path.relative(ROOT, outJson),
        rows: doc.rows.length,
        failure_count: doc.failure_count,
        suite: doc.suite,
      },
      null,
      2
    )
  );

  if (doc.failure_count > 0) {
    console.error(`Detected ${doc.failure_count} failing perf checks`);
    process.exit(1);
  }
}
