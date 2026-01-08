/**
 * Graph lowerer: pure transform GraphDefinition → FusePlan (Spec 02).
 *
 * No wasm instantiation, no AOT compile. Output is the sole input to
 * multi-root / fused-tick codegen (Spec 03).
 *
 * ## Boundary rewrite policy (one policy, tested)
 *
 * **Keep real host port / param names** in each node's `expr` text.
 * Do **not** rewrite to GraphRunner's positional `x,y,z` aliases.
 *
 * Rationale: fused codegen maps ports by stable names across the module
 * (`nodeId.param` for flattened params; producer node ids for edge slots).
 * Multi-module GraphRunner rewrites only because single-node AOT is fixed to
 * positional `x/y/z` — that constraint does not apply to the fuse plan.
 *
 * ## Param naming
 *
 * Flattened fused entry params use `"${nodeId}.${param}"` (globally unique).
 * Order: topo order of reachable compute nodes, then each node's
 * `Object.keys(params)` insertion order.
 *
 * ## Port kinds
 *
 * Known `PortKind`s are accepted as plan metadata: number/boolean plus
 * matrix/complex/record/series/string/any (Spec 07 full-value). Unknown kind
 * strings throw via `normalizePortKind`. `inputKinds` is preserved on each
 * plan node (default `"number"`). Edge kind compatibility is checked lightly
 * (aligned with GraphRunner `kindsCompatible`) so the lowerer is a safe sole
 * gate for fuse paths.
 *
 * ## Outputs
 *
 * Empty/omitted `outputs` inherit `normalizeGraphDefinition`'s rule: every
 * node becomes an output (`id → id.out`). The dedicated empty-outputs error
 * only applies when normalize still yields no outputs (empty node list).
 *
 * ## v1 rejections
 *
 * - Reachable `type: "wasm"` nodes (opaque prebuilt modules)
 * - Missing edge for a required expr input port
 * - Undeclared input port, input+param name collision, non-finite param
 * - Duplicate host-facing input `name`s
 * - Output ref to a missing node / non-`.out` port
 * - Kind mismatch on an edge into a reachable expr node
 * - Cycles (via `topoSort`)
 */

import {
  normalizeGraphDefinition,
  nodeOutputKind,
  parseGraphRef,
  type GraphDefinition,
  type GraphNode,
  type GraphNodeId,
  type GraphValue,
  type PortKind,
} from "./schema";
import { topoSort, type GraphRefSource, type Topology } from "./topo";
import { kindsCompatible, normalizePortKind } from "./value_transfer";

// ── Stable error messages (testable substrings) ─────────────────────────────

export const FUSE_ERR = {
  wasmUnsupported: "Fuse v1 does not support wasm nodes",
  missingInputEdge: "missing edge for input",
  missingOutputNode: "output references missing node",
  emptyOutputs: "graph has no outputs",
  cycle: "Graph contains a cycle",
  undeclaredPort: "has undeclared input port",
  inputParamCollision: "as both input and param",
  nonFiniteParam: "must be a finite number",
  outputNotOut: "must reference '.out'",
  invalidRef: "Invalid graph reference",
  duplicateInputName: "duplicate graph input name",
  kindMismatch: "Kind mismatch on edge",
} as const;

export class FuseError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "FuseError";
  }
}

// ── FusePlan types ──────────────────────────────────────────────────────────

export type FusePlanInput = {
  /**
   * Host-facing input name (`node.name ?? node.id`).
   * Unique within `plan.inputs` (duplicate names rejected).
   */
  name: string;
  kind: PortKind;
  sourceNodeId: GraphNodeId;
};

export type FusePlanParam = {
  /** Globally unique flat name: `nodeId.param`. */
  name: string;
  kind: "number";
  nodeId: GraphNodeId;
  /** Local param key on the source node. */
  param: string;
  default: number;
};

export type FusePlanConst = {
  id: GraphNodeId;
  value: GraphValue;
  kind: PortKind;
};

/**
 * One reachable compute (`expr`) node in topo order.
 *
 * `expr` keeps real port names (see module policy).
 * `inputPorts[i]` is the producer **node id** feeding `inputs[i]` (edge binding).
 * `inputKinds[i]` is the consumer port kind (default number).
 * `paramNames` are local keys; flat fused names are in `FusePlan.params`.
 */
