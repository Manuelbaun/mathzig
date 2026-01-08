import { describe, expect, test } from "bun:test";
import { EXAMPLE_GRAPH } from "./example";
import { parseImport, fromFlow } from "./editor_adapter";
import type { FlowNode } from "./editor_types";
import {
  classifyGraphError,
  moduleSummary,
  placeNewNode,
  validateEditorDocument,
} from "./validate_editor";

describe("validate_editor", () => {
  test("example graph is valid with 2 expression modules", () => {
    const v = validateEditorDocument(parseImport(EXAMPLE_GRAPH));
    expect(v.ok).toBe(true);
    expect(v.exprModuleCount).toBe(2);
    expect(v.totalModuleCount).toBe(2);
    expect(moduleSummary(v)).toContain("2 expression");
  });

  test("unwired expr reports actionable connect message", () => {
    const base = parseImport(EXAMPLE_GRAPH);
    const nodes: FlowNode[] = [
      {
        id: "expr_1",
        type: "mzExpr",
        position: { x: 400, y: 200 },
        data: {
          mzType: "expr",
          expr: "x",
          inputs: ["x"],
          inputKinds: ["number"],
          params: {},
          outputKind: "number",
        },
      },
    ];
    // Merge onto empty edges for just this node
    const doc = fromFlow(nodes, [], { viewport: base.ui.viewport });
    const v = validateEditorDocument(doc);
    expect(v.ok).toBe(false);
    expect(v.blocking.some((i) => i.message.includes("Connect a Number value"))).toBe(true);
  });

  test("placeNewNode avoids overlapping existing nodes", () => {
    const nodes = [
      { position: { x: 0, y: 0 }, width: 180, height: 96 },
      { position: { x: 40, y: 40 }, width: 180, height: 96 },
    ];
    const p = placeNewNode(nodes);
    expect(p.x).toBeGreaterThan(180);
  });

  test("classifyGraphError maps stages", () => {
    expect(classifyGraphError("Expr node 'a' input 'x' is not connected.").label).toBe(
      "Graph invalid",
    );
    expect(classifyGraphError("compile failed: syntax error").label).toBe("Compilation failed");
    expect(classifyGraphError("WebAssembly.instantiate failed").label).toBe(
      "Runtime initialization failed",
    );
  });

  test("empty expr is an error", () => {
    const draft: FlowNode = {
      id: "expr_1",
      type: "mzExpr",
      position: { x: 0, y: 0 },
      data: {
        mzType: "expr",
        expr: "   ",
        inputs: [],
        inputKinds: [],
        params: {},
        outputKind: "number",
      },
    };
    const doc = fromFlow([draft], [], {});
    const v = validateEditorDocument(doc);
    expect(v.ok).toBe(false);
    expect(v.blocking.some((i) => i.message.includes("empty expression"))).toBe(true);
  });
});
