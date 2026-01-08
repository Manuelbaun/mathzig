import { afterAll, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  buildFeaturesDocument,
  catalogHash,
  loadAllCaseFiles,
  loadCatalog,
  matchFeatureCases,
  parseParityCsvById,
  type CatalogFeature,
  type FeatureCatalog,
} from "../../tools/progress/build_features.ts";
import {
  applyDecisionTable,
  decideFeatureStatus,
  type CaseRef,
} from "../../tools/progress/feature_status.ts";
import {
  buildParityCliArgs,
  readPackageBackendsExecuted,
  resolveBackendsExecuted,
} from "../../tools/progress/features_matrix_refresh.ts";
import type { FeaturesDocument } from "../../tools/progress/types.ts";
import { writePackage } from "../../tools/progress/write_package.ts";
import type { StepsDocument } from "../../tools/testing/feature_gate_steps.ts";
import { writeJsonAtomic } from "../../tools/testing/feature_gate_steps.ts";

const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "mathzig-features-"));
const casesDir = path.join(tmpRoot, "cases");
const parityDir = path.join(tmpRoot, "parity");
const catalogPath = path.join(tmpRoot, "catalog.json");

afterAll(() => {
  fs.rmSync(tmpRoot, { recursive: true, force: true });
});

function writeCases(file: string, cases: CaseRef[]): void {
  fs.mkdirSync(casesDir, { recursive: true });
  // Case files need full-ish shape for loadCaseFile; only id/skip matter.
  const body = cases.map((c) => ({
    id: c.id,
    expr: "1",
    expected: { tag: "number" },
    ...(c.skip ? { skip: c.skip } : {}),
  }));
  fs.writeFileSync(path.join(casesDir, file), JSON.stringify(body, null, 2), "utf8");
}

function writeCsv(
  taskId: string,
  backend: string,
  rows: Array<{ id: string; status: string; expr?: string }>
): string {
  fs.mkdirSync(parityDir, { recursive: true });
  const p = path.join(parityDir, `${taskId}_${backend}.csv`);
  const lines = ["id,expr,status,reason"];
  for (const r of rows) {
    const expr = r.expr ?? "1 + 1";
    // Quote expr so commas are safe
    lines.push(`${r.id},"${expr.replace(/"/g, '""')}",${r.status},`);
  }
  fs.writeFileSync(p, `${lines.join("\n")}\n`, "utf8");
  return p;
}

function miniCatalog(features: CatalogFeature[]): FeatureCatalog {
  return {
    schema_version: 1,
    backends: [
      { id: "zig_vm", kind: "correctness", matrix_column: true },
      { id: "ts_ffi", kind: "correctness", matrix_column: true },
      { id: "ts_wasm_vm", kind: "correctness", matrix_column: true },
      { id: "wasm_aot", kind: "correctness", matrix_column: true },
    ],
    categories: [{ id: "arithmetic", label: "Arithmetic" }],
    features,
  };
}

function baseFeature(overrides: Partial<CatalogFeature> & { id: string }): CatalogFeature {
  return {
    category: "arithmetic",
    label: overrides.id,
    description: "",
    parity_case_files: [],
    parity_case_ids: [],
    id_prefix: null,
    id_regex: null,
    related_bench_ids: [],
    manual: {},
    notes: "",
    ...overrides,
  };
}

describe("feature_status decision table (C.5.1)", () => {
  test("all pass → done", () => {
    expect(applyDecisionTable(4, 0, 0)).toBe("done");
  });

  test("pass + skip no fail → partial", () => {
    expect(applyDecisionTable(3, 0, 1)).toBe("partial");
  });

  test("all skip → skipped", () => {
    expect(applyDecisionTable(0, 0, 5)).toBe("skipped");
  });

  test("all fail → broken", () => {
    expect(applyDecisionTable(0, 3, 0)).toBe("broken");
  });

  test("mix pass/fail under 25% fail → partial", () => {
    // 1 fail / 5 runnable = 0.20 ≤ 0.25
    expect(applyDecisionTable(4, 1, 0)).toBe("partial");
  });

  test("mix pass/fail over 25% fail → broken", () => {
    // 2 fail / 5 runnable = 0.40 > 0.25
    expect(applyDecisionTable(3, 2, 0)).toBe("broken");
  });

  test("boundary fail/runnable == 0.25 → partial", () => {
    expect(applyDecisionTable(3, 1, 0)).toBe("partial");
  });

  test("no matched rows → unknown", () => {
    expect(applyDecisionTable(0, 0, 0)).toBe("unknown");
  });
});

