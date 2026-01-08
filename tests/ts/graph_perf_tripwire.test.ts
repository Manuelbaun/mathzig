/**
 * Unit tests for task-17 graph perf tripwire (compare direction + parser).
 * Always-on (not soak/smoke) — pure logic, no browser, no long bench.
 */
import { describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as path from "node:path";
import {
  compareMetrics,
  DEFAULT_BASELINE,
  DEFAULT_THRESHOLD,
  parseBaselineResultsMd,
  parseGraphTickJson,
  TRACKED,
} from "../../tools/testing/graph_perf_tripwire.ts";

describe("graph_perf_tripwire", () => {
  test("parses committed results.md baseline metrics", () => {
    const text = fs.readFileSync(DEFAULT_BASELINE, "utf8");
    const m = parseBaselineResultsMd(text);
    for (const t of TRACKED) {
      expect(m[t.key]).toBeGreaterThan(0);
    }
    // Spot-check known B4 numbers
    expect(m["scalar_3.runNs"]).toBeCloseTo(50.78542, 4);
    expect(m["matrix_edge.runNs"]).toBeCloseTo(725.63917, 4);
  });

  test("OK when current matches baseline", () => {
    const text = fs.readFileSync(DEFAULT_BASELINE, "utf8");
    const baseline = parseBaselineResultsMd(text);
    const r = compareMetrics(baseline, { ...baseline }, DEFAULT_THRESHOLD);
    expect(r.ok).toBe(true);
    expect(r.regressions).toHaveLength(0);
  });

  test("OK when current is slightly worse but within 30%", () => {
    const baseline = { "scalar_3.runNs": 100, "scalar_3.batchNs": 90 };
    // fill all tracked so missing doesn't fail
    const fullB: Record<string, number> = {};
    const fullC: Record<string, number> = {};
    for (const t of TRACKED) {
      fullB[t.key] = 100;
      fullC[t.key] = 129; // 29% worse
    }
    void baseline;
    const r = compareMetrics(fullB, fullC, 0.3);
    expect(r.ok).toBe(true);
  });

  test("FAIL when current is >30% slower (true regression)", () => {
    const fullB: Record<string, number> = {};
    const fullC: Record<string, number> = {};
    for (const t of TRACKED) {
      fullB[t.key] = 100;
      fullC[t.key] = 100;
    }
    fullC["scalar_10.runNs"] = 140; // 40% worse
    const r = compareMetrics(fullB, fullC, 0.3);
    expect(r.ok).toBe(false);
    expect(r.regressions.some((x) => x.key === "scalar_10.runNs")).toBe(true);
  });

  test("negative: 2× better baseline (half ns) against real numbers → FAIL", () => {
    // Proves comparison direction: if someone checks "current better than baseline"
    // inverted, this would pass. We want FAIL because current looks 2× slower
    // relative to the doctored (too-good) baseline.
    const text = fs.readFileSync(DEFAULT_BASELINE, "utf8");
    const real = parseBaselineResultsMd(text);
    const doctored: Record<string, number> = {};
    for (const [k, v] of Object.entries(real)) {
      doctored[k] = v / 2; // 2× better (half ns/tick)
    }
    const r = compareMetrics(doctored, real, DEFAULT_THRESHOLD);
    expect(r.ok).toBe(false);
    expect(r.regressions.length).toBe(TRACKED.length);
    for (const row of r.regressions) {
      expect(row.ratio).toBeCloseTo(2, 5);
    }
  });

  test("parseGraphTickJson prefers multi runtime rows", () => {
    const m = parseGraphTickJson({
      rows: [
        { case: "scalar_3", runtime: "fused", runNs: 999, batchNs: 888 },
        { case: "scalar_3", runtime: "multi", runNs: 50, batchNs: 44 },
        { case: "matrix_edge", runtime: "multi", runNs: 700, batchNs: null },
      ],
    });
    expect(m["scalar_3.runNs"]).toBe(50);
    expect(m["scalar_3.batchNs"]).toBe(44);
    expect(m["matrix_edge.runNs"]).toBe(700);
    expect(m["matrix_edge.batchNs"]).toBeUndefined();
  });

  test("doctored results.md file path compare (CLI-shaped negative)", () => {
    // Write a temporary doctored baseline and ensure compare fails vs real metrics.
    const text = fs.readFileSync(DEFAULT_BASELINE, "utf8");
    const real = parseBaselineResultsMd(text);
    // Build a fake results.md with 2× better numbers in the json fence
    const rows = TRACKED.reduce(
      (acc, t) => {
        const caseName = t.case;
        let row = acc.find((r) => r.case === caseName);
        if (!row) {
          row = { case: caseName, nodes: 0, runNs: null as number | null, batchNs: null as number | null };
          acc.push(row);
        }
        if (t.field === "runNs") row.runNs = real[t.key]! / 2;
        if (t.field === "batchNs") row.batchNs = real[t.key]! / 2;
        return acc;
      },
      [] as Array<{ case: string; nodes: number; runNs: number | null; batchNs: number | null }>
    );
    const doctoredMd = `# doctored\n\n\`\`\`json\n${JSON.stringify({ rows }, null, 2)}\n\`\`\`\n`;
    const tmp = path.join(
      import.meta.dir,
      "../../tests/artifacts/.tmp_doctored_results.md"
    );
    // artifacts dir is gitignored; use /tmp instead
    const tmpPath = `/tmp/mathzig_task17_doctored_results.md`;
    fs.writeFileSync(tmpPath, doctoredMd);
    void tmp;
    const doctored = parseBaselineResultsMd(fs.readFileSync(tmpPath, "utf8"));
    const r = compareMetrics(doctored, real, DEFAULT_THRESHOLD);
    expect(r.ok).toBe(false);
    expect(r.regressions.length).toBeGreaterThan(0);
  });
});
