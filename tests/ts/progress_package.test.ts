import { afterAll, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { StepsDocument } from "../../tools/testing/feature_gate_steps.ts";
import { writeJsonAtomic } from "../../tools/testing/feature_gate_steps.ts";
import { buildProgressIndex } from "../../tools/progress/build_progress_index.ts";
import {
  comparePerformance,
  resultsToCompareRows,
} from "../../tools/progress/compare_performance.ts";
import {
  buildVersionId,
  evaluateCorrectness,
  findLatestSnapshotForFeature,
  scanMaxSeq,
  summarizeParityCsv,
  writePackage,
} from "../../tools/progress/write_package.ts";
import type {
  MetaDocument,
  PerformanceCompareDocument,
  PerformanceDocument,
  ProgressIndex,
} from "../../tools/progress/types.ts";
import type { Snapshot } from "../../tools/bench/types.ts";

const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "mathzig-progress-"));
const progressDir = path.join(tmpRoot, "progress");
const parityDir = path.join(tmpRoot, "parity");
const snapshotsDir = path.join(tmpRoot, "snapshots");

afterAll(() => {
  fs.rmSync(tmpRoot, { recursive: true, force: true });
});

function makeSteps(overrides: Partial<StepsDocument> = {}): StepsDocument {
  return {
    schema_version: 1,
    feature_id: "0101_new_feature_t1",
    started_at: "2026-07-09T12:00:00.000Z",
    finished_at: "2026-07-09T12:10:00.000Z",
    baseline_feature_id: "prev_feature",
    baseline_source: "explicit",
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
        log: "tests/artifacts/runs/0101_new_feature_t1/zig_vm_baseline.log",
        reason: null,
      },
      {
        id: "zig_tests",
        status: "pass",
        duration_sec: 10,
        command: ["zig", "build", "test", "--summary", "all"],
        log: "tests/artifacts/runs/0101_new_feature_t1/zig_tests.log",
        reason: null,
      },
      {
        id: "ts_tests",
        status: "pass",
        duration_sec: 5,
        command: ["bun", "test"],
        log: "tests/artifacts/runs/0101_new_feature_t1/ts_tests.log",
        reason: null,
      },
      {
        id: "parity_full",
        status: "pass",
        duration_sec: 30,
        command: ["bun", "tests/parity/cli.ts", "--full"],
        log: "tests/artifacts/runs/0101_new_feature_t1/parity_full.log",
        reason: null,
      },
      {
        id: "perf_zig_record",
        status: "pass",
        duration_sec: 20,
        command: ["bun", "tests/performance/record_performance.ts", "0101_new_feature_t1", "zig"],
        log: "tests/artifacts/runs/0101_new_feature_t1/perf_zig_record.log",
        reason: null,
      },
    ],
    final_status: "pass",
    artifacts: {
      parity_report: "tests/artifacts/parity/0101_new_feature_t1_report.md",
      perf_log: "tests/artifacts/performance/performance_log.csv",
      perf_compare: "tests/artifacts/performance/0101_new_feature_t1_vs_prev_feature.md",
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

const FIXTURE_FEATURE = `pr1_pkg_${process.pid}`;

function plantParityCsv(featureId: string, backend: string, statuses: string[]) {
  fs.mkdirSync(parityDir, { recursive: true });
  const p = path.join(parityDir, `${featureId}_${backend}.csv`);
  const lines = ["id,expr,status,reason"];
  statuses.forEach((st, i) => {
    lines.push(`case_${i},"1 + ${i}, x",${st},`);
  });
  fs.writeFileSync(p, `${lines.join("\n")}\n`, "utf8");
  return p;
}

function plantStaleWasmCsv(featureId: string) {
  return plantParityCsv(featureId, "ts_wasm_vm", ["PASS", "PASS", "SKIP"]);
}

function makeSnapshot(featureId: string, gitSha = "7b56744"): Snapshot {
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
        score: 1e8,
        unit: "ops/s",
        iterations: 1000,
        duration_ms: 1,
        ops_p50: 1e8,
        ops_p95: 1.1e8,
        ops_stddev: 1e6,
        sample_count: 5,
        mem_peak: 88,
      },
      {
        bench_id: "arith.batch_simd",
        backend: "mathzig_zig",
        threads: 1,
        raw_test_name: "zig_arithmetic_batch_simd_t1",
        score: 2e8,
        unit: "ops/s",
        iterations: 1000,
        duration_ms: 1,
        ops_p50: 2e8,
        sample_count: 5,
        mem_peak: 100,
      },
    ],
  };
}

