/**
 * Helpers for adding/removing/renaming node input ports and rewriting edges.
 */
import { edgeId, makeRef } from "./editor_adapter";
import type { FlowEdge, FlowNode, MzNodeData, PortKind } from "./editor_types";

const NEXT_NAMES = ["x", "y", "z", "w", "u", "v", "a", "b", "c", "d"];

export function nextPortName(existing: string[]): string {
  for (const n of NEXT_NAMES) {
    if (!existing.includes(n)) return n;
  }
  let i = 1;
  while (existing.includes(`in${i}`)) i++;
  return `in${i}`;
}

/** Apply data patch; rewrite edges when expr/wasm input ports rename or drop. */
export function applyNodeDataWithEdgeRewrite(
  nodes: FlowNode[],
  edges: FlowEdge[],
  nodeId: string,
  data: MzNodeData,
): { nodes: FlowNode[]; edges: FlowEdge[] } {
  const prev = nodes.find((n) => n.id === nodeId);
  const nextNodes = nodes.map((n) => (n.id === nodeId ? { ...n, data } : n));
  if (!prev) return { nodes: nextNodes, edges };

  let nextEdges = edges;

  if (prev.data.mzType === "expr" && data.mzType === "expr") {
    nextEdges = rewriteTargetPorts(edges, nodeId, prev.data.inputs, data.inputs);
  } else if (prev.data.mzType === "wasm" && data.mzType === "wasm") {
    const oldPorts = (prev.data.manifest?.inputs ?? []).map((p) => p.name);
    const newPorts = (data.manifest?.inputs ?? []).map((p) => p.name);
    nextEdges = rewriteTargetPorts(edges, nodeId, oldPorts, newPorts);
  }

  return { nodes: nextNodes, edges: nextEdges };
}

/**
 * Map old port list → new port list by index when lengths match;
 * drop edges to removed ports; keep unmapped only if name still exists.
 */
export function rewriteTargetPorts(
  edges: FlowEdge[],
  nodeId: string,
  oldPorts: string[],
  newPorts: string[],
): FlowEdge[] {
  const rename = new Map<string, string>();
  const removed = new Set<string>();

  if (oldPorts.length === newPorts.length) {
    for (let i = 0; i < oldPorts.length; i++) {
      if (oldPorts[i] !== newPorts[i]) rename.set(oldPorts[i]!, newPorts[i]!);
    }
  } else {
    const newSet = new Set(newPorts);
    for (const p of oldPorts) {
      if (!newSet.has(p)) removed.add(p);
    }
    // also rename if same index still "related"
    const min = Math.min(oldPorts.length, newPorts.length);
    for (let i = 0; i < min; i++) {
      if (oldPorts[i] !== newPorts[i] && !removed.has(oldPorts[i]!)) {
        rename.set(oldPorts[i]!, newPorts[i]!);
      }
    }
  }

  const out: FlowEdge[] = [];
  for (const e of edges) {
    if (e.target !== nodeId) {
      out.push(e);
      continue;
    }
    const th = e.targetHandle || "in";
    if (removed.has(th)) continue;
    const mapped = rename.get(th) ?? th;
    if (!newPorts.includes(mapped) && mapped !== "in") continue;
    if (mapped === th) {
      out.push(e);
    } else {
      const from = makeRef(e.source, e.sourceHandle || "out");
      const to = makeRef(nodeId, mapped);
      out.push({
        ...e,
        id: edgeId(from, to),
        targetHandle: mapped,
      });
    }
  }
  return out;
}

export function addExprInput(data: Extract<MzNodeData, { mzType: "expr" }>): Extract<
  MzNodeData,
  { mzType: "expr" }
> {
  const name = nextPortName(data.inputs);
  return {
    ...data,
    inputs: [...data.inputs, name],
    inputKinds: [...data.inputKinds, "number" as PortKind],
  };
}

export function removeExprInput(
  data: Extract<MzNodeData, { mzType: "expr" }>,
  index: number,
): Extract<MzNodeData, { mzType: "expr" }> {
  return {
    ...data,
    inputs: data.inputs.filter((_, i) => i !== index),
    inputKinds: data.inputKinds.filter((_, i) => i !== index),
  };
}

export function renameExprInput(
  data: Extract<MzNodeData, { mzType: "expr" }>,
  index: number,
  name: string,
): Extract<MzNodeData, { mzType: "expr" }> {
  const inputs = data.inputs.map((n, i) => (i === index ? name : n));
  return { ...data, inputs };
}

export function setExprInputKind(
  data: Extract<MzNodeData, { mzType: "expr" }>,
  index: number,
  kind: PortKind,
): Extract<MzNodeData, { mzType: "expr" }> {
  const inputKinds = data.inputKinds.map((k, i) => (i === index ? kind : k));
  return { ...data, inputKinds };
}

export function addWasmInput(data: Extract<MzNodeData, { mzType: "wasm" }>): Extract<
  MzNodeData,
  { mzType: "wasm" }
> {
  const manifest = data.manifest ?? { inputs: [], params: [], output: { kind: "number" } };
  const name = nextPortName(manifest.inputs.map((p) => p.name));
  return {
    ...data,
    manifest: {
      ...manifest,
      inputs: [...manifest.inputs, { name, kind: "number" }],
    },
  };
}

export function removeWasmInput(
  data: Extract<MzNodeData, { mzType: "wasm" }>,
  index: number,
): Extract<MzNodeData, { mzType: "wasm" }> {
  const manifest = data.manifest ?? { inputs: [], params: [], output: { kind: "number" } };
  return {
    ...data,
    manifest: {
      ...manifest,
      inputs: manifest.inputs.filter((_, i) => i !== index),
    },
  };
}

export function patchWasmInput(
  data: Extract<MzNodeData, { mzType: "wasm" }>,
  index: number,
  patch: { name?: string; kind?: PortKind },
): Extract<MzNodeData, { mzType: "wasm" }> {
  const manifest = data.manifest ?? { inputs: [], params: [], output: { kind: "number" } };
  return {
    ...data,
    manifest: {
      ...manifest,
      inputs: manifest.inputs.map((p, i) =>
        i === index
          ? { name: patch.name ?? p.name, kind: patch.kind ?? p.kind }
          : p,
      ),
    },
  };
}
