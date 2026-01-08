/**
 * Spec 06 — client fuse export eligibility (browser-safe helpers).
 */
import { describe, expect, it } from "bun:test";
import {
  checkFuseExportSupport,
  exportSummaryFromMeta,
  formatFusePlanJson,
} from "./export_optimized";
import { parseImport } from "./editor_adapter";
import { EXAMPLE_GRAPH } from "./example";
import type { GraphDefinition } from "./editor_types";

describe("checkFuseExportSupport", () => {
  it("allows scalar example graph", () => {
    const doc = parseImport(EXAMPLE_GRAPH);
    const s = checkFuseExportSupport(doc);
    expect(s.ok).toBe(true);
    if (s.ok) {
      expect(s.summary).toMatch(/1 fused module/);
      expect(s.plan.nodes.length).toBeGreaterThan(0);
      expect(s.plan.outputs.length).toBe(2);
    }
  });

  it("blocks wasm-only nodes with clear reason", () => {
    const def: GraphDefinition = {
      nodes: [
        { id: "x", type: "input" },
        { id: "w", type: "wasm", wasm: "opaque.wasm" },
      ],
      edges: [{ from: "x.out", to: "w.x" }],
      outputs: { y: "w.out" },
    };
    const doc = parseImport(def);
    const s = checkFuseExportSupport(doc);
    expect(s.ok).toBe(false);
    if (!s.ok) {
      expect(s.reason).toMatch(/WASM node 'w'/i);
      expect(s.reasons[0]).toMatch(/no expression/i);
    }
  });

  it("formatFusePlanJson is stable JSON", () => {
    const doc = parseImport(EXAMPLE_GRAPH);
    const s = checkFuseExportSupport(doc);
    expect(s.ok).toBe(true);
    if (s.ok) {
      const text = formatFusePlanJson(s.plan);
      expect(() => JSON.parse(text)).not.toThrow();
      expect(text).toContain("boundaryPolicy");
    }
  });

  it("exportSummaryFromMeta formats outputs", () => {
    expect(
      exportSummaryFromMeta({
        wasmBytes: 10,
        outputCount: 1,
        inputCount: 1,
        paramCount: 0,
        exportCount: 1,
        outMode: "table",
      }),
    ).toBe("1 fused module · 1 output");
    expect(
      exportSummaryFromMeta({
        wasmBytes: 10,
        outputCount: 3,
        inputCount: 1,
        paramCount: 0,
        exportCount: 1,
        outMode: "table",
      }),
    ).toBe("1 fused module · 3 outputs");
  });
});
