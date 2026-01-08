import { afterAll, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { StepsDocument } from "../../tools/testing/feature_gate_steps.ts";
import { writeJsonAtomic } from "../../tools/testing/feature_gate_steps.ts";
import {
  aggregateStatusHistogram,
  buildAppData,
  loadPackagesSorted,
} from "../../tools/progress/build_app_data.ts";
import { writePackage } from "../../tools/progress/write_package.ts";
import type {
  AppDataIndex,
  AppDataPackages,
  AppDataSeries,
  FeaturesDocument,
  SlimPackage,
} from "../../tools/progress/types.ts";
import type { Snapshot } from "../../tools/bench/types.ts";

const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "mathzig-app-data-"));
const progressDir = path.join(tmpRoot, "progress");
const parityDir = path.join(tmpRoot, "parity");
const outDir = path.join(tmpRoot, "public-data");

afterAll(() => {
  fs.rmSync(tmpRoot, { recursive: true, force: true });
});

function makeSteps(featureId: string, overrides: Partial<StepsDocument> = {}): StepsDocument {
  return {
    schema_version: 1,
    feature_id: featureId,
    started_at: "2026-07-09T12:00:00.000Z",
    finished_at: "2026-07-09T12:10:00.000Z",
    baseline_feature_id: null,
    baseline_source: "none",
    max_regression_pct: "5",
    parity_backends: ["zig_vm", "ts_ffi"],
    bench_mode: "zig",
    bench_tier: "smoke",
    perf_strict: false,
    steps: [
      {
        id: "zig_vm_baseline",
        status: "pass",
        duration_sec: 2,
        command: ["zig", "build", "vm-baseline", "--summary", "all"],
        log: `tests/artifacts/runs/${featureId}/zig_vm_baseline.log`,
        reason: null,
      },
      {
        id: "zig_tests",
        status: "pass",
        duration_sec: 10,
        command: ["zig", "build", "test", "--summary", "all"],
        log: `tests/artifacts/runs/${featureId}/zig_tests.log`,
        reason: null,
      },
      {
        id: "ts_tests",
        status: "pass",
        duration_sec: 5,
        command: ["bun", "test"],
        log: `tests/artifacts/runs/${featureId}/ts_tests.log`,
        reason: null,
      },
      {
        id: "parity_full",
        status: "pass",
        duration_sec: 30,
        command: ["bun", "tests/parity/cli.ts", "--full"],
        log: `tests/artifacts/runs/${featureId}/parity_full.log`,
        reason: null,
      },
      {
        id: "perf_zig_record",
        status: "pass",
        duration_sec: 20,
        command: ["bun", "tests/performance/record_performance.ts", featureId, "zig"],
        log: `tests/artifacts/runs/${featureId}/perf_zig_record.log`,
        reason: null,
      },
    ],
    final_status: "pass",
    artifacts: {
      parity_report: `tests/artifacts/parity/${featureId}_report.md`,
      perf_log: "tests/artifacts/performance/performance_log.csv",
      perf_compare: null,
      overview: "tests/artifacts/testing_overview/latest.md",
    },
    ...overrides,
  };
}

function writeFixtureSteps(featureId: string, doc: StepsDocument): string {
  const stepsPath = path.join(tmpRoot, "runs", featureId, "steps.json");
  fs.mkdirSync(path.dirname(stepsPath), { recursive: true });
  writeJsonAtomic(stepsPath, doc);
  return stepsPath;
}

function plantParityCsv(featureId: string, backend: string, statuses: string[]) {
  fs.mkdirSync(parityDir, { recursive: true });
  const p = path.join(parityDir, `${featureId}_${backend}.csv`);
  const lines = ["id,expr,status,reason"];
  statuses.forEach((st, i) => {
    lines.push(`case_${i},"1 + ${i}",${st},`);
  });
  fs.writeFileSync(p, `${lines.join("\n")}\n`, "utf8");
  return p;
}