describe("decideFeatureStatus (C.5)", () => {
  const casesAllSkip: CaseRef[] = [
    { id: "a", skip: ["ts_wasm_vm"] },
    { id: "b", skip: ["ts_wasm_vm", "wasm_aot"] },
  ];

  test("1. all cases skip on B → skipped", () => {
    const r = decideFeatureStatus({
      backend: "ts_wasm_vm",
      backendsExecuted: ["ts_wasm_vm"],
      cases: casesAllSkip,
      csvById: null,
    });
    expect(r.status).toBe("skipped");
    expect(r.evidence).toBe("case_skip_all");
    expect(r.skip).toBe(2);
  });

  test("2a. mix pass/fail under threshold → partial", () => {
    const cases: CaseRef[] = [
      { id: "c1" },
      { id: "c2" },
      { id: "c3" },
      { id: "c4" },
      { id: "c5" },
    ];
    const csv = new Map([
      ["c1", "pass" as const],
      ["c2", "pass" as const],
      ["c3", "pass" as const],
      ["c4", "pass" as const],
      ["c5", "fail" as const],
    ]);
    const r = decideFeatureStatus({
      backend: "zig_vm",
      backendsExecuted: ["zig_vm"],
      cases,
      csvById: csv,
    });
    expect(r.status).toBe("partial");
    expect(r.evidence).toBe("parity_csv");
    expect(r.pass).toBe(4);
    expect(r.fail).toBe(1);
  });

  test("2b. mix pass/fail over threshold → broken", () => {
    const cases: CaseRef[] = [{ id: "c1" }, { id: "c2" }, { id: "c3" }, { id: "c4" }, { id: "c5" }];
    const csv = new Map([
      ["c1", "pass" as const],
      ["c2", "pass" as const],
      ["c3", "pass" as const],
      ["c4", "fail" as const],
      ["c5", "fail" as const],
    ]);
    const r = decideFeatureStatus({
      backend: "zig_vm",
      backendsExecuted: ["zig_vm"],
      cases,
      csvById: csv,
    });
    expect(r.status).toBe("broken");
    expect(r.fail).toBe(2);
    expect(r.pass).toBe(3);
  });

  test("3. no csv + manual done → unknown (missing_csv)", () => {
    const r = decideFeatureStatus({
      backend: "zig_vm",
      backendsExecuted: ["zig_vm"],
      manual: "done",
      cases: [{ id: "c1" }],
      csvById: null,
    });
    expect(r.status).toBe("unknown");
    expect(r.evidence).toBe("missing_csv");
  });

  test("4. backend not executed → unknown, ignore planted stale CSV", () => {
    // Caller must not pass csv when not executed; decideFeatureStatus also ignores via not_executed path.
    const stale = new Map([["c1", "pass" as const]]);
    const r = decideFeatureStatus({
      backend: "ts_wasm_vm",
      backendsExecuted: ["zig_vm", "ts_ffi"],
      cases: [{ id: "c1" }],
      // Even if a caller wrongly passes CSV, backendsExecuted gate wins first:
      csvById: stale,
    });
    expect(r.status).toBe("unknown");
    expect(r.evidence).toBe("not_executed");
  });

  test("5. manual n/a sticky despite CSV pass", () => {
    const r = decideFeatureStatus({
      backend: "wasm_aot",
      backendsExecuted: ["wasm_aot"],
      manual: "n/a",
      cases: [{ id: "c1" }],
      csvById: new Map([["c1", "pass"]]),
    });
    expect(r.status).toBe("n/a");
    expect(r.evidence).toBe("manual_sticky");
    expect(r.warning).toContain("sticky manual");
  });

  test("5b. manual skipped sticky despite CSV pass", () => {
    const r = decideFeatureStatus({
      backend: "ts_wasm_vm",
      backendsExecuted: ["ts_wasm_vm"],
      manual: "skipped",
      cases: [{ id: "c1" }],
      csvById: new Map([["c1", "pass"]]),
    });
    expect(r.status).toBe("skipped");
    expect(r.evidence).toBe("manual_sticky");
    expect(r.warning).toContain("sticky manual");
  });

  test("not executed + sticky missing → missing", () => {
    const r = decideFeatureStatus({
      backend: "wasm_aot",
      backendsExecuted: ["zig_vm"],
      manual: "missing",
      cases: [{ id: "c1" }],
    });
    expect(r.status).toBe("missing");
    expect(r.evidence).toBe("manual_sticky");
  });

  test("empty cases + manual done → done (manual_default)", () => {
    const r = decideFeatureStatus({
      backend: "zig_vm",
      backendsExecuted: ["zig_vm"],
      manual: "done",
      cases: [],
      csvById: new Map(),
    });
    expect(r.status).toBe("done");
    expect(r.evidence).toBe("manual_default");
  });

  test("all pass from CSV → done", () => {
    const r = decideFeatureStatus({
      backend: "zig_vm",
      backendsExecuted: ["zig_vm"],
      cases: [{ id: "a" }, { id: "b" }],
      csvById: new Map([
        ["a", "pass"],
        ["b", "pass"],
      ]),
    });
    expect(r.status).toBe("done");
    expect(r.pass).toBe(2);
    expect(r.fail).toBe(0);
    expect(r.skip).toBe(0);
  });
});

