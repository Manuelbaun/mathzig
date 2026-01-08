import type { PortKind, GraphValue } from "./value_transfer";
import { normalizePortKind } from "./value_transfer";
import {
  MAX_GRAPH_EDGES,
  MAX_GRAPH_NODES,
  MAX_IDENTIFIER_LEN,
  MAX_SOURCE_BYTES,
} from "./limits";
import { GraphJsonError } from "./load_error";

export type GraphNodeId = string;
export type GraphPortName = string;
export type GraphRef = `${string}.${string}`;

export type { PortKind, GraphValue };

/** Parsed `mathzig:node` custom section / JSON sidecar. */
export type NodeManifest = {
  abi?: number;
  name?: string;
  inputs: Array<{ name: string; kind: string }>;
  params: Array<{ name: string; kind: string; default?: number | null }>;
  output: { name?: string; kind: string; result_tag?: string };
};

export type GraphNode =
  | {
      id: GraphNodeId;
      type: "input";
      name?: string;
      /** Port kind for type-checking edges (default: number). */
      kind?: PortKind | string;
    }
  | {
      id: GraphNodeId;
      type: "const";
      value: GraphValue;
      kind?: PortKind | string;
    }
  | {
      id: GraphNodeId;
      type: "expr";
      expr: string;
      /** Ordered input ports. These become eval params (then trailing params). */
      inputs?: GraphPortName[];
      /** Optional per-input kinds (parallel to `inputs`; default number). */
      inputKinds?: Array<PortKind | string>;
      /** Runtime-tunable params. Appended after inputs at the WASM boundary. */
      params?: Record<string, number>;
      /** Optional output kind (default: inferred from result_tag / number). */
      outputKind?: PortKind | string;
    }
  | {
      id: GraphNodeId;
      type: "wasm";
      /** Precompiled module bytes, or a filesystem path (bun/node only). */
      wasm: Uint8Array | ArrayBuffer | string;
      /** Optional explicit manifest; otherwise read from `mathzig:node` section. */
      manifest?: NodeManifest;
      /** Override runtime param defaults from the manifest. */
      params?: Record<string, number>;
    };

/** @deprecated Use GraphNode. Kept as an alias for B1 call sites. */
export type ScalarGraphNode = GraphNode;

export type GraphEdge = {
  from: GraphRef;
  to: GraphRef;
};

export type GraphDefinition = {
  nodes: GraphNode[] | Record<string, Omit<GraphNode, "id">>;
  edges?: GraphEdge[] | Record<GraphRef, GraphRef>;
  /** Graph outputs. String arrays are shorthand for { [name]: `${name}.out` }. */
  outputs?: Record<string, GraphRef> | string[];
};

export type NormalizedGraphDefinition = {
  nodes: GraphNode[];
  edges: GraphEdge[];
  outputs: Record<string, GraphRef>;
};

export type ParsedGraphRef = {
  nodeId: GraphNodeId;
  port: GraphPortName;
};

export function normalizeGraphDefinition(def: GraphDefinition): NormalizedGraphDefinition {
  if (def == null || typeof def !== "object") {
    throw new GraphJsonError("InvalidGraphJson", "GraphDefinition must be an object");
  }
  if (def.nodes == null) {
    throw new GraphJsonError("MissingNodes", "GraphDefinition.nodes is required", {
      position: { path: "nodes" },
    });
  }

  const nodes = Array.isArray(def.nodes)
    ? def.nodes.map((node) => ({ ...node }))
    : Object.entries(def.nodes).map(([id, node]) => ({ id, ...node }) as GraphNode);

  if (nodes.length > MAX_GRAPH_NODES) {
    throw new GraphJsonError(
      "LimitExceeded",
      `Graph has ${nodes.length} nodes; MAX_GRAPH_NODES is ${MAX_GRAPH_NODES}`,
      { position: { path: "nodes" } },
    );
  }
  for (const n of nodes) {
    if (typeof n.id !== "string" || n.id.length === 0) {
      throw new GraphJsonError("EmptyNodeId", "Graph node id must be non-empty", {
        position: { path: "nodes" },
      });
    }
    if (n.id.length > MAX_IDENTIFIER_LEN) {
      throw new GraphJsonError(
        "IdentifierTooLong",
        `Node id exceeds MAX_IDENTIFIER_LEN (${MAX_IDENTIFIER_LEN})`,
        { context: { node: n.id.slice(0, 32) }, position: { path: "nodes" } },
      );
    }
  }

  const edges = Array.isArray(def.edges)
    ? (def.edges ?? []).map((edge) => ({ ...edge }))
    : Object.entries(def.edges ?? {}).map(([from, to]) => ({ from: from as GraphRef, to }));

  if (edges.length > MAX_GRAPH_EDGES) {
    throw new GraphJsonError(
      "LimitExceeded",
      `Graph has ${edges.length} edges; MAX_GRAPH_EDGES is ${MAX_GRAPH_EDGES}`,
      { position: { path: "edges" } },
    );
  }

  const outputs = Array.isArray(def.outputs)
    ? Object.fromEntries(def.outputs.map((name) => [name, `${name}.out` as GraphRef]))
    : { ...(def.outputs ?? {}) };

  if (Object.keys(outputs).length === 0) {
    for (const node of nodes) outputs[node.id] = `${node.id}.out` as GraphRef;
  }

  return { nodes, edges, outputs };
}

