import { afterAll, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  envFlagEnabled,
  maybeRefreshProgressApp,
  resolveLatestBaselineVersionId,
  shouldWriteProgressPackage,
  writeGateProgressPackage,
} from "../../tools/testing/feature_gate_progress.ts";
import { writeJsonAtomic, type StepsDocument } from "../../tools/testing/feature_gate_steps.ts";
import type { MetaDocument, ProgressIndex } from "../../tools/progress/types.ts";

const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "mathzig-gate-progress-"));

afterAll(() => {
  fs.rmSync(tmpRoot, { recursive: true, force: true });
});

describe("shouldWriteProgressPackage / envFlagEnabled", () => {
  test("envFlagEnabled accepts 1/true/yes/on (case-insensitive)", () => {
    expect(envFlagEnabled(undefined)).toBe(false);
    expect(envFlagEnabled("")).toBe(false);
    expect(envFlagEnabled("0")).toBe(false);
    expect(envFlagEnabled("false")).toBe(false);
    expect(envFlagEnabled("1")).toBe(true);
    expect(envFlagEnabled("true")).toBe(true);
    expect(envFlagEnabled("YES")).toBe(true);
    expect(envFlagEnabled("On")).toBe(true);
  });

  test("shouldWriteProgressPackage is true unless PROGRESS_DISABLE", () => {
    expect(shouldWriteProgressPackage({})).toBe(true);
    expect(shouldWriteProgressPackage({ PROGRESS_DISABLE: undefined })).toBe(true);
    expect(shouldWriteProgressPackage({ PROGRESS_DISABLE: "" })).toBe(true);
    expect(shouldWriteProgressPackage({ PROGRESS_DISABLE: "0" })).toBe(true);
    expect(shouldWriteProgressPackage({ PROGRESS_DISABLE: "1" })).toBe(false);
    expect(shouldWriteProgressPackage({ PROGRESS_DISABLE: "true" })).toBe(false);
    expect(shouldWriteProgressPackage({ PROGRESS_DISABLE: "yes" })).toBe(false);
    expect(shouldWriteProgressPackage({ PROGRESS_DISABLE: "on" })).toBe(false);
  });
});

describe("resolveLatestBaselineVersionId", () => {
  test("returns null when no packages exist", () => {
    const progressDir = path.join(tmpRoot, "empty-progress");
    fs.mkdirSync(progressDir, { recursive: true });
    expect(resolveLatestBaselineVersionId("missing_feature", progressDir)).toBeNull();
  });

  test("picks highest seq package for baseline feature from index", () => {
    const progressDir = path.join(tmpRoot, "indexed-progress");
    const packagesDir = path.join(progressDir, "packages");
    fs.mkdirSync(packagesDir, { recursive: true });

    const index: ProgressIndex = {
      schema_version: 1,
      generated_at: "2026-07-09T00:00:00.000Z",
      packages: [
        {
          version_id: "00000001__20260709T000000Z__base__abc1234",
          seq: 1,
          sort_key: "00000001__20260709T000000Z__base__abc1234",
          label: "base",
          kind: "dev",
          status: "pass",
          feature_id: "baseline_feat",
          git_sha: "abc1234",
          git_tag: null,
          recorded_at: "2026-07-09T00:00:00.000Z",
          machine_id: "m1",
          has_performance: true,
          tier: "smoke",
          bench_mode: "zig",
          path: "packages/00000001__20260709T000000Z__base__abc1234",
          source: "local",
        },
        {
          version_id: "00000003__20260709T010000Z__base__def5678",
          seq: 3,
          sort_key: "00000003__20260709T010000Z__base__def5678",
          label: "base",
          kind: "dev",
          status: "pass",
          feature_id: "baseline_feat",
          git_sha: "def5678",
          git_tag: null,
          recorded_at: "2026-07-09T01:00:00.000Z",
          machine_id: "m1",
          has_performance: true,
          tier: "smoke",
          bench_mode: "zig",
          path: "packages/00000003__20260709T010000Z__base__def5678",
          source: "local",
        },
        {
          version_id: "00000002__20260709T003000Z__other__aaa1111",
          seq: 2,
          sort_key: "00000002__20260709T003000Z__other__aaa1111",
          label: "other",
          kind: "dev",
          status: "pass",
          feature_id: "other_feat",
          git_sha: "aaa1111",
          git_tag: null,
          recorded_at: "2026-07-09T00:30:00.000Z",
          machine_id: "m1",
          has_performance: false,
          tier: "smoke",
          bench_mode: "zig",
          path: "packages/00000002__20260709T003000Z__other__aaa1111",
          source: "local",
        },
      ],
    };
    writeJsonAtomic(path.join(progressDir, "index.json"), index);

    expect(resolveLatestBaselineVersionId("baseline_feat", progressDir)).toBe(
      "00000003__20260709T010000Z__base__def5678"
    );
    expect(resolveLatestBaselineVersionId("other_feat", progressDir)).toBe(
      "00000002__20260709T003000Z__other__aaa1111"
    );
    expect(resolveLatestBaselineVersionId("nope", progressDir)).toBeNull();
  });

  test("falls back to package meta scan when index missing", () => {
    const progressDir = path.join(tmpRoot, "scan-progress");
    const pkgId = "00000005__20260709T120000Z__scan__deadbee";
    const pkgDir = path.join(progressDir, "packages", pkgId);
    fs.mkdirSync(pkgDir, { recursive: true });
    const meta: Partial<MetaDocument> = {
      version_id: pkgId,
      seq: 5,
      feature_id: "scan_baseline",
    };
    writeJsonAtomic(path.join(pkgDir, "meta.json"), meta);

    expect(resolveLatestBaselineVersionId("scan_baseline", progressDir)).toBe(pkgId);
  });
});

