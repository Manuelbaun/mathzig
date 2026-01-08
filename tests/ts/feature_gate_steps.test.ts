import { afterAll, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  type StepsDocument,
  assertStepsDocumentV1,
  writeJsonAtomic,
} from "../../tools/testing/feature_gate_steps.ts";

/** Golden fixture matching schema_version: 1 (failed correctness → skipped perf). */
function fixtureDoc(overrides: Partial<StepsDocument> = {}): StepsDocument {
  return {
    schema_version: 1,
    feature_id: "pr1a_fixture",
    started_at: "2026-07-09T12:00:00.000Z",
    finished_at: "2026-07-09T12:05:00.000Z",
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
        log: "tests/artifacts/runs/pr1a_fixture/zig_vm_baseline.log",
        reason: null,
      },
      {
        id: "zig_tests",
        status: "fail",
        duration_sec: 10,
        command: ["zig", "build", "test", "--summary", "all"],
        log: "tests/artifacts/runs/pr1a_fixture/zig_tests.log",
        reason: null,
      },
      {
        id: "perf_zig_record",
        status: "skipped",
        duration_sec: null,
        command: null,
        log: null,
        reason: "correctness gate failed (baseline/zig/ts/parity)",
      },
    ],
    final_status: "fail",
    artifacts: {
      parity_report: "tests/artifacts/parity/pr1a_fixture_report.md",
      perf_log: "tests/artifacts/performance/performance_log.csv",
      perf_compare: "tests/artifacts/performance/pr1a_fixture_vs_prev_feature.md",
      overview: "tests/artifacts/testing_overview/latest.md",
    },
    ...overrides,
  };
}

describe("feature_gate steps.json schema v1", () => {
  test("fixture document validates", () => {
    const doc = fixtureDoc();
    expect(() => assertStepsDocumentV1(doc)).not.toThrow();
    expect(doc.schema_version).toBe(1);
    expect(doc.parity_backends).toEqual(["zig_vm", "ts_ffi"]);
    expect(doc.bench_mode).toBe("zig");
    expect(doc.bench_tier).toBe("smoke");
    expect(doc.perf_strict).toBe(false);
    expect(doc.artifacts.parity_report).toContain("parity");
    expect(doc.final_status).toBe("fail");
    expect(doc.finished_at).not.toBeNull();
    expect(doc.max_regression_pct).toBe("5");
  });

  test("rejects invalid bench_mode", () => {
    const bad = fixtureDoc();
    (bad as { bench_mode: string }).bench_mode = "wasm";
    expect(() => assertStepsDocumentV1(bad)).toThrow(/bench_mode/);
  });

  test("rejects missing/invalid perf_strict", () => {
    const bad = fixtureDoc();
    (bad as { perf_strict: unknown }).perf_strict = "true";
    expect(() => assertStepsDocumentV1(bad)).toThrow(/perf_strict/);
  });

  test("accepts ts/all bench_mode and non-default tier/strict", () => {
    const doc = fixtureDoc({
      bench_mode: "all",
      bench_tier: "standard",
      perf_strict: true,
    });
    expect(() => assertStepsDocumentV1(doc)).not.toThrow();
    expect(doc.bench_mode).toBe("all");
    expect(doc.bench_tier).toBe("standard");
    expect(doc.perf_strict).toBe(true);
  });

  test("step statuses are lowercase; skipped shape is nullables + reason", () => {
    const doc = fixtureDoc();
    for (const step of doc.steps) {
      expect(["pass", "fail", "skipped"]).toContain(step.status);
      expect(step.status).toBe(step.status.toLowerCase());
    }
    const skipped = doc.steps.find((s) => s.status === "skipped");
    expect(skipped).toBeDefined();
    expect(skipped!.reason).toBeTruthy();
    expect(skipped!.duration_sec).toBeNull();
    expect(skipped!.command).toBeNull();
    expect(skipped!.log).toBeNull();
  });

  test("rejects uppercase status (markdown casing must not leak into JSON)", () => {
    const bad = fixtureDoc();
    (bad.steps[0] as { status: string }).status = "PASS";
    expect(() => assertStepsDocumentV1(bad)).toThrow(/lowercase pass\|fail\|skipped/);
  });

  test("rejects skipped step without reason", () => {
    const bad = fixtureDoc();
    bad.steps[2] = {
      id: "perf_zig_record",
      status: "skipped",
      duration_sec: null,
      command: null,
      log: null,
      reason: null as unknown as string,
    };
    expect(() => assertStepsDocumentV1(bad)).toThrow(/reason/);
  });

  test("no-baseline fixture keeps max_regression_pct and null perf_compare", () => {
    const doc = fixtureDoc({
      baseline_feature_id: null,
      baseline_source: "none",
      max_regression_pct: "5",
      artifacts: {
        parity_report: "tests/artifacts/parity/pr1a_fixture_report.md",
        perf_log: "tests/artifacts/performance/performance_log.csv",
        perf_compare: null,
        overview: "tests/artifacts/testing_overview/latest.md",
      },
    });
    expect(() => assertStepsDocumentV1(doc)).not.toThrow();
    expect(doc.max_regression_pct).toBe("5");
    expect(doc.artifacts.perf_compare).toBeNull();
  });

  test("incomplete run allows null final_status and finished_at", () => {
    const doc = fixtureDoc({
      finished_at: null,
      final_status: null,
      steps: [
        {
          id: "zig_vm_baseline",
          status: "pass",
          duration_sec: 1,
          command: ["zig", "build", "vm-baseline", "--summary", "all"],
          log: "tests/artifacts/runs/pr1a_fixture/zig_vm_baseline.log",
          reason: null,
        },
      ],
    });
    expect(() => assertStepsDocumentV1(doc)).not.toThrow();
  });
});

describe("writeJsonAtomic", () => {
  const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "mathzig-steps-"));

  afterAll(() => {
    fs.rmSync(tmpRoot, { recursive: true, force: true });
  });

  test("writes readable JSON at destination (no leftover .tmp)", () => {
    const dest = path.join(tmpRoot, "steps.json");
    const doc = fixtureDoc();
    writeJsonAtomic(dest, doc);

    expect(fs.existsSync(dest)).toBe(true);
    const parsed = JSON.parse(fs.readFileSync(dest, "utf8"));
    expect(() => assertStepsDocumentV1(parsed)).not.toThrow();
    expect(parsed.feature_id).toBe("pr1a_fixture");

    const leftovers = fs.readdirSync(tmpRoot).filter((n) => n.includes(".tmp"));
    expect(leftovers).toEqual([]);
  });
});
