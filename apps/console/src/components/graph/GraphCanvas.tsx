import {
  For,
  Show,
  batch,
  createEffect,
  createMemo,
  createSignal,
  onCleanup,
  onMount,
  untrack,
} from "solid-js";
import { reconcile } from "solid-js/store";
import {
  Background,
  Controls,
  MiniMap,
  SolidFlow,
  addEdge,
  createEdgeStore,
  createNodeStore,
  useSolidFlow,
  useUpdateNodeInternals,
  type Connection,
  type EdgeConnection,
  type IsValidConnection,
} from "@dschz/solid-flow";
import "@dschz/solid-flow/styles";
import "./theme.css";
import { mzNodeTypes } from "./nodes/MzNodes";
import { GraphIssuesProvider } from "./GraphIssuesContext";
import {
  fromFlow,
  inputKindOf,
  kindsCompatible,
  outputKindOf,
  toFlow,
} from "../../engine/graph/editor_adapter";
import { applyNodeDataWithEdgeRewrite } from "../../engine/graph/port_edit";
import {
  addNodeToDocument as addNodeToDocumentCore,
  createNodeDraft,
  NODE_KIND_META,
  type NodeKind,
  uniqueNodeId,
} from "../../engine/graph/node_draft";
import type {
  EditorDocument,
  FlowEdge,
  FlowNode,
  MzNodeData,
  MzNodeType,
} from "../../engine/graph/editor_types";
import {
  issuesByNodeId,
  missingPortsForNode,
  type ValidationIssue,
} from "../../engine/graph/validate_editor";

import { PALETTE_MIME } from "./constants";
export { PALETTE_MIME };

export type GraphCanvasApi = {
  applyNodeData: (nodeId: string, data: MzNodeData) => void;
  getFlowSnapshot: () => { nodes: FlowNode[]; edges: FlowEdge[] };
  addNodeAt: (kind: NodeKind, position?: { x: number; y: number }) => string;
  selectNodeId: (id: string | null) => void;
  getSelectedNodeIds: () => string[];
  fitToNode: (id: string) => void;
  deleteSelected: () => void;
};

type Props = {
  document: EditorDocument;
  onDocumentChange: (doc: EditorDocument, meta?: { label?: string; history?: boolean }) => void;
  onSelectNode: (node: FlowNode | null) => void;
  onSelectEdge?: (edge: FlowEdge | null) => void;
  onApi?: (api: GraphCanvasApi | null) => void;
  validationIssues?: ValidationIssue[];
  /** Select + gently frame this node (add via toolbar / after remount). */
  focusNodeId?: string | null;
};

/**
 * Solid Flow canvas bound to EditorDocument (GraphDefinition + UI layout).
 *
 * Structural edits from the parent (add/layout/undo) push through `document`
 * and are applied with Solid `reconcile` so unchanged nodes keep identity and
 * the viewport is not reset. Full remount is only for genuine document
 * replacement (import / restore example).
 */
