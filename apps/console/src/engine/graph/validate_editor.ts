/**
 * Static validation for the graph editor (pre-compile).
 * Produces human-readable issues for the canvas / problems list.
 */
import type { EditorDocument, FlowEdge, FlowNode, PortKind } from "./editor_types";
import {
  kindsCompatible,
  normalizeDefinition,
  toFlow,
  toRunner,
} from "./editor_adapter";

export type ValidationIssue = {
  severity: "error" | "warning";
  /** Runner / canvas node id when applicable */
  nodeId?: string;
  port?: string;
  message: string;
};

export type EditorValidation = {
  issues: ValidationIssue[];
  blocking: ValidationIssue[];
  ok: boolean;
  exprModuleCount: number;
  wasmModuleCount: number;
  totalModuleCount: number;
};

function humanKind(kind: string | undefined): string {
  if (!kind || kind === "number") return "Number";
  return kind.charAt(0).toUpperCase() + kind.slice(1);
}

/** Incoming edges keyed by `targetId` → set of targetHandle. */
function incomingMap(edges: FlowEdge[]): Map<string, Set<string>> {
  const m = new Map<string, Set<string>>();
  for (const e of edges) {
    const handle = e.targetHandle || "in";
    let set = m.get(e.target);
    if (!set) {
      set = new Set();
      m.set(e.target, set);
    }
    set.add(handle);
  }
  return m;
}

function nodeById(nodes: FlowNode[]): Map<string, FlowNode> {
  return new Map(nodes.map((n) => [n.id, n]));
}

export function validateEditorDocument(doc: EditorDocument): EditorValidation {
  const { nodes, edges } = toFlow(doc);
  const incoming = incomingMap(edges);
  const byId = nodeById(nodes);
  const issues: ValidationIssue[] = [];
  let exprModuleCount = 0;
  let wasmModuleCount = 0;

  for (const n of nodes) {
    const d = n.data;
    if (d.mzType === "expr") {
      exprModuleCount++;
      if (!d.expr.trim()) {
        issues.push({
          severity: "error",
          nodeId: n.id,
          message: `Expression node ${n.id} has an empty expression.`,
        });
      }
      for (let i = 0; i < d.inputs.length; i++) {
        const port = d.inputs[i]!;
        const kind = d.inputKinds[i] ?? "number";
        if (!incoming.get(n.id)?.has(port)) {
          issues.push({
            severity: "error",
            nodeId: n.id,
            port,
            message: `Connect a ${humanKind(kind)} value to ${n.id}.${port}.`,
          });
        }
      }
      const params = Object.keys(d.params ?? {});
      for (const p of params) {
        if (d.inputs.includes(p)) {
          issues.push({
            severity: "error",
            nodeId: n.id,
            port: p,
            message: `Expression node ${n.id} uses '${p}' as both an input port and a parameter.`,
          });
        }
      }
    } else if (d.mzType === "wasm") {
      wasmModuleCount++;
      if (!d.wasmRef?.trim()) {
        issues.push({
          severity: "error",
          nodeId: n.id,
          message: `WASM node ${n.id} has no module — import a .wasm file.`,
        });
      }
      if (!d.manifest) {
        issues.push({
          severity: "error",
          nodeId: n.id,
          message:
            `WASM node ${n.id} has no node metadata. Compile with \`mathzig compile --node\`, ` +
            `or provide a compatible manifest.`,
        });
      } else {
        for (const p of d.manifest.inputs ?? []) {
          if (!incoming.get(n.id)?.has(p.name)) {
            issues.push({
              severity: "error",
              nodeId: n.id,
              port: p.name,
              message: `Connect a ${humanKind(p.kind)} value to ${n.id}.${p.name}.`,
            });
          }
        }
      }
    } else if (d.mzType === "output") {
      if (!incoming.get(n.id)?.has("in")) {
        issues.push({
          severity: "warning",
          nodeId: n.id,
          port: "in",
          message: `Output ${d.name || n.id} is not connected — it will not appear in results.`,
        });
      }
    } else if (d.mzType === "input") {
      if (!d.name?.trim()) {
        issues.push({
          severity: "error",
          nodeId: n.id,
          message: `Input node ${n.id} needs a name.`,
        });
      }
    }
  }

  // Type-check wired edges (editor-side).
  for (const e of edges) {
    const src = byId.get(e.source);
    const tgt = byId.get(e.target);
    if (!src || !tgt) {
      issues.push({
        severity: "error",
        message: `Edge references a missing node (${e.source} → ${e.target}).`,
      });
      continue;
    }
    if (tgt.data.mzType === "output") continue;
    const outKind = outputKindOf(src);
    const inKind = inputKindOf(tgt, e.targetHandle || "in");
    if (!kindsCompatible(outKind, inKind)) {
      issues.push({
        severity: "error",
        nodeId: tgt.id,
        port: e.targetHandle || "in",
        message:
          `Type mismatch on ${e.source} → ${tgt.id}.${e.targetHandle || "in"}: ` +
          `${humanKind(outKind)} cannot connect to ${humanKind(inKind)}.`,
      });
    }
  }

  // Structural sanity via runner normalize (catch duplicate ids, etc.)
  try {
    toRunner(doc);
    normalizeDefinition(doc.definition);
  } catch (err) {
    issues.push({
      severity: "error",
      message: String((err as Error)?.message ?? err),
    });
  }

  const blocking = issues.filter((i) => i.severity === "error");
  return {
    issues,
    blocking,
    ok: blocking.length === 0,
    exprModuleCount,
    wasmModuleCount,
    totalModuleCount: exprModuleCount + wasmModuleCount,
  };
}