describe("matcher API", () => {
  test("6. files / prefix / ids / regex", () => {
    writeCases("alpha.json", [
      { id: "arith_add_01" },
      { id: "arith_mul_01" },
      { id: "other_01" },
      { id: "arith_div_02", skip: ["ts_ffi"] },
    ]);
    writeCases("beta.json", [
      { id: "matrix_add_01" },
      { id: "arith_pow_01" },
    ]);
    const byFile = loadAllCaseFiles(casesDir);

    // files only
    const byFiles = matchFeatureCases(
      baseFeature({ id: "f1", parity_case_files: ["alpha.json"] }),
      byFile
    );
    expect(byFiles.map((c) => c.id).sort()).toEqual([
      "arith_add_01",
      "arith_div_02",
      "arith_mul_01",
      "other_01",
    ]);

    // prefix filter
    const byPrefix = matchFeatureCases(
      baseFeature({
        id: "f2",
        parity_case_files: ["alpha.json", "beta.json"],
        id_prefix: "arith_",
      }),
      byFile
    );
    expect(byPrefix.map((c) => c.id).sort()).toEqual([
      "arith_add_01",
      "arith_div_02",
      "arith_mul_01",
      "arith_pow_01",
    ]);

    // explicit ids
    const byIds = matchFeatureCases(
      baseFeature({
        id: "f3",
        parity_case_files: ["alpha.json"],
        parity_case_ids: ["arith_mul_01", "other_01"],
      }),
      byFile
    );
    expect(byIds.map((c) => c.id).sort()).toEqual(["arith_mul_01", "other_01"]);

    // regex
    const byRegex = matchFeatureCases(
      baseFeature({
        id: "f4",
        parity_case_files: ["alpha.json"],
        id_regex: "arith_.*_01$",
      }),
      byFile
    );
    expect(byRegex.map((c) => c.id).sort()).toEqual(["arith_add_01", "arith_mul_01"]);

    // ids-only mode (empty files)
    const idsOnly = matchFeatureCases(
      baseFeature({
        id: "f5",
        parity_case_files: [],
        parity_case_ids: ["matrix_add_01", "arith_add_01"],
      }),
      byFile
    );
    expect(idsOnly.map((c) => c.id).sort()).toEqual(["arith_add_01", "matrix_add_01"]);

    // skip preserved
    const skipCase = byPrefix.find((c) => c.id === "arith_div_02");
    expect(skipCase?.skip).toEqual(["ts_ffi"]);
  });
});

