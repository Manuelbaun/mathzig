/**
 * Bidirectional adapter: EditorDocument ↔ Solid Flow nodes/edges ↔ runner GraphDefinition.
 */
import { autoLayoutUi } from "./editor_layout";
import type {
  EditorDocument,
  EditorUi,
  FlowEdge,
  FlowNode,
  GraphDefinition,
  GraphEdge,
  GraphNode,
  MzNodeData,
  NodeManifest,
  PortKind,
} from "./editor_types";

// ─── port kinds ──────────────────────────────────────────────────────────────

export function normalizePortKind(kind: string | undefined | null): PortKind {
  if (!kind) return "number";
  switch (kind) {
    case "scalar":
    case "number":
      return "number";
    case "bool":
    case "boolean":
      return "boolean";
    case "matrix":
    case "matrix_ptr":
      return "matrix";
    case "complex":
    case "complex_ptr":
      return "complex";
    case "record":
    case "record_ptr":
      return "record";
    case "string":
    case "string_ptr":
      return "string";
    case "series":
    case "series_handle":
      return "series";
    case "any":
      return "any";
    default:
      return "number";
  }
}

export function kindsCompatible(producer: string, consumer: string): boolean {
  const a = normalizePortKind(producer);
  const b = normalizePortKind(consumer);
  if (a === b) return true;
  if (a === "any" || b === "any") return true;
  if ((a === "number" && b === "boolean") || (a === "boolean" && b === "number")) return true;
  return false;
}

// ─── normalize definition ────────────────────────────────────────────────────

export function normalizeDefinition(def: GraphDefinition | Record<string, unknown>): GraphDefinition {
  const raw = def as GraphDefinition & {
    nodes?: GraphNode[] | Record<string, Omit<GraphNode, "id">>;
    edges?: GraphEdge[] | Record<string, string>;
    outputs?: Record<string, string> | string[];
  };

  const nodes: GraphNode[] = Array.isArray(raw.nodes)
    ? raw.nodes.map((n) => ({ ...n }))
    : Object.entries(raw.nodes ?? {}).map(([id, n]) => ({ id, ...(n as object) }) as GraphNode);

  const edges: GraphEdge[] = Array.isArray(raw.edges)
    ? (raw.edges ?? []).map((e) => ({ ...e }))
    : Object.entries(raw.edges ?? {}).map(([from, to]) => ({ from, to: String(to) }));

  let outputs: Record<string, string>;
  if (Array.isArray(raw.outputs)) {
    outputs = Object.fromEntries(raw.outputs.map((name) => [name, `${name}.out`]));
  } else {
    outputs = { ...(raw.outputs ?? {}) };
  }
  if (Object.keys(outputs).length === 0) {
    for (const n of nodes) outputs[n.id] = `${n.id}.out`;
  }

  return { nodes, edges, outputs };
}

// ─── refs / edges ────────────────────────────────────────────────────────────

export function parseRef(ref: string): { nodeId: string; port: string } {
  const dot = ref.indexOf(".");
  if (dot <= 0 || dot === ref.length - 1) {
    throw new Error(`Invalid graph ref '${ref}'. Expected '<node>.<port>'.`);
  }
  return { nodeId: ref.slice(0, dot), port: ref.slice(dot + 1) };
}

export function makeRef(nodeId: string, port: string): string {
  return `${nodeId}.${port}`;
}

export function edgeId(from: string, to: string): string {
  return `e:${from}->${to}`;
}

// ─── definition → flow ───────────────────────────────────────────────────────