function makeSnapshot(featureId: string, scoreScale: number, gitSha = "abc1234"): Snapshot {
  return {
    snapshot: {
      id: `${featureId}_${gitSha}`,
      kind: "dev",
      git_tag: null,
      git_sha: gitSha,
      feature_id: featureId,
      recorded_at: "2026-07-09T12:05:00.000Z",
      machine_id: "darwin-arm64-test",
      tier: "smoke",
      cpu_model: "Test CPU",
      cpu_cores: 4,
      os: "darwin-arm64",
      zig_version: "0.15.2",
      bun_version: "1.3.9",
      perf_samples: 5,
    },
    results: [
      {
        bench_id: "arith.scalar",
        backend: "mathzig_zig",
        threads: 1,
        raw_test_name: "zig_arithmetic_scalar_fast_t1",
        score: 1e8 * scoreScale,
        unit: "ops/s",
        iterations: 1000,
        duration_ms: 1,
        ops_p50: 1e8 * scoreScale,
        ops_p95: 1.1e8 * scoreScale,
        ops_stddev: 1e6,
        sample_count: 5,
        mem_peak: 88,
      },
      {
        bench_id: "arith.batch_simd",
        backend: "mathzig_zig",
        threads: 1,
        raw_test_name: "zig_arithmetic_batch_simd_t1",
        score: 2e8 * scoreScale,
        unit: "ops/s",
        iterations: 1000,
        duration_ms: 1,
        ops_p50: 2e8 * scoreScale,
        sample_count: 5,
        mem_peak: 100,
      },
    ],
  };
}

const FIXTURE = `app_data_${process.pid}`;