export function GraphCanvas(props: Props) {
  const initial = toFlow(props.document);

  const [nodes, setNodes] = createNodeStore<typeof mzNodeTypes>(
    initial.nodes.map(toStoreNode) as never,
  );
  const [edges, setEdges] = createEdgeStore(
    initial.edges.map((e) => toStoreEdge(e, true)),
  );

  const [statusLine, setStatusLine] = createSignal(
    "Edit on canvas · drag from palette, double-click to insert, Compile then Run",
  );
  const [connectError, setConnectError] = createSignal<string | null>(null);
  const [connectFromKind, setConnectFromKind] = createSignal<string | null>(null);
  const [insertMenu, setInsertMenu] = createSignal<{
    clientX: number;
    clientY: number;
    flow: { x: number; y: number };
  } | null>(null);
  const [selectedEdgeId, setSelectedEdgeId] = createSignal<string | null>(null);
  const [selectedNodeIds, setSelectedNodeIds] = createSignal<string[]>([]);

  let updateInternals: ((id: string | string[]) => void) | null = null;
  let flowHelpers: {
    screenToFlowPosition: (p: { x: number; y: number }) => { x: number; y: number };
    fitView: (opts?: { nodes?: Array<{ id: string }>; padding?: number; duration?: number }) => void;
  } | null = null;
  let paneEl: HTMLDivElement | undefined;
  /** Signature of the last flow we applied or emitted — skips echo re-sync. */
  let lastFlowSig = flowSignature(initial.nodes, initial.edges);
  let lastFocusedId: string | null = null;

  const issuesAccessor = createMemo(() => props.validationIssues ?? []);
  const issuesApi = {
    issues: issuesAccessor,
    issuesFor: (nodeId: string) => issuesByNodeId(issuesAccessor()).get(nodeId) ?? [],
    missingPorts: (nodeId: string) => missingPortsForNode(issuesAccessor(), nodeId),
    connectFromKind,
  };

  function snapshot(): { nodes: FlowNode[]; edges: FlowEdge[] } {
    return {
      nodes: nodes as unknown as FlowNode[],
      edges: edges as unknown as FlowEdge[],
    };
  }

  /**
   * Patch stores without replacing object identity for unchanged nodes/edges.
   * Solid Flow keeps measured handle bounds when the user-node proxy is stable.
   */
  function applyFlowToStores(
    nextNodes: FlowNode[],
    nextEdges: FlowEdge[],
    opts?: { selectedIds?: string[] },
  ) {
    const selected = new Set(opts?.selectedIds ?? selectedNodeIds());
    const storeNodes = nextNodes.map((n) => ({
      ...toStoreNode(n),
      selected: selected.has(n.id),
    }));
    const storeEdges = nextEdges.map((e) => toStoreEdge(e, true));
    batch(() => {
      setNodes(reconcile(storeNodes, { key: "id" }) as never);
      setEdges(reconcile(storeEdges, { key: "id" }) as never);
    });
    lastFlowSig = flowSignature(nextNodes, nextEdges);
  }

  function emitFromStores(meta?: { label?: string; history?: boolean }) {
    const { nodes: flowNodes, edges: flowEdges } = snapshot();
    lastFlowSig = flowSignature(flowNodes, flowEdges);
    const doc = fromFlow(flowNodes, flowEdges, {
      viewport: props.document.ui.viewport,
    });
    props.onDocumentChange(doc, meta);
  }

  function scheduleInternals(ids: string | string[]) {
    const list = Array.isArray(ids) ? ids : [ids];
    if (list.length === 0) return;
    // Wait for DOM layout after port/data changes so edges snap to new handles.
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        updateInternals?.(list);
      });
    });
  }

  function applyNodeData(nodeId: string, data: MzNodeData) {
    const { nodes: curNodes, edges: curEdges } = snapshot();
    const { nodes: nextNodes, edges: nextEdges } = applyNodeDataWithEdgeRewrite(
      curNodes,
      curEdges,
      nodeId,
      data,
    );

    applyFlowToStores(nextNodes, nextEdges);
    scheduleInternals(nodeId);

    const patched = nextNodes.find((n) => n.id === nodeId);
    emitFromStores({ label: `edit ${nodeId}`, history: true });
    if (patched) props.onSelectNode({ ...patched, data });
    setStatusLine(`Updated ${nodeId}`);
  }

  function addNodeAt(kind: NodeKind, position?: { x: number; y: number }): string {
    const { nodes: cur } = snapshot();
    const id = uniqueNodeId(kind === "output" ? "out" : kind, new Set(cur.map((n) => n.id)));
    const pos =
      position ??
      (() => {
        // viewport center approx via first node offset
        if (cur.length === 0) return { x: 120, y: 120 };
        const xs = cur.map((n) => n.position.x);
        const ys = cur.map((n) => n.position.y);
        return {
          x: (Math.min(...xs) + Math.max(...xs)) / 2 + 40,
          y: (Math.min(...ys) + Math.max(...ys)) / 2 + 40,
        };
      })();
    const draft = createNodeDraft(kind, id, pos);
    const nextNodes = [...cur, draft];
    setSelectedNodeIds([id]);
    applyFlowToStores(nextNodes, snapshot().edges, { selectedIds: [id] });
    queueMicrotask(() => {
      emitFromStores({ label: `add ${kind}`, history: true });
      props.onSelectNode(draft);
      setStatusLine(`Added ${kind} ${id}`);
      requestAnimationFrame(() => {
        flowHelpers?.fitView({ nodes: [{ id }], padding: 0.45, duration: 200 });
      });
    });
    return id;
  }

  function selectNodeId(id: string | null) {
    if (!id) {
      props.onSelectNode(null);
      setSelectedNodeIds([]);
      batch(() => {
        setNodes((node) => Boolean((node as { selected?: boolean }).selected), "selected", false);
      });
      return;
    }
    const n = (nodes as unknown as FlowNode[]).find((x) => x.id === id) ?? null;
    props.onSelectNode(n);
    setSelectedNodeIds(n ? [id] : []);
    if (n) {
      batch(() => {
        setNodes((node) => node.id !== id, "selected", false);
        setNodes((node) => node.id === id, "selected", true);
      });
    }
  }

  function deleteSelected() {
    const nodeIds = new Set(selectedNodeIds());
    const edgeId = selectedEdgeId();
    const { nodes: cur, edges: curEdges } = snapshot();
    let nextNodes = cur;
    let nextEdges = curEdges;
    if (nodeIds.size > 0) {
      nextNodes = cur.filter((n) => !nodeIds.has(n.id));
      nextEdges = curEdges.filter(
        (e) => !nodeIds.has(e.source) && !nodeIds.has(e.target),
      );
    } else if (edgeId) {
      nextEdges = curEdges.filter((e) => e.id !== edgeId);
    } else {
      return;
    }
    setSelectedEdgeId(null);
    setSelectedNodeIds([]);
    applyFlowToStores(nextNodes, nextEdges, { selectedIds: [] });
    props.onSelectNode(null);
    props.onSelectEdge?.(null);
    queueMicrotask(() => emitFromStores({ label: "delete", history: true }));
  }

  const api: GraphCanvasApi = {
    applyNodeData,
    getFlowSnapshot: snapshot,
    addNodeAt,
    selectNodeId,
    getSelectedNodeIds: () => selectedNodeIds(),
    fitToNode: (id) => flowHelpers?.fitView({ nodes: [{ id }], padding: 0.45, duration: 200 }),
    deleteSelected,
  };

  onMount(() => {
    props.onApi?.(api);
  });
  onCleanup(() => props.onApi?.(null));

  // Parent-driven document changes (toolbar add, layout, undo) — no remount.
  createEffect(() => {
    const doc = props.document;
    const { nodes: nextNodes, edges: nextEdges } = toFlow(doc);
    const sig = flowSignature(nextNodes, nextEdges);
    if (sig === lastFlowSig) return;

    // Don't track store reads — this effect is driven only by props.document.
    const { prevById, keep } = untrack(() => {
      const map = new Map(
        (nodes as unknown as FlowNode[]).map((n) => [n.id, n] as const),
      );
      const selected = selectedNodeIds().filter((id) =>
        nextNodes.some((n) => n.id === id),
      );
      return { prevById: map, keep: selected };
    });
    const dataChanged: string[] = [];
    for (const n of nextNodes) {
      const old = prevById.get(n.id);
      if (
        !old ||
        old.type !== n.type ||
        JSON.stringify(old.data) !== JSON.stringify(n.data)
      ) {
        dataChanged.push(n.id);
      }
    }

    applyFlowToStores(nextNodes, nextEdges, { selectedIds: keep });
    setSelectedNodeIds(keep);
    if (keep.length === 0) {
      setSelectedEdgeId(null);
    }
    // Only remeasure when handles may have moved (data/type change), not for pure moves.
    if (dataChanged.length > 0) scheduleInternals(dataChanged);
  });

  // Focus a newly added node without remounting / fitView of the whole graph.
  createEffect(() => {
    const id = props.focusNodeId ?? null;
    if (!id || id === lastFocusedId) return;
    lastFocusedId = id;
    queueMicrotask(() => {
      requestAnimationFrame(() => {
        selectNodeId(id);
        flowHelpers?.fitView({ nodes: [{ id }], padding: 0.45, duration: 200 });
      });
    });
  });

  const isValidConnection: IsValidConnection = (connection) => {
    const c = connection as Connection;
    if (!c.source || !c.target) return false;
    if (c.source === c.target) {
      setConnectError("Self-loops are not allowed");
      return false;
    }
    const taken = edges.some(
      (e) =>
        e.target === c.target &&
        (e.targetHandle ?? null) === (c.targetHandle ?? null) &&
        e.id !== (c as { edgeId?: string }).edgeId,
    );
    if (taken) {
      setConnectError(`Port already wired: ${c.target}.${c.targetHandle ?? "in"}`);
      return false;
    }

    const src = (nodes as unknown as FlowNode[]).find((n) => n.id === c.source);
    const tgt = (nodes as unknown as FlowNode[]).find((n) => n.id === c.target);
    if (src && tgt) {
      const outK = outputKindOf(src);
      const inK = inputKindOf(tgt, c.targetHandle || "in");
      if (!kindsCompatible(outK, inK)) {
        setConnectError(`Type mismatch: ${outK} → ${inK}`);
        return false;
      }
    }
    setConnectError(null);
    return true;
  };

  const onConnect = (connection: EdgeConnection) => {
    setConnectError(null);
    setConnectFromKind(null);
    setStatusLine(
      `Connected ${connection.source}.${connection.sourceHandle ?? "out"} → ${connection.target}.${connection.targetHandle ?? "in"}`,
    );
    setEdges((eds) => {
      if (eds.some((e) => e.id === connection.id)) return eds;
      return addEdge(
        {
          ...connection,
          sourceHandle: connection.sourceHandle ?? undefined,
          targetHandle: connection.targetHandle ?? undefined,
        } as never,
        eds,
      );
    });
    queueMicrotask(() => emitFromStores({ label: "connect", history: true }));
  };

  const onReconnect = (oldEdge: FlowEdge, newConnection: Connection) => {
    if (!isValidConnection(newConnection)) return;
    setEdges((eds) =>
      eds.map((e) =>
        e.id === oldEdge.id
          ? ({
              ...e,
              source: newConnection.source!,
              target: newConnection.target!,
              sourceHandle: newConnection.sourceHandle ?? undefined,
              targetHandle: newConnection.targetHandle ?? undefined,
              reconnectable: true,
            } as never)
          : e,
      ),
    );
    setStatusLine(
      `Reconnected ${newConnection.source} → ${newConnection.target}.${newConnection.targetHandle ?? "in"}`,
    );
    queueMicrotask(() => emitFromStores({ label: "reconnect", history: true }));
  };

  const onNodeClick = (args: { node: { id: string } }) => {
    const n = (nodes as unknown as FlowNode[]).find((x) => x.id === args.node.id) ?? null;
    props.onSelectNode(n);
    setSelectedNodeIds(n ? [n.id] : []);
    setSelectedEdgeId(null);
    props.onSelectEdge?.(null);
    if (n) setStatusLine(`Selected ${n.id}`);
  };

  const onEdgeClick = (args: { edge: { id: string } }) => {
    const e = (edges as unknown as FlowEdge[]).find((x) => x.id === args.edge.id) ?? null;
    setSelectedEdgeId(e?.id ?? null);
    props.onSelectEdge?.(e);
    props.onSelectNode(null);
    setSelectedNodeIds([]);
    if (e) setStatusLine(`Edge ${e.source} → ${e.target} · Delete to remove`);
  };

  const onPaneClick = (args: { event: MouseEvent }) => {
    props.onSelectNode(null);
    props.onSelectEdge?.(null);
    setSelectedEdgeId(null);
    setSelectedNodeIds([]);
    setInsertMenu(null);
    if (args.event.detail === 2 && paneEl) {
      const flow = flowHelpers?.screenToFlowPosition({
        x: args.event.clientX,
        y: args.event.clientY,
      }) ?? { x: 120, y: 120 };
      setInsertMenu({
        clientX: args.event.clientX,
        clientY: args.event.clientY,
        flow,
      });
    }
  };

  const onNodeDragStop = () => {
    emitFromStores({ label: "move", history: true });
  };

  const onSelectionChange = (params: { nodes: Array<{ id: string }> }) => {
    setSelectedNodeIds(params.nodes.map((n) => n.id));
  };

  const onConnectStart = (
    _e: MouseEvent | TouchEvent,
    params: { nodeId?: string | null; handleType?: string | null },
  ) => {
    if (params.handleType === "source" && params.nodeId) {
      const src = (nodes as unknown as FlowNode[]).find((n) => n.id === params.nodeId);
      if (src) setConnectFromKind(String(outputKindOf(src)));
    }
  };

  const onConnectEnd = () => {
    setConnectFromKind(null);
  };

  function onDragOver(e: DragEvent) {
    if (e.dataTransfer?.types.includes(PALETTE_MIME) || e.dataTransfer?.types.includes("text/plain")) {
      e.preventDefault();
      if (e.dataTransfer) e.dataTransfer.dropEffect = "copy";
    }
  }

  function onDrop(e: DragEvent) {
    e.preventDefault();
    const kind = (e.dataTransfer?.getData(PALETTE_MIME) ||
      e.dataTransfer?.getData("text/plain")) as NodeKind;
    if (!NODE_KIND_META.some((m) => m.kind === kind)) return;
    const flow = flowHelpers?.screenToFlowPosition({ x: e.clientX, y: e.clientY }) ?? {
      x: e.offsetX,
      y: e.offsetY,
    };
    addNodeAt(kind, flow);
    setInsertMenu(null);
  }

  const issueCount = () =>
    (props.validationIssues ?? []).filter((i) => i.severity === "error").length;

  return (
    <GraphIssuesProvider value={issuesApi}>
      <div class="flex h-full min-h-[420px] flex-col">
        <div
          class="mz-flow flex-1"
          ref={paneEl}
          onDragOver={onDragOver}
          onDrop={onDrop}
        >
          <SolidFlow
            class="mz-solid-flow"
            nodes={nodes}
            edges={edges}
            nodeTypes={mzNodeTypes}
            fitView
            fitViewOptions={{ padding: 0.2 }}
            colorMode="dark"
            connectionRadius={32}
            multiSelectionKey={["Meta", "Control"]}
            selectionKey="Shift"
            isValidConnection={isValidConnection}
            onConnect={onConnect}
            onConnectStart={onConnectStart as never}
            onConnectEnd={onConnectEnd}
            onReconnect={(oldEdge, newConnection) =>
              onReconnect(oldEdge as FlowEdge, newConnection)
            }
            onNodeClick={onNodeClick}
            onEdgeClick={onEdgeClick}
            onPaneClick={onPaneClick}
            onNodeDragStop={onNodeDragStop}
            onSelectionChange={onSelectionChange}
            onDelete={() => {
              queueMicrotask(() => emitFromStores({ label: "delete", history: true }));
              setSelectedEdgeId(null);
              setSelectedNodeIds([]);
              props.onSelectNode(null);
              props.onSelectEdge?.(null);
            }}
            deleteKey={["Backspace", "Delete"]}
            proOptions={{ hideAttribution: true }}
            style={{ width: "100%", height: "100%" }}
            defaultEdgeOptions={{ type: "default", reconnectable: true } as never}
            elevateEdgesOnSelect
            elevateNodesOnSelect
          >
            <InternalsHook
              onReady={(fn, helpers) => {
                updateInternals = fn;
                flowHelpers = helpers;
              }}
            />
            <Background gap={18} size={1} />
            <Controls />
            <MiniMap pannable zoomable />
          </SolidFlow>

          <Show when={insertMenu()}>
            {(menu) => (
              <div
                class="fixed z-40 min-w-[180px] rounded-md border border-line bg-panel py-1 shadow-lg"
                style={{
                  left: `${menu().clientX}px`,
                  top: `${menu().clientY}px`,
                }}
                role="menu"
              >
                <p class="px-2 py-1 text-[10px] tracking-wider text-fg-muted uppercase">
                  Add node
                </p>
                <For each={NODE_KIND_META}>
                  {(item) => (
                    <button
                      type="button"
                      class="block w-full px-3 py-1.5 text-left text-[12px] text-fg-secondary hover:bg-inset hover:text-fg"
                      role="menuitem"
                      onClick={() => {
                        addNodeAt(item.kind, menu().flow);
                        setInsertMenu(null);
                      }}
                    >
                      {item.label}
                    </button>
                  )}
                </For>
              </div>
            )}
          </Show>
        </div>
        <div class="flex shrink-0 flex-wrap items-center justify-between gap-x-3 gap-y-0.5 border-t border-line px-2 py-1 font-mono text-[11px]">
          <span class="truncate text-fg-secondary">{statusLine()}</span>
          <Show when={connectError()}>
            <span class="text-err">{connectError()}</span>
          </Show>
          <Show when={selectedEdgeId()}>
            <button
              type="button"
              class="ghost-btn !py-0 !px-2 text-err"
              onClick={() => {
                setSelectedNodeIds([]);
                deleteSelected();
              }}
            >
              Delete edge
            </button>
          </Show>
          <Show when={issueCount() > 0}>
            <span class="text-err">
              {issueCount()} issue{issueCount() === 1 ? "" : "s"} · fix before compile
            </span>
          </Show>
          <span
            class="text-fg-muted"
            title="Shift-drag select · ⌘/Ctrl multi-select · Del removes · double-click inserts"
          >
            {nodes.length} nodes · {edges.length} edges
          </span>
        </div>
      </div>
    </GraphIssuesProvider>
  );
}

