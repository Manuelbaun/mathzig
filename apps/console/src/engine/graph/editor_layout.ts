import type { EditorUi, GraphDefinition, GraphNode } from "./editor_types";

/**
 * Simple layered left-to-right layout when importing runner-only JSON (no ui).
 * Not a production graph layout — just enough to open a graph on the canvas.
 *
 * Wide layers (many parallel consts) wrap to extra columns so nodes stay
 * on-screen instead of stacking off the bottom of the viewport.
 */
export function autoLayoutUi(definition: GraphDefinition): EditorUi {
  const nodes = definition.nodes ?? [];
  const layers = topoLayers(nodes, definition.edges ?? []);
  const xGap = 220;
  const yGap = 100;
  /** Max nodes stacked in one column before wrapping within a topo layer. */
  const maxPerCol = 7;
  const uiNodes: EditorUi["nodes"] = {};

  let col = 0;
  for (const layer of layers) {
    for (let i = 0; i < layer.length; i += maxPerCol) {
      const chunk = layer.slice(i, i + maxPerCol);
      chunk.forEach((id, row) => {
        uiNodes[id] = {
          position: {
            x: 48 + col * xGap,
            y: 48 + row * yGap,
          },
        };
      });
      col += 1;
    }
  }

  const outputs = definition.outputs ?? {};
  const outputNames = Object.keys(outputs);
  const outputNodes = outputNames.map((name, i) => ({
    id: `out_${name}`,
    name,
    position: {
      x: 48 + col * xGap,
      y: 48 + i * yGap,
    },
  }));

  return { nodes: uiNodes, outputNodes };
}

function topoLayers(nodes: GraphNode[], edges: Array<{ from: string; to: string }>): string[][] {
  const ids = nodes.map((n) => n.id);
  const idSet = new Set(ids);
  const indeg = new Map<string, number>();
  const outs = new Map<string, string[]>();
  for (const id of ids) {
    indeg.set(id, 0);
    outs.set(id, []);
  }
  for (const e of edges) {
    const from = e.from.split(".")[0]!;
    const to = e.to.split(".")[0]!;
    if (!idSet.has(from) || !idSet.has(to)) continue;
    outs.get(from)!.push(to);
    indeg.set(to, (indeg.get(to) ?? 0) + 1);
  }

  const layers: string[][] = [];
  let frontier = ids.filter((id) => (indeg.get(id) ?? 0) === 0);
  const placed = new Set<string>();

  while (frontier.length > 0) {
    // Stable order for deterministic layouts
    frontier = [...frontier].sort();
    layers.push([...frontier]);
    for (const id of frontier) placed.add(id);
    const next: string[] = [];
    for (const id of frontier) {
      for (const t of outs.get(id) ?? []) {
        if (placed.has(t)) continue;
        const d = (indeg.get(t) ?? 1) - 1;
        indeg.set(t, d);
        if (d <= 0) next.push(t);
      }
    }
    frontier = [...new Set(next)].filter((id) => !placed.has(id));
  }

  // cycles / leftover
  for (const id of ids) {
    if (!placed.has(id)) {
      if (layers.length === 0) layers.push([]);
      layers[layers.length - 1]!.push(id);
    }
  }
  return layers.length > 0 ? layers : [ids];
}