describe("buildFeaturesDocument integration", () => {
  test("stale CSV ignored when backend not executed", () => {
    const taskId = "feat_stale_csv";
    writeCases("core.json", [{ id: "core_1" }, { id: "core_2" }]);
    // Plant stale wasm CSV showing PASS — must not become done
    writeCsv(taskId, "ts_wasm_vm", [
      { id: "core_1", status: "PASS" },
      { id: "core_2", status: "PASS" },
    ]);
    writeCsv(taskId, "zig_vm", [
      { id: "core_1", status: "PASS" },
      { id: "core_2", status: "PASS" },
    ]);

    const catalog = miniCatalog([
      baseFeature({
        id: "arith.core",
        parity_case_files: ["core.json"],
        related_bench_ids: ["arith.scalar"],
      }),
    ]);
    fs.writeFileSync(catalogPath, JSON.stringify(catalog), "utf8");

    const doc = buildFeaturesDocument({
      versionId: "v_stale",
      taskId,
      backendsExecuted: ["zig_vm"],
      catalog,
      catalogRaw: fs.readFileSync(catalogPath),
      catalogPath,
      casesDir,
      parityArtifactsDir: parityDir,
      generatedAt: "2026-07-09T12:00:00.000Z",
    });

    const cell = doc.cells.find((c) => c.feature_id === "arith.core")!;
    expect(cell.by_backend.zig_vm.status).toBe("done");
    expect(cell.by_backend.zig_vm.evidence).toBe("parity_csv");
    expect(cell.by_backend.ts_wasm_vm.status).toBe("unknown");
    expect(cell.by_backend.ts_wasm_vm.evidence).toBe("not_executed");
    expect(doc.backends_executed).toEqual(["zig_vm"]);
    expect(doc.catalog_hash.startsWith("sha256:")).toBe(true);
    expect(cell.related_bench_ids).toEqual(["arith.scalar"]);
  });

  test("manual n/a sticky in full document build", () => {
    const taskId = "feat_sticky_na";
    writeCases("na.json", [{ id: "na_1" }]);
    writeCsv(taskId, "wasm_aot", [{ id: "na_1", status: "PASS" }]);

    const catalog = miniCatalog([
      baseFeature({
        id: "ref.na",
        category: "reference",
        parity_case_files: ["na.json"],
        manual: { wasm_aot: "n/a" },
      }),
    ]);

    const doc = buildFeaturesDocument({
      versionId: "v_na",
      taskId,
      backendsExecuted: ["wasm_aot"],
      catalog,
      catalogRaw: JSON.stringify(catalog),
      casesDir,
      parityArtifactsDir: parityDir,
    });

    const cell = doc.cells[0];
    expect(cell.by_backend.wasm_aot.status).toBe("n/a");
    expect(cell.by_backend.wasm_aot.evidence).toBe("manual_sticky");
  });

  test("summary histogram counts per backend", () => {
    const taskId = "feat_hist";
    writeCases("h.json", [
      { id: "h1" },
      { id: "h2", skip: ["ts_ffi"] },
    ]);
    writeCsv(taskId, "zig_vm", [
      { id: "h1", status: "PASS" },
      { id: "h2", status: "PASS" },
    ]);
    writeCsv(taskId, "ts_ffi", [
      { id: "h1", status: "PASS" },
      { id: "h2", status: "SKIP" },
    ]);

    const catalog = miniCatalog([
      baseFeature({ id: "a", parity_case_files: ["h.json"] }),
      baseFeature({
        id: "b",
        parity_case_files: ["h.json"],
        manual: { ts_ffi: "skipped" },
      }),
    ]);

    const doc = buildFeaturesDocument({
      versionId: "v_hist",
      taskId,
      backendsExecuted: ["zig_vm", "ts_ffi"],
      catalog,
      catalogRaw: JSON.stringify(catalog),
      casesDir,
      parityArtifactsDir: parityDir,
    });

    expect(doc.summary.zig_vm.done).toBe(2);
    expect(doc.summary.ts_ffi.partial + doc.summary.ts_ffi.skipped).toBeGreaterThanOrEqual(1);
    // feature b is sticky skipped on ts_ffi
    const b = doc.cells.find((c) => c.feature_id === "b")!;
    expect(b.by_backend.ts_ffi.status).toBe("skipped");
  });

  test("parseParityCsvById handles quoted commas", () => {
    const taskId = "csv_quote";
    const p = writeCsv(taskId, "zig_vm", [
      { id: "q1", status: "PASS", expr: "1 + 2, x" },
      { id: "q2", status: "FAIL", expr: 'say "hi"' },
    ]);
    const map = parseParityCsvById(p);
    expect(map.get("q1")).toBe("pass");
    expect(map.get("q2")).toBe("fail");
  });

  test("repo catalog loads and has ≥15 features covering all categories", () => {
    const { catalog, hash } = loadCatalog();
    expect(catalog.schema_version).toBe(1);
    expect(catalog.features.length).toBeGreaterThanOrEqual(15);
    expect(hash.startsWith("sha256:")).toBe(true);
    expect(hash).toBe(catalogHash(fs.readFileSync("bench/features/catalog.json")));

    const categories = new Set(catalog.features.map((f) => f.category));
    for (const cat of [
      "arithmetic",
      "matrix",
      "complex",
      "timeseries",
      "units",
      "ode",
      "control_flow",
      "bindings",
      "aot",
      "reference",
    ]) {
      expect(categories.has(cat)).toBe(true);
    }

    // Every mapped file should exist
    const casesRoot = path.resolve("tests/parity/cases");
    for (const f of catalog.features) {
      for (const file of f.parity_case_files ?? []) {
        expect(fs.existsSync(path.join(casesRoot, file))).toBe(true);
      }
    }
  });
});

