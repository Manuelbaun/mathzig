import { describe, expect, test } from "bun:test";
import {
  addExprInput,
  applyNodeDataWithEdgeRewrite,
  nextPortName,
  removeExprInput,
  renameExprInput,
  rewriteTargetPorts,
} from "./port_edit";
import type { FlowEdge, FlowNode, MzNodeData } from "./editor_types";

describe("port_edit", () => {
  test("nextPortName prefers x,y,z", () => {
    expect(nextPortName([])).toBe("x");
    expect(nextPortName(["x"])).toBe("y");
    expect(nextPortName(["x", "y"])).toBe("z");
  });

  test("addExprInput appends port", () => {
    const d: Extract<MzNodeData, { mzType: "expr" }> = {
      mzType: "expr",
      expr: "x + y",
      inputs: ["x"],
      inputKinds: ["number"],
      params: {},
      outputKind: "number",
    };
    const next = addExprInput(d);
    expect(next.inputs).toEqual(["x", "y"]);
    expect(next.inputKinds).toEqual(["number", "number"]);
  });

  test("removeExprInput drops edges via applyNodeDataWithEdgeRewrite", () => {
    const nodes: FlowNode[] = [
      {
        id: "a",
        type: "mzInput",
        position: { x: 0, y: 0 },
        data: { mzType: "input", name: "a", kind: "number" },
      },
      {
        id: "e",
        type: "mzExpr",
        position: { x: 0, y: 0 },
        data: {
          mzType: "expr",
          expr: "x",
          inputs: ["x", "y"],
          inputKinds: ["number", "number"],
          params: {},
          outputKind: "number",
        },
      },
    ];
    const edges: FlowEdge[] = [
      { id: "1", source: "a", sourceHandle: "out", target: "e", targetHandle: "x" },
      { id: "2", source: "a", sourceHandle: "out", target: "e", targetHandle: "y" },
    ];
    const data = removeExprInput(
      nodes[1]!.data as Extract<MzNodeData, { mzType: "expr" }>,
      1,
    );
    const out = applyNodeDataWithEdgeRewrite(nodes, edges, "e", data);
    expect(out.edges.map((e) => e.targetHandle)).toEqual(["x"]);
    expect((out.nodes[1]!.data as { inputs: string[] }).inputs).toEqual(["x"]);
  });

  test("rename rewrites edge handles", () => {
    const edges: FlowEdge[] = [
      { id: "1", source: "a", sourceHandle: "out", target: "e", targetHandle: "x" },
    ];
    const renamed = rewriteTargetPorts(edges, "e", ["x"], ["signal"]);
    expect(renamed[0]!.targetHandle).toBe("signal");
  });

  test("renameExprInput", () => {
    const d: Extract<MzNodeData, { mzType: "expr" }> = {
      mzType: "expr",
      expr: "x",
      inputs: ["x"],
      inputKinds: ["number"],
      params: {},
      outputKind: "number",
    };
    expect(renameExprInput(d, 0, "sig").inputs).toEqual(["sig"]);
  });
});
