import { For, Show } from "solid-js";
import { SNIPPET_GROUPS } from "../../lib/autocomplete_catalog";
import { session } from "../../state/session";

const SHORTCUTS: { label: string; keys: string[] }[] = [
  { label: "Execute", keys: ["Enter"] },
  { label: "Complete", keys: ["Tab", "↑", "↓"] },
  { label: "History", keys: ["↑", "↓"] },
  { label: "Clear output", keys: ["Ctrl+L"] },
];

const LORENZ_SLIDERS: {
  id: "sigma" | "beta" | "rho" | "dt" | "steps";
  label: string;
  min: number;
  max: number;
  step: number;
}[] = [
  { id: "sigma", label: "Sigma (σ)", min: 0, max: 50, step: 0.1 },
  { id: "beta", label: "Beta (β)", min: 0, max: 10, step: 0.01 },
  { id: "rho", label: "Rho (ρ)", min: 0, max: 100, step: 0.1 },
  { id: "dt", label: "Step (dt)", min: 0.001, max: 0.1, step: 0.001 },
  { id: "steps", label: "Steps", min: 100, max: 20000, step: 100 },
];

function ListPanel(props: {
  title: string;
  items: readonly { expr: string; label: string }[];
  open?: boolean;
}) {
  return (
    <details class="panel-section bg-panel" open={props.open ?? false}>
      <summary class="panel-summary cursor-pointer px-2 py-2 text-[11px] font-semibold tracking-wider text-fg-secondary uppercase">
        {props.title}
      </summary>
      <div class="panel-section-body max-h-40 space-y-0 overflow-y-auto">
        <For each={[...props.items]}>
          {(item) => (
            <button
              type="button"
              class="flex w-full items-center justify-between gap-2 px-2 py-1.5 text-left hover:bg-active"
              title={`Insert ${item.expr} into input`}
              onClick={() => {
                session.insertSnippet(item.expr);
                session.setSidebarOpen(false);
              }}
            >
              <span class="text-[12px] text-fg">{item.label}</span>
              <span class="truncate font-mono text-[11px] text-fg-muted">{item.expr}</span>
            </button>
          )}
        </For>
      </div>
    </details>
  );
}

export function SidePanels() {
  return (
    <div class="flex min-h-0 flex-1 flex-col overflow-y-auto">
      <Show when={session.state.lorenzVisible}>
        <details class="panel-section bg-panel" open>
          <summary class="panel-summary cursor-pointer px-2 py-2 text-[11px] font-semibold tracking-wider text-fg-secondary uppercase">
            Lorenz Parameters
          </summary>
          <div class="panel-section-body space-y-3 px-2 py-2">
            <For each={LORENZ_SLIDERS}>
              {(s) => (
                <label class="block text-[11px] text-fg-secondary">
                  <div class="mb-1 flex justify-between gap-2">
                    <span>{s.label}</span>
                    <span class="font-mono text-number">{session.state.lorenzParams[s.id]}</span>
                  </div>
                  <input
                    type="range"
                    class="w-full accent-keyword"
                    min={s.min}
                    max={s.max}
                    step={s.step}
                    value={session.state.lorenzParams[s.id]}
                    onInput={(e) => session.setLorenzParam(s.id, Number(e.currentTarget.value))}
                  />
                </label>
              )}
            </For>
          </div>
        </details>
      </Show>

      <ListPanel title="Getting Started" items={SNIPPET_GROUPS.start} open />
      <ListPanel title="Data & Math" items={SNIPPET_GROUPS.data} />
      <ListPanel title="Simulations" items={SNIPPET_GROUPS.sims} />
      <ListPanel title="Plot Cheatsheet" items={SNIPPET_GROUPS.plots} />

      <details class="panel-section bg-panel">
        <summary class="panel-summary cursor-pointer px-2 py-2 text-[11px] font-semibold tracking-wider text-fg-secondary uppercase">
          Shortcuts
        </summary>
        <div class="panel-section-body space-y-1 px-2 py-2">
          <For each={SHORTCUTS}>
            {(row) => (
              <div class="flex items-center justify-between text-[12px]">
                <span class="text-fg-secondary">{row.label}</span>
                <span class="flex gap-1">
                  <For each={row.keys}>
                    {(k) => (
                      <kbd class="rounded border border-line bg-inset px-1.5 py-0.5 font-mono text-[11px] text-fg-muted">
                        {k}
                      </kbd>
                    )}
                  </For>
                </span>
              </div>
            )}
          </For>
        </div>
      </details>
    </div>
  );
}
