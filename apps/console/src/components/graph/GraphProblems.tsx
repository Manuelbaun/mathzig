import { For, Show } from "solid-js";
import type { FlowNode } from "../../engine/graph/editor_types";
import type { ValidationIssue } from "../../engine/graph/validate_editor";

type Props = {
  issues: ValidationIssue[];
  nodes: FlowNode[];
  onSelectNodeId: (id: string) => void;
  onSelectIssue?: (issue: ValidationIssue) => void;
};

export function GraphProblems(props: Props) {
  return (
    <div class="px-3 py-2">
      <h2 class="mb-1.5 text-[10px] font-semibold tracking-wider text-fg-muted uppercase">
        Problems
      </h2>
      <Show
        when={props.issues.length > 0}
        fallback={<p class="text-[12px] text-fg-muted">No issues.</p>}
      >
        <ul class="max-h-36 space-y-1 overflow-y-auto font-mono text-[11px]">
          <For each={props.issues}>
            {(issue) => (
              <li>
                <button
                  type="button"
                  class="w-full rounded px-1.5 py-1 text-left hover:bg-inset"
                  classList={{
                    "text-err": issue.severity === "error",
                    "text-warn": issue.severity === "warning",
                  }}
                  onClick={() => {
                    if (issue.nodeId) props.onSelectNodeId(issue.nodeId);
                    props.onSelectIssue?.(issue);
                  }}
                >
                  {issue.message}
                </button>
              </li>
            )}
          </For>
        </ul>
      </Show>
    </div>
  );
}

export function GraphOutline(props: {
  nodes: FlowNode[];
  selectedId: string | null;
  onSelectNodeId: (id: string) => void;
  nodeTimings?: Record<string, number>;
}) {
  const typeLabel = (n: FlowNode) => {
    switch (n.data.mzType) {
      case "input":
        return "Input";
      case "const":
        return "Constant";
      case "expr":
        return "Expression";
      case "wasm":
        return "WASM";
      case "output":
        return "Output";
    }
  };

  return (
    <div class="px-3 py-2">
      <h2 class="mb-1.5 text-[10px] font-semibold tracking-wider text-fg-muted uppercase">
        Graph outline
      </h2>
      <Show
        when={props.nodes.length > 0}
        fallback={<p class="text-[12px] text-fg-muted">Empty graph.</p>}
      >
        <ul class="max-h-40 space-y-0.5 overflow-y-auto font-mono text-[11px]">
          <For each={props.nodes}>
            {(n) => {
              const ms = () => props.nodeTimings?.[n.id];
              return (
                <li>
                  <button
                    type="button"
                    class="flex w-full items-center justify-between gap-2 rounded px-1.5 py-1 text-left hover:bg-inset"
                    classList={{
                      "bg-keyword/15 text-fg": props.selectedId === n.id,
                      "text-fg-secondary": props.selectedId !== n.id,
                    }}
                    onClick={() => props.onSelectNodeId(n.id)}
                  >
                    <span>
                      <span class="text-fg-muted">{typeLabel(n)} · </span>
                      {n.id}
                    </span>
                    <Show when={ms() != null}>
                      <span class="text-[10px] text-fg-muted">{ms()!.toFixed(2)} ms</span>
                    </Show>
                  </button>
                </li>
              );
            }}
          </For>
        </ul>
      </Show>
    </div>
  );
}