describe("features_matrix_refresh CLI helpers", () => {
  test("parity argv uses equals-form --task-id= / --backends= (not space-separated)", () => {
    const cmd = buildParityCliArgs("my_feat", ["zig_vm", "ts_ffi"]);
    expect(cmd).toEqual([
      "bun",
      "tests/parity/cli.ts",
      "--full",
      "--task-id=my_feat",
      "--backends=zig_vm,ts_ffi",
    ]);
    // Space form would be rejected by parity CLI as unknown args
    expect(cmd.some((a) => a === "--task-id" || a === "--backends")).toBe(false);
    expect(cmd.every((a) => a !== "my_feat" || a.startsWith("--"))).toBe(true);
  });

  test("--package defaults backends_executed from meta.parity_backends_executed", () => {
    const pkgDir = path.join(tmpRoot, "pkg_meta_backends");
    fs.mkdirSync(pkgDir, { recursive: true });
    writeJsonAtomic(path.join(pkgDir, "meta.json"), {
      version_id: "v1",
      parity_backends_executed: ["zig_vm", "ts_ffi"],
    });
    // Stale/wrong claim in features would be ignored because meta wins
    writeJsonAtomic(path.join(pkgDir, "features.json"), {
      backends_executed: ["zig_vm", "ts_ffi", "ts_wasm_vm", "wasm_aot"],
    });

    expect(readPackageBackendsExecuted(pkgDir)).toEqual(["zig_vm", "ts_ffi"]);
    expect(
      resolveBackendsExecuted({ explicitBackends: null, packageDir: pkgDir })
    ).toEqual(["zig_vm", "ts_ffi"]);

    // Explicit --backends overrides package meta
    expect(
      resolveBackendsExecuted({
        explicitBackends: ["zig_vm", "ts_ffi", "ts_wasm_vm", "wasm_aot"],
        packageDir: pkgDir,
      })
    ).toEqual(["zig_vm", "ts_ffi", "ts_wasm_vm", "wasm_aot"]);
  });

  test("--package falls back to correctness.parity.backends_executed", () => {
    const pkgDir = path.join(tmpRoot, "pkg_corr_backends");
    fs.mkdirSync(pkgDir, { recursive: true });
    writeJsonAtomic(path.join(pkgDir, "correctness.json"), {
      parity: { backends_executed: ["zig_vm"] },
    });
    expect(readPackageBackendsExecuted(pkgDir)).toEqual(["zig_vm"]);
  });

  test("standalone (no package) defaults to all matrix columns when --backends omitted", () => {
    const resolved = resolveBackendsExecuted({
      explicitBackends: null,
      packageDir: null,
    });
    expect(resolved).toEqual(["zig_vm", "ts_ffi", "ts_wasm_vm", "wasm_aot"]);
  });
});