/**
 * S4 single untrusted TS entry for graph JSON text.
 *
 * Schema-normalized objects may still call {@link normalizeGraphDefinition}
 * directly; **untrusted text** must enter here (size check + JSON.parse +
 * normalize with documented caps, pre-allocation).
 */
export function parseGraphDefinitionJson(text: string): NormalizedGraphDefinition {
  if (typeof text !== "string") {
    throw new GraphJsonError("InvalidGraphJson", "graph JSON text must be a string");
  }
  if (text.length > MAX_SOURCE_BYTES) {
    throw new GraphJsonError(
      "SourceTooLarge",
      `graph JSON exceeds MAX_SOURCE_BYTES (${MAX_SOURCE_BYTES})`,
    );
  }
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    throw new GraphJsonError("InvalidGraphJson", `graph JSON parse failed: ${msg}`);
  }
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
    throw new GraphJsonError("InvalidGraphJson", "graph JSON root must be an object");
  }
  return normalizeGraphDefinition(raw as GraphDefinition);
}

/**
 * S4 byte-boundary entry: UTF-8 decode (fatal) then {@link parseGraphDefinitionJson}.
 */
export function parseGraphDefinitionJsonBytes(
  bytes: Uint8Array | ArrayBuffer,
): NormalizedGraphDefinition {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  if (view.byteLength > MAX_SOURCE_BYTES) {
    throw new GraphJsonError(
      "SourceTooLarge",
      `graph JSON exceeds MAX_SOURCE_BYTES (${MAX_SOURCE_BYTES})`,
    );
  }
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(view);
  } catch {
    throw new GraphJsonError("InvalidUtf8", "graph JSON bytes are not valid UTF-8");
  }
  return parseGraphDefinitionJson(text);
}

export function parseGraphRef(ref: string): ParsedGraphRef {
  const dot = ref.indexOf(".");
  if (dot <= 0 || dot === ref.length - 1 || ref.indexOf(".", dot + 1) !== -1) {
    throw new Error(`Invalid graph reference '${ref}'. Expected '<node>.<port>'.`);
  }
  return { nodeId: ref.slice(0, dot), port: ref.slice(dot + 1) };
}

export function assertFiniteScalar(value: unknown, label: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new Error(`${label} must be a finite number.`);
  }
  return value;
}

/** Resolve the output kind of a node for edge type-checking. */
export function nodeOutputKind(node: GraphNode): PortKind {
  switch (node.type) {
    case "input":
      return normalizePortKind(node.kind ?? "number");
    case "const":
      if (node.kind) return normalizePortKind(node.kind);
      return inferConstKind(node.value);
    case "expr":
      return normalizePortKind(node.outputKind ?? "number");
    case "wasm": {
      const k = node.manifest?.output?.kind ?? node.manifest?.output?.result_tag ?? "number";
      return normalizePortKind(k);
    }
  }
}

/** Resolve the kind of an input port on a node. */
export function nodeInputKind(node: GraphNode, port: string): PortKind | null {
  switch (node.type) {
    case "input":
    case "const":
      return null;
    case "expr": {
      const inputs = node.inputs ?? [];
      const idx = inputs.indexOf(port);
      if (idx < 0) {
        if (node.params && Object.hasOwn(node.params, port)) return "number";
        return null;
      }
      const kinds = node.inputKinds ?? [];
      return normalizePortKind(kinds[idx] ?? "number");
    }
    case "wasm": {
      const inputs = node.manifest?.inputs ?? [];
      const found = inputs.find((p) => p.name === port);
      if (found) return normalizePortKind(found.kind);
      const params = node.manifest?.params ?? [];
      const p = params.find((x) => x.name === port);
      if (p) return normalizePortKind(p.kind);
      return null;
    }
  }
}

function inferConstKind(value: GraphValue): PortKind {
  if (typeof value === "number") return "number";
  if (typeof value === "boolean") return "boolean";
  if (typeof value === "string") return "string";
  if (value && typeof value === "object") {
    if ("rows" in value && "cols" in value) return "matrix";
    if ("re" in value && "im" in value) return "complex";
    if (value instanceof Map) return "record";
    if ("timestamps" in value || "id" in value) return "series";
  }
  return "number";
}