describe("build_app_data", () => {
  test("writes index sorted by seq + series keys from two packages", () => {
    const f1 = `${FIXTURE}_v1`;
    const f2 = `${FIXTURE}_v2`;

    const steps1 = makeSteps(f1);
    const stepsPath1 = writeFixtureSteps(f1, steps1);
    plantParityCsv(f1, "zig_vm", ["PASS", "PASS"]);
    plantParityCsv(f1, "ts_ffi", ["PASS"]);
    const snap1 = path.join(tmpRoot, "snap1.json");
    writeJsonAtomic(snap1, makeSnapshot(f1, 1.0, "1111111"));

    const r1 = writePackage({
      featureId: f1,
      stepsPath: stepsPath1,
      progressDir,
      parityArtifactsDir: parityDir,
      snapshotPath: snap1,
      gitSha: "1111111abcdef",
      recordedAt: "2026-07-09T10:00:00.000Z",
    });

    const steps2 = makeSteps(f2);
    const stepsPath2 = writeFixtureSteps(f2, steps2);
    plantParityCsv(f2, "zig_vm", ["PASS", "PASS", "PASS"]);
    plantParityCsv(f2, "ts_ffi", ["PASS", "PASS"]);
    const snap2 = path.join(tmpRoot, "snap2.json");
    writeJsonAtomic(snap2, makeSnapshot(f2, 1.1, "2222222"));

    const r2 = writePackage({
      featureId: f2,
      stepsPath: stepsPath2,
      progressDir,
      parityArtifactsDir: parityDir,
      snapshotPath: snap2,
      gitSha: "2222222abcdef",
      recordedAt: "2026-07-09T11:00:00.000Z",
    });

    expect(r2.seq).toBeGreaterThan(r1.seq);

    // Staging / no-meta package must be skipped
    const ghostDir = path.join(progressDir, "packages", ".tmp-ghost");
    fs.mkdirSync(ghostDir, { recursive: true });
    fs.writeFileSync(path.join(ghostDir, "meta.json"), '{"version_id":"ghost"}', "utf8");
    const noMeta = path.join(progressDir, "packages", "no_meta_pkg");
    fs.mkdirSync(noMeta, { recursive: true });
    fs.writeFileSync(path.join(noMeta, "correctness.json"), "{}", "utf8");

    const result = buildAppData({
      progressDir,
      outDir,
      quiet: true,
    });

    expect(result.package_count).toBe(2);
    expect(result.files).toEqual([
      "index.json",
      "packages.json",
      "series.json",
      "features_latest.json",
      "latest_compare.json",
    ]);
    expect(result.mixed_machines).toBe(false);
    expect(result.machine_ids.length).toBeGreaterThanOrEqual(1);

    // index.json sorted by seq
    const index = JSON.parse(
      fs.readFileSync(path.join(outDir, "index.json"), "utf8")
    ) as AppDataIndex;
    expect(index.schema_version).toBe(1);
    expect(index.package_count).toBe(2);
    expect(index.packages.length).toBe(2);
    expect(index.packages[0]!.seq).toBeLessThan(index.packages[1]!.seq);
    expect(index.packages.map((p) => p.version_id)).toEqual([r1.version_id, r2.version_id]);
    expect(index.mixed_machines).toBe(false);

    // packages.json slim: no step logs
    const packagesDoc = JSON.parse(
      fs.readFileSync(path.join(outDir, "packages.json"), "utf8")
    ) as AppDataPackages;
    expect(Object.keys(packagesDoc.packages).sort()).toEqual(
      [r1.version_id, r2.version_id].sort()
    );
    const slim1 = packagesDoc.packages[r1.version_id] as SlimPackage;
    expect(slim1.meta.version_id).toBe(r1.version_id);
    expect(slim1.correctness.overall).toBe("pass");
    expect(slim1.correctness.steps[0]).not.toHaveProperty("log");
    expect(slim1.correctness.parity.backends.zig_vm).toMatchObject({
      pass: 2,
      fail: 0,
    });
    expect(slim1.correctness.parity.backends.zig_vm).not.toHaveProperty("csv");
    expect(slim1.performance.status).toBe("ok");
    expect(slim1.performance.results.length).toBe(2);
    expect(slim1.features).not.toBeNull();
    expect(slim1.features!.cell_count).toBeGreaterThan(0);
    // slim features has summary, not full cells
    expect(slim1.features).not.toHaveProperty("cells");

    // series.json keys
    const series = JSON.parse(
      fs.readFileSync(path.join(outDir, "series.json"), "utf8")
    ) as AppDataSeries;
    expect(series.schema_version).toBe(1);
    expect(Object.keys(series.series).sort()).toEqual(["arith.batch_simd", "arith.scalar"]);
    expect(result.series_bench_ids).toEqual(["arith.batch_simd", "arith.scalar"]);

    const scalarZig = series.series["arith.scalar"]!["mathzig_zig"]!;
    expect(scalarZig.length).toBe(2);
    expect(scalarZig[0]!.seq).toBeLessThan(scalarZig[1]!.seq);
    expect(scalarZig[0]!.version_id).toBe(r1.version_id);
    expect(scalarZig[1]!.version_id).toBe(r2.version_id);
    expect(scalarZig[0]!.score).toBe(1e8);
    expect(scalarZig[1]!.score).toBeCloseTo(1.1e8, 0);
    expect(scalarZig[0]!.threads).toBe(1);

    // features_latest = latest package features
    const featuresLatest = JSON.parse(
      fs.readFileSync(path.join(outDir, "features_latest.json"), "utf8")
    ) as FeaturesDocument;
    expect(featuresLatest.version_id).toBe(r2.version_id);
    expect(featuresLatest.cells.length).toBeGreaterThan(0);
    expect(result.features_latest_version_id).toBe(r2.version_id);

    const loaded = loadPackagesSorted(progressDir);
    expect(loaded.length).toBe(2);
    expect(loaded[0]!.meta.seq).toBeLessThan(loaded[1]!.meta.seq);
  });

  test("empty progress dir writes empty stubs", () => {
    const emptyProgress = path.join(tmpRoot, "empty-progress");
    const emptyOut = path.join(tmpRoot, "empty-out");
    fs.mkdirSync(path.join(emptyProgress, "packages"), { recursive: true });

    const result = buildAppData({
      progressDir: emptyProgress,
      outDir: emptyOut,
      quiet: true,
    });

    expect(result.package_count).toBe(0);
    expect(result.series_bench_ids).toEqual([]);
    expect(result.features_latest_version_id).toBeNull();

    const index = JSON.parse(
      fs.readFileSync(path.join(emptyOut, "index.json"), "utf8")
    ) as AppDataIndex;
    expect(index.packages).toEqual([]);
    expect(index.machine_ids).toEqual([]);

    const series = JSON.parse(
      fs.readFileSync(path.join(emptyOut, "series.json"), "utf8")
    ) as AppDataSeries;
    expect(series.series).toEqual({});

    const features = JSON.parse(
      fs.readFileSync(path.join(emptyOut, "features_latest.json"), "utf8")
    ) as FeaturesDocument;
    expect(features.cells).toEqual([]);
    expect(features.version_id).toBe("");
  });

  test("aggregateStatusHistogram sums backends", () => {
    const agg = aggregateStatusHistogram({
      zig_vm: {
        done: 2,
        partial: 1,
        broken: 0,
        skipped: 0,
        missing: 0,
        "n/a": 0,
        unknown: 3,
      },
      ts_ffi: {
        done: 1,
        partial: 0,
        broken: 1,
        skipped: 0,
        missing: 0,
        "n/a": 0,
        unknown: 4,
      },
    });
    expect(agg.done).toBe(3);
    expect(agg.partial).toBe(1);
    expect(agg.broken).toBe(1);
    expect(agg.unknown).toBe(7);
  });
});