function pkgOpts(extra: Parameters<typeof writePackage>[0]) {
  return {
    progressDir,
    parityArtifactsDir: parityDir,
    snapshotsDir,
    ...extra,
  };
}

const VERSION_ID_RE =
  /^\d{8}__\d{8}T\d{6}Z__[a-z0-9_]+__[0-9a-f]+$/;

describe("progress package writer", () => {
  test("1. build package from fixture steps (pass) → version_id pattern + files exist", () => {
    const featureId = `${FIXTURE_FEATURE}_pass`;
    const steps = makeSteps({ feature_id: featureId, parity_backends: ["zig_vm", "ts_ffi"] });
    const stepsPath = writeFixtureSteps(featureId, steps);
    plantParityCsv(featureId, "zig_vm", ["PASS", "PASS", "FAIL"]);
    plantParityCsv(featureId, "ts_ffi", ["PASS", "SKIP"]);

    const snapPath = path.join(tmpRoot, "snap_pass.json");
    writeJsonAtomic(snapPath, makeSnapshot(featureId));

    const result = writePackage(
      pkgOpts({
        featureId,
        stepsPath,
        snapshotPath: snapPath,
        gitSha: "7b56744abcdef",
        recordedAt: "2026-07-09T14:15:30.000Z",
      })
    );

    expect(result.version_id).toMatch(VERSION_ID_RE);
    expect(result.seq).toBe(1);
    expect(result.version_id.startsWith("00000001__")).toBe(true);
    expect(result.version_id).toContain("20260709T141530Z");
    expect(result.version_id).toContain(featureId);
    // version_id ends with short git sha from gitSha option
    expect(result.version_id.endsWith("__7b56744")).toBe(true);
    expect(result.status).toBe("pass");
    expect(result.has_performance).toBe(true);

    const pkgDir = result.package_dir;
    for (const f of [
      "meta.json",
      "correctness.json",
      "features.json",
      "performance.json",
      "summary.md",
    ]) {
      expect(fs.existsSync(path.join(pkgDir, f))).toBe(true);
    }

    const meta = JSON.parse(fs.readFileSync(path.join(pkgDir, "meta.json"), "utf8")) as MetaDocument;
    expect(meta.seq).toBe(1);
    expect(meta.sort_key).toBe(result.version_id);
    // label is the automatic tag / feature_id (not the git short sha)
    expect(meta.label).toBe(featureId);
    expect(meta.git_sha).toBe("7b56744");
    expect(meta.version_id).toBe(result.version_id);
    expect(meta.parity_backends_executed).toEqual(["zig_vm", "ts_ffi"]);
    expect(meta.has_performance).toBe(true);
    expect(meta.mathzig_version.length).toBeGreaterThan(0);

    const correctness = JSON.parse(fs.readFileSync(path.join(pkgDir, "correctness.json"), "utf8"));
    expect(correctness.overall).toBe("pass");
    expect(correctness.parity.backends_executed).toEqual(["zig_vm", "ts_ffi"]);
    expect(correctness.parity.backends.zig_vm.pass).toBe(2);
    expect(correctness.parity.backends.zig_vm.fail).toBe(1);
    expect(correctness.parity.backends.ts_ffi.skip).toBe(1);

    const features = JSON.parse(fs.readFileSync(path.join(pkgDir, "features.json"), "utf8"));
    // PR2: real matrix from catalog (not empty stub)
    expect(features.cells.length).toBeGreaterThanOrEqual(15);
    expect(features.catalog_hash).toMatch(/^sha256:[0-9a-f]{64}$/);
    expect(features.backends_executed).toEqual(["zig_vm", "ts_ffi"]);
    expect(features.backends).toContain("zig_vm");
    // Non-executed matrix backends stay unknown (stale CSV hard rule)
    expect(features.summary.ts_wasm_vm.unknown).toBeGreaterThan(0);
    expect(features.seq).toBe(1);

    const perf = JSON.parse(
      fs.readFileSync(path.join(pkgDir, "performance.json"), "utf8")
    ) as PerformanceDocument;
    expect(perf.status).toBe("ok");
    if (perf.status === "ok") {
      expect(perf.results.length).toBe(2);
    }
  });

  test("2. fail correctness → has_performance false, performance skipped", () => {
    const featureId = `${FIXTURE_FEATURE}_fail`;
    const steps = makeSteps({
      feature_id: featureId,
      final_status: "fail",
      steps: [
        {
          id: "zig_vm_baseline",
          status: "pass",
          duration_sec: 1,
          command: ["zig", "build", "vm-baseline", "--summary", "all"],
          log: "x.log",
          reason: null,
        },
        {
          id: "zig_tests",
          status: "fail",
          duration_sec: 2,
          command: ["zig", "build", "test", "--summary", "all"],
          log: "y.log",
          reason: null,
        },
        {
          id: "ts_tests",
          status: "skipped",
          duration_sec: null,
          command: null,
          log: null,
          reason: "prior step failed",
        },
        {
          id: "parity_full",
          status: "skipped",
          duration_sec: null,
          command: null,
          log: null,
          reason: "prior step failed",
        },
        {
          id: "perf_zig_record",
          status: "skipped",
          duration_sec: null,
          command: null,
          log: null,
          reason: "correctness gate failed",
        },
      ],
    });
    const stepsPath = writeFixtureSteps(featureId, steps);

    const result = writePackage(
      pkgOpts({
        featureId,
        stepsPath,
        gitSha: "deadbeef",
        recordedAt: "2026-07-09T15:00:00.000Z",
        snapshotPath: path.join(tmpRoot, "should_not_use.json"),
      })
    );

    expect(result.status).toBe("fail");
    expect(result.has_performance).toBe(false);
    expect(result.meta.has_performance).toBe(false);

    const perf = JSON.parse(
      fs.readFileSync(path.join(result.package_dir, "performance.json"), "utf8")
    ) as PerformanceDocument;
    expect(perf.status).toBe("skipped");
    if (perf.status === "skipped") {
      expect(perf.reason).toBe("correctness_failed");
    }
  });

  test("2b. correctness steps pass + final_status fail (perf/overview) → correctness pass, perf embedded", () => {
    const featureId = `${FIXTURE_FEATURE}_final_fail`;
    const steps = makeSteps({
      feature_id: featureId,
      // Gate failed on post-correctness step only
      final_status: "fail",
      steps: [
        ...makeSteps().steps.slice(0, 4), // four correctness steps pass
        {
          id: "perf_zig_record",
          status: "pass",
          duration_sec: 5,
          command: ["bun", "record"],
          log: "p.log",
          reason: null,
        },
        {
          id: "perf_compare",
          status: "fail",
          duration_sec: 1,
          command: ["bun", "compare"],
          log: "c.log",
          reason: null,
        },
      ],
    });
    // Ensure four correctness ids are pass
    for (const id of ["zig_vm_baseline", "zig_tests", "ts_tests", "parity_full"]) {
      const s = steps.steps.find((x) => x.id === id)!;
      s.status = "pass";
      s.duration_sec = 1;
      s.command = ["x"];
      s.log = "l.log";
      s.reason = null;
    }
    const stepsPath = writeFixtureSteps(featureId, steps);
    plantParityCsv(featureId, "zig_vm", ["PASS"]);
    plantParityCsv(featureId, "ts_ffi", ["PASS"]);
    const snapPath = path.join(tmpRoot, "snap_final_fail.json");
    writeJsonAtomic(snapPath, makeSnapshot(featureId));

    const evaluated = evaluateCorrectness(steps);
    expect(evaluated.overall).toBe("pass");

    const result = writePackage(
      pkgOpts({
        featureId,
        stepsPath,
        snapshotPath: snapPath,
        gitSha: "cafebabe",
        recordedAt: "2026-07-09T15:30:00.000Z",
      })
    );

    expect(result.status).toBe("pass");
    expect(result.has_performance).toBe(true);
    const correctness = JSON.parse(
      fs.readFileSync(path.join(result.package_dir, "correctness.json"), "utf8")
    );
    expect(correctness.overall).toBe("pass");
    const perf = JSON.parse(
      fs.readFileSync(path.join(result.package_dir, "performance.json"), "utf8")
    ) as PerformanceDocument;
    expect(perf.status).toBe("ok");
  });

  test("3. re-run same feature → new seq, two packages on disk", () => {
    const featureId = `${FIXTURE_FEATURE}_rerun`;
    const steps = makeSteps({ feature_id: featureId });
    const stepsPath = writeFixtureSteps(featureId, steps);
    plantParityCsv(featureId, "zig_vm", ["PASS"]);
    plantParityCsv(featureId, "ts_ffi", ["PASS"]);
    const snapPath = path.join(tmpRoot, "snap_rerun.json");
    writeJsonAtomic(snapPath, makeSnapshot(featureId));

    const r1 = writePackage(
      pkgOpts({
        featureId,
        stepsPath,
        snapshotPath: snapPath,
        gitSha: "aaaaaaa1",
        recordedAt: "2026-07-09T16:00:00.000Z",
      })
    );
    const r2 = writePackage(
      pkgOpts({
        featureId,
        stepsPath,
        snapshotPath: snapPath,
        gitSha: "aaaaaaa1",
        recordedAt: "2026-07-09T16:00:01.000Z",
      })
    );

    expect(r2.seq).toBe(r1.seq + 1);
    expect(r2.version_id).not.toBe(r1.version_id);
    expect(fs.existsSync(r1.package_dir)).toBe(true);
    expect(fs.existsSync(r2.package_dir)).toBe(true);
    expect(scanMaxSeq(path.join(progressDir, "packages"))).toBeGreaterThanOrEqual(r2.seq);
  });

  test("4. index sorted by seq", () => {
    const index = buildProgressIndex(progressDir) as ProgressIndex;
    expect(index.schema_version).toBe(1);
    expect(index.packages.length).toBeGreaterThanOrEqual(2);

    for (let i = 1; i < index.packages.length; i += 1) {
      expect(index.packages[i].seq).toBeGreaterThanOrEqual(index.packages[i - 1].seq);
    }

    const indexFile = path.join(progressDir, "index.json");
    expect(fs.existsSync(indexFile)).toBe(true);
    const onDisk = JSON.parse(fs.readFileSync(indexFile, "utf8")) as ProgressIndex;
    expect(onDisk.packages.map((p) => p.seq)).toEqual(index.packages.map((p) => p.seq));
  });

  test("5. never use non-executed backend CSV; missing snapshot → partial", () => {
    const featureId = `${FIXTURE_FEATURE}_stale`;
    const steps = makeSteps({
      feature_id: featureId,
      parity_backends: ["zig_vm"],
    });
    const stepsPath = writeFixtureSteps(featureId, steps);
    plantParityCsv(featureId, "zig_vm", ["PASS", "PASS"]);
    plantStaleWasmCsv(featureId);

    const result = writePackage(
      pkgOpts({
        featureId,
        stepsPath,
        gitSha: "bbbbbbb",
        recordedAt: "2026-07-09T17:00:00.000Z",
        // no snapshot → partial status
      })
    );

    expect(result.status).toBe("partial");
    expect(result.has_performance).toBe(false);

    const correctness = JSON.parse(
      fs.readFileSync(path.join(result.package_dir, "correctness.json"), "utf8")
    );
    expect(correctness.overall).toBe("pass");
    expect(correctness.parity.backends_executed).toEqual(["zig_vm"]);
    expect(Object.keys(correctness.parity.backends)).toEqual(["zig_vm"]);
    expect(correctness.parity.backends.ts_wasm_vm).toBeUndefined();
    expect(correctness.parity.backends_not_executed).toContain("ts_wasm_vm");
    expect(correctness.parity.backends_not_executed).toContain("ts_ffi");
    expect(result.meta.parity_backends_executed).toEqual(["zig_vm"]);

    const perf = JSON.parse(
      fs.readFileSync(path.join(result.package_dir, "performance.json"), "utf8")
    ) as PerformanceDocument;
    expect(perf.status).toBe("error");
    if (perf.status === "error") {
      expect(perf.reason).toBe("missing_snapshot");
    }
  });

  test("snapshot lookup does not match unrelated feature prefix", () => {
    fs.mkdirSync(snapshotsDir, { recursive: true });
    const shortId = `${FIXTURE_FEATURE}_feat`;
    const longId = `${FIXTURE_FEATURE}_feat_extra`;
    writeJsonAtomic(path.join(snapshotsDir, `${longId}_abc1234.json`), makeSnapshot(longId, "abc1234"));
    // No snapshot for shortId — must not pick longId by loose prefix
    expect(findLatestSnapshotForFeature(shortId, snapshotsDir)).toBeNull();

    writeJsonAtomic(path.join(snapshotsDir, `${shortId}_def5678.json`), makeSnapshot(shortId, "def5678"));
    const found = findLatestSnapshotForFeature(shortId, snapshotsDir);
    expect(found).not.toBeNull();
    expect(found!).toContain(`${shortId}_def5678`);
  });

  test("version_id builder format", () => {
    const id = buildVersionId({
      seq: 42,
      recordedAt: "2026-07-09T14:15:30.123Z",
      slug: "0101_new_feature_t1",
      shortSha: "7b56744",
    });
    expect(id).toBe("00000042__20260709T141530Z__0101_new_feature_t1__7b56744");
  });

  test("summarizeParityCsv handles quoted commas", () => {
    const p = path.join(tmpRoot, "quoted.csv");
    fs.writeFileSync(
      p,
      [
        "id,expr,status,reason",
        `a,"1, 2, 3",PASS,`,
        `b,"x = ""hi""",FAIL,oops`,
        `c,plain,SKIP,`,
      ].join("\n"),
      "utf8"
    );
    const c = summarizeParityCsv(p);
    expect(c.pass).toBe(1);
    expect(c.fail).toBe(1);
    expect(c.skip).toBe(1);
    expect(c.total).toBe(3);
  });
});