describe("writeGateProgressPackage", () => {
  test("skips when PROGRESS_DISABLE is set", () => {
    const result = writeGateProgressPackage({
      featureId: "any",
      stepsPath: "/tmp/nope.json",
      baselineFeatureId: null,
      benchMode: "zig",
      tier: "smoke",
      env: { PROGRESS_DISABLE: "1" },
    });
    expect(result.skipped).toBe(true);
    expect(result.ok).toBe(true);
    expect(result.skipReason).toMatch(/PROGRESS_DISABLE/);
    expect(result.packageDir).toBeNull();
  });

  test("soft-fails when steps.json is missing (does not throw)", () => {
    const progressDir = path.join(tmpRoot, "soft-fail-progress");
    const stepsPath = path.join(tmpRoot, "missing-steps.json");
    const result = writeGateProgressPackage({
      featureId: "soft_fail_feat",
      stepsPath,
      baselineFeatureId: null,
      benchMode: "zig",
      tier: "smoke",
      env: {},
      progressDir,
    });
    expect(result.skipped).toBe(false);
    expect(result.ok).toBe(false);
    expect(result.errorMessage).toBeTruthy();
    expect(result.packageDir).toBeNull();
  });

  test("writes package from fixture steps when enabled", () => {
    const progressDir = path.join(tmpRoot, "write-progress");
    const parityDir = path.join(tmpRoot, "write-parity");
    const stepsPath = path.join(tmpRoot, "write-steps.json");
    fs.mkdirSync(parityDir, { recursive: true });

    const steps: StepsDocument = {
      schema_version: 1,
      feature_id: "gate_progress_fixture",
      started_at: "2026-07-09T12:00:00.000Z",
      finished_at: "2026-07-09T12:05:00.000Z",
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
          duration_sec: 1,
          command: ["zig", "build", "vm-baseline"],
          log: "zig_vm_baseline.log",
          reason: null,
        },
        {
          id: "zig_tests",
          status: "pass",
          duration_sec: 2,
          command: ["zig", "build", "test"],
          log: "zig_tests.log",
          reason: null,
        },
        {
          id: "ts_tests",
          status: "pass",
          duration_sec: 1,
          command: ["bun", "test"],
          log: "ts_tests.log",
          reason: null,
        },
        {
          id: "parity_full",
          status: "pass",
          duration_sec: 3,
          command: ["bun", "tests/parity/cli.ts", "--full"],
          log: "parity_full.log",
          reason: null,
        },
      ],
      final_status: "pass",
      artifacts: {
        parity_report: "tests/artifacts/parity/gate_progress_fixture_report.md",
        perf_log: "tests/artifacts/performance/performance_log.csv",
        perf_compare: null,
        overview: "tests/artifacts/testing_overview/latest.md",
      },
    };
    writeJsonAtomic(stepsPath, steps);

    // Empty CSVs so matrix builder does not fail hard.
    for (const backend of ["zig_vm", "ts_ffi"]) {
      fs.writeFileSync(
        path.join(parityDir, `gate_progress_fixture_${backend}.csv`),
        "expression,expected,got,status\n",
        "utf8"
      );
    }

    // writePackage reads parity from default path unless we pass parityArtifactsDir —
    // writeGateProgressPackage does not expose parityArtifactsDir. Isolate via PROGRESS_DIR
    // only; package write may still hit real parity dir for CSVs (missing → missing:true ok).
    const result = writeGateProgressPackage({
      featureId: "gate_progress_fixture",
      stepsPath,
      baselineFeatureId: null,
      benchMode: "zig",
      tier: "smoke",
      env: {},
      progressDir,
    });

    expect(result.skipped).toBe(false);
    expect(result.ok).toBe(true);
    expect(result.versionId).toBeTruthy();
    expect(result.packageDir).toBeTruthy();
    expect(fs.existsSync(path.join(result.packageDir!, "meta.json"))).toBe(true);
    expect(fs.existsSync(path.join(progressDir, "index.json"))).toBe(true);
  });
});

describe("maybeRefreshProgressApp", () => {
  test("no-op when PROGRESS_REFRESH_APP unset", () => {
    const r = maybeRefreshProgressApp({});
    expect(r.ran).toBe(false);
    expect(r.ok).toBe(true);
  });

  test("rebuilds index when PROGRESS_REFRESH_APP=1", () => {
    const progressDir = path.join(tmpRoot, "refresh-progress");
    fs.mkdirSync(path.join(progressDir, "packages"), { recursive: true });
    const r = maybeRefreshProgressApp({ PROGRESS_REFRESH_APP: "1" }, progressDir);
    expect(r.ran).toBe(true);
    expect(r.ok).toBe(true);
    expect(fs.existsSync(path.join(progressDir, "index.json"))).toBe(true);
    expect(r.message).toMatch(/not available yet|rebuilt/);
  });
});

describe("feature_gate.ts wiring (source smoke)", () => {
  test("feature_gate imports writeGateProgressPackage path", () => {
    const src = fs.readFileSync(
      path.resolve(process.cwd(), "tools/testing/feature_gate.ts"),
      "utf8"
    );
    expect(src).toContain("writeGateProgressPackage");
    expect(src).toContain("PROGRESS_DISABLE");
    expect(src).toContain("progress_package");
    expect(src).toContain("maybeRefreshProgressApp");
    // Default bench mode remains zig; no default mode=all
    expect(src).toMatch(/parseBenchMode\(process\.env\.FEATURE_GATE_BENCH_MODE\)/);
    expect(src).toContain('(raw ?? "zig")');
  });
});
