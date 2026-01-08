import { parseGraphRef, type GraphEdge, type GraphNodeId, type GraphNode } from "./schema";

export type Topology = {
  ordered: GraphNode[];
  incoming: Map<GraphNodeId, Map<string, GraphRefSource>>;
};

export type GraphRefSource = {
  nodeId: GraphNodeId;
  port: string;
};

export function topoSort(nodes: GraphNode[], edges: GraphEdge[]): Topology {
  const byId = new Map<GraphNodeId, GraphNode>();
  for (const node of nodes) {
    if (!node.id) throw new Error("Graph node id must be non-empty.");
    if (byId.has(node.id)) throw new Error(`Duplicate graph node '${node.id}'.`);
    byId.set(node.id, node);
  }

  const outgoing = new Map<GraphNodeId, GraphNodeId[]>();
  const indegree = new Map<GraphNodeId, number>();
  const incoming = new Map<GraphNodeId, Map<string, GraphRefSource>>();
  for (const node of nodes) {
    outgoing.set(node.id, []);
    indegree.set(node.id, 0);
    incoming.set(node.id, new Map());
  }

  for (const edge of edges) {
    const from = parseGraphRef(edge.from);
    const to = parseGraphRef(edge.to);
    if (!byId.has(from.nodeId)) throw new Error(`Edge source node '${from.nodeId}' does not exist.`);
    if (!byId.has(to.nodeId)) throw new Error(`Edge target node '${to.nodeId}' does not exist.`);
    if (from.port !== "out") throw new Error(`Edge source '${edge.from}' must use '.out'.`);
    const targetInputs = incoming.get(to.nodeId)!;
    if (targetInputs.has(to.port)) throw new Error(`Input '${edge.to}' has multiple sources.`);
    targetInputs.set(to.port, from);
    outgoing.get(from.nodeId)!.push(to.nodeId);
    indegree.set(to.nodeId, indegree.get(to.nodeId)! + 1);
  }

  const queue = nodes.filter((node) => indegree.get(node.id) === 0).map((node) => node.id);
  const ordered: GraphNode[] = [];
  for (let head = 0; head < queue.length; head++) {
    const nodeId = queue[head]!;
    ordered.push(byId.get(nodeId)!);
    for (const next of outgoing.get(nodeId)!) {
      const degree = indegree.get(next)! - 1;
      indegree.set(next, degree);
      if (degree === 0) queue.push(next);
    }
  }

  if (ordered.length !== nodes.length) {
    const cycleNodes = nodes.filter((node) => (indegree.get(node.id) ?? 0) > 0).map((node) => node.id).join(", ");
    throw new Error(`Graph contains a cycle involving: ${cycleNodes}.`);
  }

  return { ordered, incoming };
}
