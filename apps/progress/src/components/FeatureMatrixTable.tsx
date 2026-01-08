import { createMemo, For, Show } from "solid-js";
import { StatusPill } from "./StatusPill";
import {
  parityBackendLabel,
  type FeatureCell,
  type FeatureCellBackend,
} from "../lib/data";

export type SelectedCell = {
  feature: FeatureCell;
  backend: string;
  cell: FeatureCellBackend;
};

export type FeatureMatrixTableProps = {
  cells: FeatureCell[];
  backends: string[];
  backendsExecuted: string[];
  selected: SelectedCell | null;
  onSelect: (sel: SelectedCell | null) => void;
};

function cellTooltip(
  cell: FeatureCellBackend | undefined,
  executed: boolean
): string {
  if (!cell) {
    return executed ? "no cell data" : "not run this version";
  }
  if (cell.evidence === "not_executed" || !executed) {
    return "not run this version";
  }
  const parts = [`status=${cell.status}`, `evidence=${cell.evidence}`];
  if (cell.pass !== undefined) parts.push(`pass=${cell.pass}`);
  if (cell.fail !== undefined) parts.push(`fail=${cell.fail}`);
  if (cell.skip !== undefined) parts.push(`skip=${cell.skip}`);
  return parts.join(" · ");
}

export function FeatureMatrixTable(props: FeatureMatrixTableProps) {
  const executedSet = createMemo(() => new Set(props.backendsExecuted));

  const isSelected = (featureId: string, backend: string) => {
    const s = props.selected;
    return s?.feature.feature_id === featureId && s.backend === backend;
  };

  return (
    <div class="overflow-x-auto rounded-md border border-line bg-panel">
      <table class="w-full min-w-[40rem] border-collapse text-left text-xs">
        <thead>
          <tr class="border-b border-line bg-inset/60 text-fg-muted">
            <th class="sticky left-0 z-10 bg-inset/95 py-2 pl-3 pr-3 font-medium">
              feature
            </th>
            <th class="py-2 pr-3 font-medium">category</th>
            <For each={props.backends}>
              {(be) => {
                const exec = () => executedSet().has(be);
                return (
                  <th class="py-2 px-2 font-medium text-center">
                    <div class="flex flex-col items-center gap-0.5">
                      <span class="font-mono text-fg" title={be}>
                        {parityBackendLabel(be)}
                      </span>
                      <span
                        class={`text-[10px] font-normal ${
                          exec() ? "text-ok" : "text-fg-muted"
                        }`}
                      >
                        {exec() ? "executed" : "not run"}
                      </span>
                    </div>
                  </th>
                );
              }}
            </For>
          </tr>
        </thead>
        <tbody>
          <Show
            when={props.cells.length > 0}
            fallback={
              <tr>
                <td
                  class="px-3 py-6 text-sm text-fg-secondary"
                  colspan={2 + props.backends.length}
                >
                  No feature cells in this matrix.
                </td>
              </tr>
            }
          >
            <For each={props.cells}>
              {(feature) => (
                <tr class="border-b border-line/50 last:border-0 hover:bg-raised/40">
                  <td class="sticky left-0 z-10 bg-panel py-1.5 pl-3 pr-3">
                    <div class="font-medium text-fg">{feature.label}</div>
                    <div class="font-mono text-[10px] text-fg-muted">
                      {feature.feature_id}
                    </div>
                  </td>
                  <td class="py-1.5 pr-3 font-mono text-fg-secondary">
                    {feature.category}
                  </td>
                  <For each={props.backends}>
                    {(backend) => {
                      const cell = () =>
                        feature.by_backend?.[backend] ?? {
                          status: "unknown",
                          evidence: executedSet().has(backend)
                            ? "missing_cell"
                            : "not_executed",
                        };
                      const executed = () => executedSet().has(backend);
                      return (
                        <td class="py-1.5 px-2 text-center">
                          <button
                            type="button"
                            class={`inline-flex rounded-md p-0.5 transition-colors ${
                              isSelected(feature.feature_id, backend)
                                ? "bg-active ring-1 ring-focus"
                                : "hover:bg-raised"
                            }`}
                            title={cellTooltip(cell(), executed())}
                            onClick={() => {
                              if (isSelected(feature.feature_id, backend)) {
                                props.onSelect(null);
                              } else {
                                props.onSelect({
                                  feature,
                                  backend,
                                  cell: cell(),
                                });
                              }
                            }}
                          >
                            <StatusPill
                              status={cell().status}
                              title={cellTooltip(cell(), executed())}
                            />
                          </button>
                        </td>
                      );
                    }}
                  </For>
                </tr>
              )}
            </For>
          </Show>
        </tbody>
      </table>
    </div>
  );
}