function InternalsHook(props: {
  onReady: (
    fn: (id: string | string[]) => void,
    helpers: {
      screenToFlowPosition: (p: { x: number; y: number }) => { x: number; y: number };
      fitView: (opts?: {
        nodes?: Array<{ id: string }>;
        padding?: number;
        duration?: number;
      }) => void;
    },
  ) => void;
}) {
  const update = useUpdateNodeInternals();
  const flow = useSolidFlow();
  onMount(() =>
    props.onReady(update, {
      screenToFlowPosition: (p) => flow.screenToFlowPosition(p),
      fitView: (opts) => void flow.fitView(opts as never),
    }),
  );
  return null;
}

function toStoreNode(n: FlowNode & { selected?: boolean }) {
  return {
    id: n.id,
    type: n.type as MzNodeType,
    position: n.position,
    data: n.data as MzNodeData,
    width: n.width,
    height: n.height,
    selected: n.selected,
  };
}

function toStoreEdge(e: FlowEdge, reconnectable: boolean) {
  return {
    id: e.id,
    source: e.source,
    target: e.target,
    sourceHandle: e.sourceHandle ?? undefined,
    targetHandle: e.targetHandle ?? undefined,
    reconnectable,
  } as never;
}

/** Structural fingerprint of the flow (ignores selection / measured sizes). */
function flowSignature(flowNodes: FlowNode[], flowEdges: FlowEdge[]): string {
  return JSON.stringify({
    n: flowNodes.map((n) => [n.id, n.type, n.position.x, n.position.y, n.data]),
    e: flowEdges.map((e) => [
      e.id,
      e.source,
      e.target,
      e.sourceHandle ?? null,
      e.targetHandle ?? null,
    ]),
  });
}

/** Compat: old callers expect EditorDocument only. */
export function addNodeToDocument(doc: EditorDocument, kind: NodeKind): EditorDocument {
  return addNodeToDocumentCore(doc, kind).doc;
}

export { createNodeDraft };