export type FusePlanNode = {
  id: GraphNodeId;
  expr: string;
  /** Declared input port names (order preserved from the graph node). */
  inputs: string[];
  /** Producer node id for each entry in `inputs` (parallel). */
  inputPorts: string[];
  /** Consumer port kinds parallel to `inputs` (default `"number"`). */
  inputKinds: PortKind[];
  /** Local param names on this node (order matches node.params keys). */
  paramNames: string[];
  outputKind: PortKind;
};

export type FusePlanOutput = {
  name: string;
  fromNodeId: GraphNodeId;
  kind: PortKind;
};

export type FusePlan = {
  inputs: FusePlanInput[];
  params: FusePlanParam[];
  /** Reachable const nodes only (feed producers for edge binding / codegen). */
  consts: FusePlanConst[];
  /** Topo order among reachable compute (expr) nodes only. */
  nodes: FusePlanNode[];
  outputs: FusePlanOutput[];
  /**
   * Documented boundary policy for consumers of this plan.
   * Always `"real_names"` in v1 (no x,y,z rewrite).
   */
  boundaryPolicy: "real_names";
};

// ── Lowerer ─────────────────────────────────────────────────────────────────

/**
 * Lower a graph definition to a deterministic fuse plan.
 * Throws {@link FuseError} on all lowerer-owned failures (including cycles).
 */