function outputKindOf(node: FlowNode): PortKind | string {
  const d = node.data;
  switch (d.mzType) {
    case "input":
      return d.kind;
    case "const":
      return d.kind;
    case "expr":
      return d.outputKind;
    case "wasm":
      return d.manifest?.output?.kind ?? "any";
    case "output":
      return "any";
  }
}

function inputKindOf(node: FlowNode, port: string): PortKind | string {
  const d = node.data;
  switch (d.mzType) {
    case "expr": {
      const i = d.inputs.indexOf(port);
      return i >= 0 ? (d.inputKinds[i] ?? "number") : "any";
    }
    case "wasm": {
      const p = d.manifest?.inputs?.find((x) => x.name === port);
      return p?.kind ?? "any";
    }
    case "output":
      return "any";
    default:
      return "any";
  }
}

/** Classify a runtime/compile error for status copy. */
export function classifyGraphError(message: string): {
  stage: "invalid" | "compile" | "init" | "run" | "unknown";
  label: string;
} {
  const m = message.toLowerCase();
  if (
    m.includes("not connected") ||
    m.includes("undeclared") ||
    m.includes("cycle") ||
    m.includes("duplicate") ||
    m.includes("invalid graph") ||
    m.includes("type mismatch") ||
    m.includes("connect a ")
  ) {
    return { stage: "invalid", label: "Graph invalid" };
  }
  if (
    m.includes("compile") ||
    m.includes("aot") ||
    m.includes("syntax") ||
    m.includes("parse") ||
    m.includes("/api/aot")
  ) {
    return { stage: "compile", label: "Compilation failed" };
  }
  if (
    m.includes("instantiate") ||
    m.includes("import") ||
    m.includes("wasm") ||
    m.includes("manifest") ||
    m.includes("webassembly")
  ) {
    return { stage: "init", label: "Runtime initialization failed" };
  }
  if (m.includes("eval") || m.includes("run failed") || m.includes("finite")) {
    return { stage: "run", label: "Run failed" };
  }
  return { stage: "unknown", label: "Failed" };
}

/** Summarize module counts for status / compile button tooltip. */
export function moduleSummary(v: EditorValidation): string {
  const parts: string[] = [];
  if (v.exprModuleCount > 0) {
    parts.push(
      `${v.exprModuleCount} expression${v.exprModuleCount === 1 ? "" : "s"} → ` +
        `${v.exprModuleCount} WASM module${v.exprModuleCount === 1 ? "" : "s"}`,
    );
  }
  if (v.wasmModuleCount > 0) {
    parts.push(
      `${v.wasmModuleCount} external WASM module${v.wasmModuleCount === 1 ? "" : "s"}`,
    );
  }
  if (parts.length === 0) return "No compute modules";
  return parts.join(" · ");
}

/** Index issues by node id for canvas chrome. */
export function issuesByNodeId(issues: ValidationIssue[]): Map<string, ValidationIssue[]> {
  const m = new Map<string, ValidationIssue[]>();
  for (const i of issues) {
    if (!i.nodeId) continue;
    const list = m.get(i.nodeId) ?? [];
    list.push(i);
    m.set(i.nodeId, list);
  }
  return m;
}

/** Ports on a node that are missing required connections. */
export function missingPortsForNode(
  issues: ValidationIssue[],
  nodeId: string,
): Set<string> {
  const s = new Set<string>();
  for (const i of issues) {
    if (i.nodeId === nodeId && i.port && i.severity === "error") s.add(i.port);
  }
  return s;
}

/** Free-form placement helper: collision-aware spot near existing graph. */
export function placeNewNode(
  nodes: Array<{ position: { x: number; y: number }; width?: number; height?: number }>,
): { x: number; y: number } {
  const NODE_W = 180;
  const NODE_H = 96;
  const GAP = 36;

  if (nodes.length === 0) return { x: 120, y: 120 };

  let maxX = -Infinity;
  let minY = Infinity;
  let maxY = -Infinity;
  for (const n of nodes) {
    const w = n.width ?? NODE_W;
    const h = n.height ?? NODE_H;
    maxX = Math.max(maxX, n.position.x + w);
    minY = Math.min(minY, n.position.y);
    maxY = Math.max(maxY, n.position.y + h);
  }

  const overlaps = (x: number, y: number) =>
    nodes.some((n) => {
      const w = n.width ?? NODE_W;
      const h = n.height ?? NODE_H;
      return !(
        x + NODE_W + GAP < n.position.x ||
        n.position.x + w + GAP < x ||
        y + NODE_H + GAP < n.position.y ||
        n.position.y + h + GAP < y
      );
    });

  for (let attempt = 0; attempt < 48; attempt++) {
    const col = attempt % 4;
    const row = Math.floor(attempt / 4);
    const x = maxX + GAP + col * (NODE_W + GAP);
    const y = minY + row * (NODE_H + GAP);
    if (!overlaps(x, y)) return { x, y };
  }

  return { x: maxX + GAP, y: maxY + GAP };
}

