import { describe, expect, test } from "bun:test";
import { parseImport } from "./editor_adapter";
import { EXAMPLE_GRAPH } from "./example";
import { DocumentHistory } from "./history";
import { addNodeToDocument, alignSelectedNodes, applyAutoLayout } from "./node_draft";

describe("DocumentHistory", () => {
  test("undo/redo round-trip", () => {
    const h = new DocumentHistory(parseImport(EXAMPLE_GRAPH));
    const a = h.present;
    const { doc: b } = addNodeToDocument(a, "expr");
    h.commit(b, "add expr");
    expect(h.canUndo).toBe(true);
    const undone = h.undo();
    expect(undone).toEqual(a);
    expect(h.canRedo).toBe(true);
    const redone = h.redo();
    expect(redone?.definition.nodes.length).toBe(b.definition.nodes.length);
  });
});

describe("node_draft layout", () => {
  test("addNodeToDocument returns id", () => {
    const base = parseImport(EXAMPLE_GRAPH);
    const { doc, nodeId } = addNodeToDocument(base, "const");
    expect(nodeId.startsWith("const_")).toBe(true);
    expect(doc.definition.nodes.some((n) => n.id === nodeId)).toBe(true);
  });

  test("alignSelectedNodes left", () => {
    const base = parseImport(EXAMPLE_GRAPH);
    const flow = applyAutoLayout(base);
    // positions from auto layout
    const ids = flow.definition.nodes.slice(0, 2).map((n) => n.id);
    // ensure two nodes have ui positions
    const withUi = applyAutoLayout(base);
    const aligned = alignSelectedNodes(withUi, ids, "left");
    const xs = ids.map((id) => aligned.ui.nodes[id]!.position.x);
    expect(xs[0]).toBe(xs[1]);
  });
});