export function toFlow(doc: EditorDocument): { nodes: FlowNode[]; edges: FlowEdge[] } {
  const def = normalizeDefinition(doc.definition);
  const ui = doc.ui ?? { nodes: {} };
  const flowNodes: FlowNode[] = [];

  for (const node of def.nodes) {
    const pos = ui.nodes[node.id]?.position ?? { x: 0, y: 0 };
    const size = ui.nodes[node.id];
    flowNodes.push({
      id: node.id,
      type: schemaTypeToFlow(node.type),
      position: { ...pos },
      width: size?.width,
      height: size?.height,
      data: schemaNodeToData(node),
    });
  }

  for (const out of ui.outputNodes ?? defaultOutputNodes(def, ui)) {
    flowNodes.push({
      id: out.id,
      type: "mzOutput",
      position: { ...out.position },
      data: { mzType: "output", name: out.name },
    });
  }

  const flowEdges: FlowEdge[] = [];
  for (const e of def.edges ?? []) {
    const from = parseRef(e.from);
    const to = parseRef(e.to);
    flowEdges.push({
      id: edgeId(e.from, e.to),
      source: from.nodeId,
      sourceHandle: from.port,
      target: to.nodeId,
      targetHandle: to.port,
    });
  }

  // Wire outputs: definition.outputs[name] → mzOutput node target `in`
  const outputs = def.outputs ?? {};
  for (const out of ui.outputNodes ?? defaultOutputNodes(def, ui)) {
    const ref = outputs[out.name];
    if (!ref) continue;
    try {
      const from = parseRef(ref);
      const toRef = makeRef(out.id, "in");
      flowEdges.push({
        id: edgeId(ref, toRef),
        source: from.nodeId,
        sourceHandle: from.port,
        target: out.id,
        targetHandle: "in",
      });
    } catch {
      /* skip bad output ref */
    }
  }

  return { nodes: flowNodes, edges: flowEdges };
}

function schemaTypeToFlow(t: GraphNode["type"]): FlowNode["type"] {
  switch (t) {
    case "input":
      return "mzInput";
    case "const":
      return "mzConst";
    case "expr":
      return "mzExpr";
    case "wasm":
      return "mzWasm";
  }
}

function schemaNodeToData(node: GraphNode): MzNodeData {
  switch (node.type) {
    case "input":
      return {
        mzType: "input",
        name: node.name ?? node.id,
        kind: normalizePortKind(node.kind),
      };
    case "const":
      return {
        mzType: "const",
        value: node.value,
        kind: normalizePortKind(node.kind),
      };
    case "expr": {
      const inputs = [...(node.inputs ?? [])];
      const inputKinds = inputs.map((_, i) => normalizePortKind(node.inputKinds?.[i]));
      return {
        mzType: "expr",
        expr: node.expr,
        inputs,
        inputKinds,
        params: { ...(node.params ?? {}) },
        outputKind: normalizePortKind(node.outputKind),
      };
    }
    case "wasm":
      return {
        mzType: "wasm",
        wasmRef: wasmToRef(node.wasm),
        manifest: node.manifest ?? null,
        params: { ...(node.params ?? {}) },
      };
  }
}

function wasmToRef(wasm: string | Uint8Array | ArrayBuffer): string {
  if (typeof wasm === "string") return wasm;
  const bytes = wasm instanceof ArrayBuffer ? new Uint8Array(wasm) : wasm;
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]!);
  // browser + bun
  // Prefer btoa (browser); otherwise manual base64 for bun tests.
  if (typeof btoa === "function") {
    return `data:application/wasm;base64,${btoa(bin)}`;
  }
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i]!;
    const b = i + 1 < bytes.length ? bytes[i + 1]! : 0;
    const c = i + 2 < bytes.length ? bytes[i + 2]! : 0;
    const triple = (a << 16) | (b << 8) | c;
    out += alphabet[(triple >> 18) & 63];
    out += alphabet[(triple >> 12) & 63];
    out += i + 1 < bytes.length ? alphabet[(triple >> 6) & 63] : "=";
    out += i + 2 < bytes.length ? alphabet[triple & 63] : "=";
  }
  return `data:application/wasm;base64,${out}`;
}

function defaultOutputNodes(def: GraphDefinition, ui: EditorUi) {
  const names = Object.keys(def.outputs ?? {});
  return names.map((name, i) => ({
    id: `out_${name}`,
    name,
    position: ui.nodes[`out_${name}`]?.position ?? {
      x: 720,
      y: 48 + i * 100,
    },
  }));
}

// ─── flow → document ─────────────────────────────────────────────────────────