describe("compare_performance structured SoT", () => {
  test("6. returns structured rows with status field + manifest threshold", () => {
    const baseline = resultsToCompareRows(makeSnapshot("base").results);
    const afterResults = makeSnapshot("after").results.map((r, i) => ({
      ...r,
      score: i === 0 ? r.score * 0.5 : r.score * 1.2,
      ops_p50: i === 0 ? r.ops_p50 * 0.5 : (r.ops_p50 ?? r.score) * 1.2,
    }));
    const after = resultsToCompareRows(afterResults);

    const doc: PerformanceCompareDocument = comparePerformance({
      baseline_feature_id: "base_feat",
      after_feature_id: "after_feat",
      suite: "zig",
      max_regression_pct: 5,
      baseline_rows: baseline,
      after_rows: after,
      machine_id: "darwin-arm64-test",
    });

    expect(doc.schema_version).toBe(1);
    expect(doc.source_module).toContain("compare_performance");
    expect(doc.rows.length).toBe(2);
    expect(doc.failure_count).toBeGreaterThanOrEqual(1);

    for (const row of doc.rows) {
      expect(row).toHaveProperty("status");
      expect(row).toHaveProperty("bench_id");
      expect(row).toHaveProperty("backend");
      expect(row).toHaveProperty("threads");
      expect(row).toHaveProperty("threshold_pct");
      expect(row).toHaveProperty("threshold_source");
      expect([
        "OK",
        "REGRESSION_REL",
        "REGRESSION_ABS",
        "UNSTABLE",
        "MISSING_AFTER",
        "NEW_IN_AFTER",
      ]).toContain(row.status);
    }

    const reg = doc.rows.find((r) => r.test_name.includes("arithmetic_scalar"));
    expect(reg).toBeDefined();
    expect(reg!.status).toBe("REGRESSION_REL");
    expect(reg!.bench_id).toBe("arith.scalar");
    expect(reg!.backend).toBe("mathzig_zig");
    expect(reg!.threshold_source).toBe("manifest");
    expect(reg!.threshold_pct).toBe(3);
  });

  test("missing after / new in after statuses", () => {
    const doc = comparePerformance({
      baseline_feature_id: "b",
      after_feature_id: "a",
      baseline_rows: [{ test_name: "zig_only_base", score: 100 }],
      after_rows: [{ test_name: "zig_only_after", score: 200 }],
      suite: "all",
    });
    expect(doc.rows.find((r) => r.test_name === "zig_only_base")?.status).toBe("MISSING_AFTER");
    expect(doc.rows.find((r) => r.test_name === "zig_only_after")?.status).toBe("NEW_IN_AFTER");
  });

  test("refuses silent cross-machine compare unless allowed", () => {
    const rows = [{ test_name: "zig_arithmetic_scalar_fast_t1", score: 100 }];
    expect(() =>
      comparePerformance({
        baseline_feature_id: "b",
        after_feature_id: "a",
        baseline_rows: rows,
        after_rows: rows,
        baseline_machine_id: "machine-a",
        after_machine_id: "machine-b",
        allow_cross_machine: false,
      })
    ).toThrow(/cross-machine/);

    const doc = comparePerformance({
      baseline_feature_id: "b",
      after_feature_id: "a",
      baseline_rows: rows,
      after_rows: rows,
      baseline_machine_id: "machine-a",
      after_machine_id: "machine-b",
      allow_cross_machine: true,
    });
    expect(doc.rows.length).toBe(1);
  });
});