export function lowerGraphToFusePlan(def: GraphDefinition): FusePlan {
  const normalized = normalizeGraphDefinition(def);
  let topology: Topology;
  try {
    topology = topoSort(normalized.nodes, normalized.edges);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    // Match topo.ts prefix "Graph contains a cycle involving: …"
    if (msg.startsWith(FUSE_ERR.cycle)) throw new FuseError(msg);
    throw e instanceof Error ? e : new Error(msg);
  }

  const byId = new Map<GraphNodeId, GraphNode>();
  for (const node of normalized.nodes) byId.set(node.id, node);

  const outputEntries = Object.entries(normalized.outputs);
  // Only hit when normalize yields nothing (empty node list). Non-empty graphs
  // with omitted/empty outputs auto-fill every node as an output.
  if (outputEntries.length === 0) {
    throw new FuseError(FUSE_ERR.emptyOutputs);
  }

  // Resolve outputs first — missing refs are hard errors (no silent drop).
  const planOutputs: FusePlanOutput[] = [];
  const seedIds = new Set<GraphNodeId>();
  for (const [outName, ref] of outputEntries) {
    let parsed: { nodeId: string; port: string };
    try {
      parsed = parseGraphRef(ref);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      throw new FuseError(
        msg.startsWith(FUSE_ERR.invalidRef)
          ? `${msg} (output '${outName}')`
          : `${FUSE_ERR.invalidRef} '${ref}' (output '${outName}').`,
      );
    }
    if (parsed.port !== "out") {
      throw new FuseError(
        `Output '${outName}' ${FUSE_ERR.outputNotOut} (got '${ref}').`,
      );
    }
    const src = byId.get(parsed.nodeId);
    if (!src) {
      throw new FuseError(
        `${FUSE_ERR.missingOutputNode} '${parsed.nodeId}' (output '${outName}').`,
      );
    }
    seedIds.add(parsed.nodeId);
    planOutputs.push({
      name: outName,
      fromNodeId: parsed.nodeId,
      kind: nodeOutputKind(src),
    });
  }

  const reachable = markReachable(seedIds, topology.incoming, byId);

  // Reject wasm among reachable nodes (v1).
  for (const id of reachable) {
    const node = byId.get(id)!;
    if (node.type === "wasm") {
      throw new FuseError(
        `${FUSE_ERR.wasmUnsupported} (node '${id}'). Replace with an expr node or keep multi-module GraphRunner.`,
      );
    }
  }

  const inputs: FusePlanInput[] = [];
  const consts: FusePlanConst[] = [];
  const nodes: FusePlanNode[] = [];
  const params: FusePlanParam[] = [];
  const seenInputNames = new Set<string>();

  // Topo order among all nodes; emit only reachable of each kind.
  for (const node of topology.ordered) {
    if (!reachable.has(node.id)) continue;

    switch (node.type) {
      case "input": {
        const name = node.name ?? node.id;
        if (seenInputNames.has(name)) {
          const prior = inputs.find((i) => i.name === name)?.sourceNodeId ?? "?";
          throw new FuseError(
            `${FUSE_ERR.duplicateInputName} '${name}' (nodes '${prior}' and '${node.id}').`,
          );
        }
        seenInputNames.add(name);
        inputs.push({
          name,
          kind: nodeOutputKind(node),
          sourceNodeId: node.id,
        });
        break;
      }
      case "const": {
        consts.push({
          id: node.id,
          value: node.value,
          kind: nodeOutputKind(node),
        });
        break;
      }
      case "expr": {
        const declared = [...(node.inputs ?? [])];
        const incoming = topology.incoming.get(node.id) ?? new Map<string, GraphRefSource>();
        const inputPorts: string[] = [];
        const inputKinds: PortKind[] = declared.map((_, i) =>
          normalizePortKind(node.inputKinds?.[i] ?? "number"),
        );

        for (let i = 0; i < declared.length; i++) {
          const port = declared[i]!;
          const src = incoming.get(port);
          if (!src) {
            throw new FuseError(
              `Expr node '${node.id}' ${FUSE_ERR.missingInputEdge} '${port}'.`,
            );
          }
          inputPorts.push(src.nodeId);

          // Lightweight kind check (aligned with GraphRunner typeCheckEdges).
          const srcNode = byId.get(src.nodeId);
          if (srcNode) {
            const consumerKind = inputKinds[i]!;
            // Expr without explicit outputKind defaults to number (same as runner).
            const producerKind =
              srcNode.type === "expr" && !srcNode.outputKind
                ? ("number" as PortKind)
                : nodeOutputKind(srcNode);
            if (!kindsCompatible(producerKind, consumerKind)) {
              throw new FuseError(
                `${FUSE_ERR.kindMismatch} '${src.nodeId}.out' → '${node.id}.${port}': producer '${producerKind}' vs consumer '${consumerKind}'.`,
              );
            }
          }
        }

        // Undeclared ports with edges → error (same as GraphRunner policy).
        for (const port of incoming.keys()) {
          if (!declared.includes(port)) {
            throw new FuseError(
              `Expr node '${node.id}' ${FUSE_ERR.undeclaredPort} '${port}'.`,
            );
          }
        }

        const paramRecord = node.params ?? {};
        const paramNames = Object.keys(paramRecord);
        for (const p of paramNames) {
          if (declared.includes(p)) {
            throw new FuseError(
              `Expr node '${node.id}' uses '${p}' ${FUSE_ERR.inputParamCollision}.`,
            );
          }
          const defVal = paramRecord[p];
          if (typeof defVal !== "number" || !Number.isFinite(defVal)) {
            throw new FuseError(
              `Param '${node.id}.${p}' ${FUSE_ERR.nonFiniteParam}.`,
            );
          }
          params.push({
            name: `${node.id}.${p}`,
            kind: "number",
            nodeId: node.id,
            param: p,
            default: defVal,
          });
        }

        nodes.push({
          id: node.id,
          // Boundary policy: real names — store expression as authored.
          expr: node.expr,
          inputs: declared,
          inputPorts,
          inputKinds,
          paramNames,
          outputKind: nodeOutputKind(node),
        });
        break;
      }
      case "wasm":
        // Unreachable wasm is fine (dropped); reachable already rejected above.
        break;
    }
  }

  return {
    inputs,
    params,
    consts,
    nodes,
    outputs: planOutputs,
    boundaryPolicy: "real_names",
  };
}

/**
 * Backward reachability from graph outputs through edge producers (DFS stack).
 * Marks every node whose value can affect at least one declared output.
 * The reachable **set** is order-independent; only the set matters for emit.
 */
function markReachable(
  seeds: Set<GraphNodeId>,
  incoming: Map<GraphNodeId, Map<string, GraphRefSource>>,
  byId: Map<GraphNodeId, GraphNode>,
): Set<GraphNodeId> {
  const reachable = new Set<GraphNodeId>();
  const stack = [...seeds];
  while (stack.length > 0) {
    const id = stack.pop()!;
    if (reachable.has(id)) continue;
    if (!byId.has(id)) continue;
    reachable.add(id);
    const ports = incoming.get(id);
    if (!ports) continue;
    for (const src of ports.values()) {
      if (!reachable.has(src.nodeId)) stack.push(src.nodeId);
    }
  }
  return reachable;
}