export function fromFlow(
  nodes: FlowNode[],
  edges: FlowEdge[],
  extras?: { viewport?: EditorUi["viewport"] },
): EditorDocument {
  const defNodes: GraphNode[] = [];
  const uiNodes: EditorUi["nodes"] = {};
  const outputNodes: NonNullable<EditorUi["outputNodes"]> = [];
  const outputs: Record<string, string> = {};

  for (const n of nodes) {
    if (n.type === "mzOutput") {
      const name = n.data.mzType === "output" ? n.data.name : n.id;
      outputNodes.push({ id: n.id, name, position: { ...n.position } });
      // resolved below from edges into this node
      continue;
    }
    uiNodes[n.id] = {
      position: { ...n.position },
      width: n.width,
      height: n.height,
    };
    defNodes.push(flowNodeToSchema(n));
  }

  const defEdges: GraphEdge[] = [];
  for (const e of edges) {
    const sourceHandle = e.sourceHandle || "out";
    const targetHandle = e.targetHandle || "in";
    const from = makeRef(e.source, sourceHandle);
    const to = makeRef(e.target, targetHandle);

    const targetNode = nodes.find((n) => n.id === e.target);
    if (targetNode?.type === "mzOutput") {
      const outName = targetNode.data.mzType === "output" ? targetNode.data.name : e.target;
      outputs[outName] = from;
      continue;
    }
    defEdges.push({ from, to });
  }

  // Preserve output keys even if unwired (compile/run will surface missing wires)
  for (const o of outputNodes) {
    if (!(o.name in outputs)) {
      // leave unset — validation / compile will surface missing wires
    }
  }

  return {
    definition: {
      nodes: defNodes,
      edges: defEdges,
      outputs,
    },
    ui: {
      viewport: extras?.viewport,
      nodes: uiNodes,
      outputNodes,
    },
  };
}

function flowNodeToSchema(n: FlowNode): GraphNode {
  const d = n.data;
  switch (d.mzType) {
    case "input":
      return { id: n.id, type: "input", name: d.name, kind: d.kind };
    case "const":
      return { id: n.id, type: "const", value: d.value, kind: d.kind };
    case "expr":
      return {
        id: n.id,
        type: "expr",
        expr: d.expr,
        inputs: [...d.inputs],
        inputKinds: [...d.inputKinds],
        params: { ...d.params },
        outputKind: d.outputKind,
      };
    case "wasm":
      return {
        id: n.id,
        type: "wasm",
        wasm: d.wasmRef,
        manifest: d.manifest ?? undefined,
        params: { ...d.params },
      };
    case "output":
      throw new Error("mzOutput is editor-only");
  }
}

// ─── document → runner ───────────────────────────────────────────────────────

export function toRunner(doc: EditorDocument): GraphDefinition {
  return normalizeDefinition(doc.definition);
}

// ─── import / export ─────────────────────────────────────────────────────────

/**
 * Accept either a full EditorDocument or a bare GraphDefinition.
 */
export function parseImport(raw: unknown): EditorDocument {
  if (!raw || typeof raw !== "object") throw new Error("Import must be a JSON object");
  const obj = raw as Record<string, unknown>;

  if (obj.definition && typeof obj.definition === "object") {
    const definition = normalizeDefinition(obj.definition as GraphDefinition);
    const ui = (obj.ui as EditorUi | undefined) ?? autoLayoutUi(definition);
    if (!ui.nodes) ui.nodes = {};
    if (!ui.outputNodes) {
      const laid = autoLayoutUi(definition);
      ui.outputNodes = laid.outputNodes;
      for (const [id, pos] of Object.entries(laid.nodes)) {
        if (!ui.nodes[id]) ui.nodes[id] = pos;
      }
    }
    return { definition, ui };
  }

  const definition = normalizeDefinition(obj as GraphDefinition);
  return { definition, ui: autoLayoutUi(definition) };
}

export function exportDocument(doc: EditorDocument): string {
  return JSON.stringify(doc, null, 2);
}

export function exportRunnerJson(doc: EditorDocument): string {
  return JSON.stringify(toRunner(doc), null, 2);
}

// ─── port kind lookup (for isValidConnection) ────────────────────────────────

export function outputKindOf(node: FlowNode): PortKind {
  const d = node.data;
  switch (d.mzType) {
    case "input":
      return d.kind;
    case "const":
      return d.kind;
    case "expr":
      return d.outputKind;
    case "wasm":
      return normalizePortKind(d.manifest?.output?.kind);
    case "output":
      return "any";
  }
}

export function inputKindOf(node: FlowNode, port: string): PortKind {
  const d = node.data;
  switch (d.mzType) {
    case "expr": {
      const i = d.inputs.indexOf(port);
      return i >= 0 ? d.inputKinds[i] ?? "number" : "number";
    }
    case "wasm": {
      const p = d.manifest?.inputs?.find((x) => x.name === port);
      return normalizePortKind(p?.kind);
    }
    case "output":
      return "any";
    default:
      return "number";
  }
}

export function emptyManifest(): NodeManifest {
  return {
    inputs: [],
    params: [],
    output: { name: "out", kind: "number" },
  };
}
