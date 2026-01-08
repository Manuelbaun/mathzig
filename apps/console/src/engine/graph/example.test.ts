import { describe, expect, it } from "bun:test";
import { parseImport } from "./editor_adapter";
import { validateEditorDocument } from "./validate_editor";
import {
  DEFAULT_EXAMPLE_ID,
  EXAMPLE_GRAPH,
  GRAPH_EXAMPLES,
  getGraphExample,
} from "./example";

describe("graph examples catalog", () => {
  it("has a non-trivial catalog with stable default", () => {
    expect(GRAPH_EXAMPLES.length).toBeGreaterThanOrEqual(12);
    expect(DEFAULT_EXAMPLE_ID).toBe("lowpass_gain");
    expect(getGraphExample(DEFAULT_EXAMPLE_ID)?.definition).toEqual(EXAMPLE_GRAPH);
  });

  it("every example has unique id, title, and at least one named graph output", () => {
    const ids = new Set<string>();
    for (const ex of GRAPH_EXAMPLES) {
      expect(ex.id.length).toBeGreaterThan(0);
      expect(ids.has(ex.id)).toBe(false);
      ids.add(ex.id);
      expect(ex.title.length).toBeGreaterThan(0);
      expect(ex.description.length).toBeGreaterThan(0);
      const outs = ex.definition.outputs ?? {};
      expect(Object.keys(outs).length).toBeGreaterThan(0);
    }
  });

  it("every example parses and validates (no blocking issues)", () => {
    for (const ex of GRAPH_EXAMPLES) {
      const doc = parseImport(ex.definition);
      const v = validateEditorDocument(doc);
      expect(v.ok, `${ex.id}: ${v.blocking.map((b) => b.message).join("; ")}`).toBe(true);
      // Named graph outputs become canvas out_* nodes.
      const outNodes = doc.ui.outputNodes ?? [];
      expect(outNodes.length, ex.id).toBeGreaterThan(0);
    }
  });

  it("includes rocket and lorenz simulation examples", () => {
    expect(getGraphExample("lorenz")).toBeTruthy();
    expect(getGraphExample("rocket")).toBeTruthy();
    expect(getGraphExample("lorenz")!.category).toBe("simulations");
    expect(getGraphExample("rocket")!.category).toBe("simulations");
    expect(Object.keys(getGraphExample("lorenz")!.definition.outputs ?? {})).toContain(
      "trajectory",
    );
    const rocketOuts = Object.keys(getGraphExample("rocket")!.definition.outputs ?? {});
    expect(rocketOuts).toContain("altitude_km");
    expect(rocketOuts).toContain("trajectory_s1");
    expect(rocketOuts).toContain("trajectory_inter");
    expect(rocketOuts).toContain("trajectory_s2");
    expect(rocketOuts).toContain("velocity");
  });
});
