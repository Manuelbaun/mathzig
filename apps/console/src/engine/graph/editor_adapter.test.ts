import { describe, expect, test } from "bun:test";
import {
  edgeId,
  exportRunnerJson,
  fromFlow,
  kindsCompatible,
  normalizeDefinition,
  parseImport,
  parseRef,
  toFlow,
  toRunner,
} from "./editor_adapter";
import { autoLayoutUi } from "./editor_layout";
import type { EditorDocument, GraphDefinition } from "./editor_types";

const EXAMPLE: GraphDefinition = {
  nodes: [
    { id: "source", type: "input" },
    {
      id: "lowpass",
      type: "expr",
      expr: "x * a + y * (1 - a)",
      inputs: ["x", "y"],
      params: { a: 0.2 },
    },
    {
      id: "gain",
      type: "expr",
      expr: "x * g",
      inputs: ["x"],
      params: { g: 1.5 },
    },
    { id: "prev", type: "const", value: 0 },
  ],
  edges: [
    { from: "source.out", to: "lowpass.x" },
    { from: "prev.out", to: "lowpass.y" },
    { from: "lowpass.out", to: "gain.x" },
  ],
  outputs: { value: "gain.out", filtered: "lowpass.out" },
};

describe("editor_adapter", () => {
  test("parseRef", () => {
    expect(parseRef("gain.out")).toEqual({ nodeId: "gain", port: "out" });
    expect(() => parseRef("bad")).toThrow();
  });

  test("kindsCompatible", () => {
    expect(kindsCompatible("number", "number")).toBe(true);
    expect(kindsCompatible("number", "boolean")).toBe(true);
    expect(kindsCompatible("matrix", "number")).toBe(false);
    expect(kindsCompatible("any", "series")).toBe(true);
  });

  test("round-trip example via toFlow/fromFlow", () => {
    const doc: EditorDocument = {
      definition: normalizeDefinition(EXAMPLE),
      ui: autoLayoutUi(EXAMPLE),
    };
    const { nodes, edges } = toFlow(doc);
    expect(nodes.some((n) => n.id === "lowpass" && n.type === "mzExpr")).toBe(true);
    expect(nodes.filter((n) => n.type === "mzOutput").length).toBe(2);
    expect(edges.some((e) => e.source === "source" && e.target === "lowpass" && e.targetHandle === "x")).toBe(
      true,
    );

    const back = fromFlow(nodes, edges);
    const runner = toRunner(back);
    expect(runner.nodes.map((n) => n.id).sort()).toEqual(
      EXAMPLE.nodes.map((n) => n.id).sort(),
    );
    expect(runner.edges).toEqual(
      expect.arrayContaining([
        { from: "source.out", to: "lowpass.x" },
        { from: "prev.out", to: "lowpass.y" },
        { from: "lowpass.out", to: "gain.x" },
      ]),
    );
    expect(runner.outputs?.value).toBe("gain.out");
    expect(runner.outputs?.filtered).toBe("lowpass.out");
  });

  test("parseImport bare definition gets auto-layout", () => {
    const doc = parseImport(EXAMPLE);
    expect(doc.ui.nodes.source).toBeTruthy();
    expect(doc.ui.outputNodes?.length).toBe(2);
    expect(toRunner(doc).nodes.length).toBe(4);
  });

  test("parseImport full document preserves ui positions", () => {
    const doc = parseImport({
      definition: EXAMPLE,
      ui: {
        nodes: { source: { position: { x: 1, y: 2 } } },
        outputNodes: [{ id: "out_value", name: "value", position: { x: 9, y: 9 } }],
      },
    });
    expect(doc.ui.nodes.source?.position).toEqual({ x: 1, y: 2 });
    const { nodes } = toFlow(doc);
    expect(nodes.find((n) => n.id === "source")?.position).toEqual({ x: 1, y: 2 });
  });

  test("exportRunnerJson is loadable shape", () => {
    const doc = parseImport(EXAMPLE);
    const json = exportRunnerJson(doc);
    const parsed = JSON.parse(json) as GraphDefinition;
    expect(parsed.nodes.length).toBe(4);
    expect(parsed.edges?.length).toBe(3);
  });

  test("edgeId stable", () => {
    expect(edgeId("a.out", "b.x")).toBe("e:a.out->b.x");
  });

  test("wasm + multi-kind nodes round-trip in editor model", () => {
    const def: GraphDefinition = {
      nodes: [
        { id: "a", type: "input", kind: "matrix" },
        {
          id: "w",
          type: "wasm",
          wasm: "https://example.com/n.wasm",
          manifest: {
            inputs: [{ name: "m", kind: "matrix" }],
            params: [{ name: "k", kind: "number", default: 1 }],
            output: { kind: "matrix" },
          },
          params: { k: 2 },
        },
      ],
      edges: [{ from: "a.out", to: "w.m" }],
      outputs: { m: "w.out" },
    };
    const doc = parseImport(def);
    const { nodes, edges } = toFlow(doc);
    const wasm = nodes.find((n) => n.id === "w");
    expect(wasm?.type).toBe("mzWasm");
    expect(wasm?.data.mzType === "wasm" && wasm.data.params.k).toBe(2);
    const back = fromFlow(nodes, edges);
    const w = back.definition.nodes.find((n) => n.id === "w");
    expect(w?.type).toBe("wasm");
    if (w?.type === "wasm") {
      expect(w.wasm).toBe("https://example.com/n.wasm");
      expect(w.params?.k).toBe(2);
    }
  });
});
