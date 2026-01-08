/**
 * Pure node draft / placement helpers (no Solid Flow dependency).
 */
import { fromFlow, toFlow } from "./editor_adapter";
import { autoLayoutUi } from "./editor_layout";
import type { EditorDocument, FlowNode, MzNodeData } from "./editor_types";
import { placeNewNode } from "./validate_editor";

export type NodeKind = "input" | "const" | "expr" | "wasm" | "output";

export const NODE_KIND_META: Array<{
  kind: NodeKind;
  label: string;
  group: "Interface" | "Values" | "Compute";
  title: string;
}> = [
  {
    kind: "input",
    label: "Input",
    group: "Interface",
    title: "Graph input — value you set at run time",
  },
  {
    kind: "output",
    label: "Output",
    group: "Interface",
    title: "Named result collected when the graph runs",
  },
  {
    kind: "const",
    label: "Constant",
    group: "Values",
    title: "Fixed value wired into other nodes",
  },
  {
    kind: "expr",
    label: "Expression",
    group: "Compute",
    title: "Math expression compiled into its own WASM module",
  },
  {
    kind: "wasm",
    label: "WASM module",
    group: "Compute",
    title: "Import an external MathZig-compatible .wasm module",
  },
];

export function createNodeDraft(
  kind: NodeKind,
  id: string,
  position: { x: number; y: number },
): FlowNode {
  const base = { id, position };
  switch (kind) {
    case "input":
      return {
        ...base,
        type: "mzInput",
        data: { mzType: "input", name: id, kind: "number" },
      };
    case "const":
      return {
        ...base,
        type: "mzConst",
        data: { mzType: "const", value: 0, kind: "number" },
      };
    case "expr":
      return {
        ...base,
        type: "mzExpr",
        data: {
          mzType: "expr",
          expr: "x",
          inputs: ["x"],
          inputKinds: ["number"],
          params: {},
          outputKind: "number",
        },
      };
    case "wasm":
      return {
        ...base,
        type: "mzWasm",
        data: {
          mzType: "wasm",
          wasmRef: "",
          manifest: {
            inputs: [{ name: "x", kind: "number" }],
            params: [],
            output: { kind: "number" },
          },
          params: {},
        },
      };
    case "output":
      return {
        ...base,
        type: "mzOutput",
        data: { mzType: "output", name: id.replace(/^out_/, "") || "out" },
      };
  }
}

export function uniqueNodeId(prefix: string, used: Set<string>): string {
  let i = 1;
  let id = `${prefix}_${i}`;
  while (used.has(id)) {
    i++;
    id = `${prefix}_${i}`;
  }
  return id;
}

export function addNodeToDocument(
  doc: EditorDocument,
  kind: NodeKind,
  position?: { x: number; y: number },
): { doc: EditorDocument; nodeId: string } {
  const { nodes, edges } = toFlow(doc);
  const id = uniqueNodeId(kind === "output" ? "out" : kind, new Set(nodes.map((n) => n.id)));
  const pos = position ?? placeNewNode(nodes);
  const draft = createNodeDraft(kind, id, pos);
  return {
    doc: fromFlow([...nodes, draft], edges, { viewport: doc.ui.viewport }),
    nodeId: id,
  };
}

export function applyAutoLayout(doc: EditorDocument): EditorDocument {
  const def = doc.definition;
  const layout = autoLayoutUi(def);
  return {
    definition: def,
    ui: {
      ...layout,
      viewport: doc.ui.viewport,
    },
  };
}

export type AlignMode = "left" | "right" | "top" | "bottom" | "centerX" | "centerY";

export function alignSelectedNodes(
  doc: EditorDocument,
  selectedIds: string[],
  mode: AlignMode,
): EditorDocument {
  if (selectedIds.length < 2) return doc;
  const { nodes, edges } = toFlow(doc);
  const selected = nodes.filter((n) => selectedIds.includes(n.id));
  if (selected.length < 2) return doc;

  const NODE_W = 180;
  const NODE_H = 96;
  const xs = selected.map((n) => n.position.x);
  const ys = selected.map((n) => n.position.y);
  const rights = selected.map((n) => n.position.x + (n.width ?? NODE_W));
  const bottoms = selected.map((n) => n.position.y + (n.height ?? NODE_H));

  const minX = Math.min(...xs);
  const maxRight = Math.max(...rights);
  const minY = Math.min(...ys);
  const maxBottom = Math.max(...bottoms);
  const centerX = (minX + maxRight) / 2;
  const centerY = (minY + maxBottom) / 2;

  const next = nodes.map((n) => {
    if (!selectedIds.includes(n.id)) return n;
    const w = n.width ?? NODE_W;
    const h = n.height ?? NODE_H;
    let x = n.position.x;
    let y = n.position.y;
    switch (mode) {
      case "left":
        x = minX;
        break;
      case "right":
        x = maxRight - w;
        break;
      case "top":
        y = minY;
        break;
      case "bottom":
        y = maxBottom - h;
        break;
      case "centerX":
        x = centerX - w / 2;
        break;
      case "centerY":
        y = centerY - h / 2;
        break;
    }
    return { ...n, position: { x, y } };
  });
  return fromFlow(next, edges, { viewport: doc.ui.viewport });
}

export function distributeSelectedNodes(
  doc: EditorDocument,
  selectedIds: string[],
  axis: "x" | "y",
): EditorDocument {
  if (selectedIds.length < 3) return doc;
  const { nodes, edges } = toFlow(doc);
  const selected = nodes
    .filter((n) => selectedIds.includes(n.id))
    .sort((a, b) =>
      axis === "x" ? a.position.x - b.position.x : a.position.y - b.position.y,
    );
  if (selected.length < 3) return doc;

  const first = selected[0]!;
  const last = selected[selected.length - 1]!;
  const span =
    axis === "x"
      ? last.position.x - first.position.x
      : last.position.y - first.position.y;
  const step = span / (selected.length - 1);
  const posById = new Map<string, { x: number; y: number }>();
  selected.forEach((n, i) => {
    if (i === 0 || i === selected.length - 1) {
      posById.set(n.id, { ...n.position });
      return;
    }
    posById.set(
      n.id,
      axis === "x"
        ? { x: first.position.x + step * i, y: n.position.y }
        : { x: n.position.x, y: first.position.y + step * i },
    );
  });

  const next = nodes.map((n) => {
    const p = posById.get(n.id);
    return p ? { ...n, position: p } : n;
  });
  return fromFlow(next, edges, { viewport: doc.ui.viewport });
}

export function patchNodeData(
  doc: EditorDocument,
  nodeId: string,
  data: MzNodeData,
): EditorDocument {
  const { nodes, edges } = toFlow(doc);
  const next = nodes.map((n) => (n.id === nodeId ? { ...n, data } : n));
  return fromFlow(next, edges, { viewport: doc.ui.viewport });
}