describe("write_package embeds real features matrix", () => {
  test("features.json has cells + catalog_hash (not empty stub)", () => {
    const progressDir = path.join(tmpRoot, "progress_pkg");
    const featureId = `pr2_pkg_${process.pid}`;
    const stepsPath = path.join(tmpRoot, "runs", featureId, "steps.json");
    const steps: StepsDocument = {
      schema_version: 1,
      feature_id: featureId,
      started_at: "2026-07-09T12:00:00.000Z",
      finished_at: "2026-07-09T12:10:00.000Z",
      baseline_feature_id: null,
      baseline_source: "none",
      max_regression_pct: "5",
      parity_backends: ["zig_vm"],
      bench_mode: "zig",
      bench_tier: "smoke",
      perf_strict: false,
      steps: [
        {
          id: "zig_vm_baseline",
          status: "pass",
          duration_sec: 1,
          command: ["zig", "build", "vm-baseline"],
          log: "tests/artifacts/runs/pr2/zig_vm_baseline.log",
          reason: null,
        },
        {
          id: "zig_tests",
          status: "pass",
          duration_sec: 1,
          command: ["zig", "build", "test"],
          log: "tests/artifacts/runs/pr2/zig_tests.log",
          reason: null,
        },
        {
          id: "ts_tests",
          status: "pass",
          duration_sec: 1,
          command: ["bun", "test"],
          log: "tests/artifacts/runs/pr2/ts_tests.log",
          reason: null,
        },
        {
          id: "parity_full",
          status: "pass",
          duration_sec: 1,
          command: ["bun", "tests/parity/cli.ts", "--full"],
          log: "tests/artifacts/runs/pr2/parity_full.log",
          reason: null,
        },
      ],
      final_status: "pass",
      artifacts: {
        parity_report: "tests/artifacts/parity/pr2_report.md",
        perf_log: "tests/artifacts/performance/performance_log.csv",
        perf_compare: "tests/artifacts/performance/pr2_vs_prev.md",
        overview: "tests/artifacts/testing_overview/latest.md",
      },
    };
    fs.mkdirSync(path.dirname(stepsPath), { recursive: true });
    writeJsonAtomic(stepsPath, steps);

    // minimal parity CSV so zig_vm cells can derive
    writeCsv(featureId, "zig_vm", [{ id: "core_add_01", status: "PASS" }]);

    const result = writePackage({
      featureId,
      stepsPath,
      progressDir,
      parityArtifactsDir: parityDir,
      snapshotsDir: path.join(tmpRoot, "snaps_empty"),
      gitSha: "abcdef1",
      recordedAt: "2026-07-09T15:00:00.000Z",
      rebuildIndex: true,
    });

    const features = JSON.parse(
      fs.readFileSync(path.join(result.package_dir, "features.json"), "utf8")
    ) as FeaturesDocument;

    expect(features.cells.length).toBeGreaterThanOrEqual(15);
    expect(features.catalog_hash).toMatch(/^sha256:[0-9a-f]{64}$/);
    expect(features.backends_executed).toEqual(["zig_vm"]);
    expect(features.backends).toEqual(["zig_vm", "ts_ffi", "ts_wasm_vm", "wasm_aot"]);
    expect(features.summary.zig_vm).toBeDefined();
    expect(features.summary.ts_wasm_vm.unknown).toBeGreaterThan(0);

    // non-executed backends never "done" from nothing
    for (const cell of features.cells) {
      const wasm = cell.by_backend.ts_wasm_vm;
      expect(["unknown", "n/a", "missing", "skipped"]).toContain(wasm.status);
      if (wasm.status === "unknown") {
        expect(wasm.evidence).toBe("not_executed");
      }
    }
  });
});
