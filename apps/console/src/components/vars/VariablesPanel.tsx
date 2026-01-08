import { For, Show } from "solid-js";
import { CONSTANT_ITEMS } from "../../lib/autocomplete_catalog";
import { session } from "../../state/session";

export function VariablesPanel() {
  const names = () => Object.keys(session.state.variables).sort();

  return (
    <div class="flex min-h-0 flex-col">
      <details class="panel-section group bg-panel" open>
        <summary class="panel-summary cursor-pointer px-2 py-2 text-[11px] font-semibold tracking-wider text-fg-secondary uppercase">
          Variables / Memory
        </summary>
        <div class="panel-section-body max-h-48 space-y-0 overflow-y-auto">
          <Show
            when={names().length > 0}
            fallback={
              <p class="px-2 py-3 text-center text-[12px] text-fg-muted">
                No variables yet. Assign with{" "}
                <span class="font-mono text-keyword">x = 1</span>
              </p>
            }
          >
            <For each={names()}>
              {(name) => {
                const v = () => session.state.variables[name]!;
                return (
                  <button
                    type="button"
                    class="flex w-full items-center gap-2 px-2 py-1.5 text-left hover:bg-active"
                    classList={{
                      "bg-active": session.state.inspector.open && session.state.inspector.name === name,
                    }}
                    onClick={() => session.openInspector(name, v())}
                  >
                    <span class="font-mono text-[12px] text-variable">{name}</span>
                    <span class="ml-auto truncate font-mono text-[11px] text-fg-muted">{v().value}</span>
                    <span class="shrink-0 rounded bg-inset px-1.5 py-0.5 text-[10px] text-type">{v().type}</span>
                  </button>
                );
              }}
            </For>
          </Show>
        </div>
      </details>

      <details class="panel-section bg-panel">
        <summary class="panel-summary cursor-pointer px-2 py-2 text-[11px] font-semibold tracking-wider text-fg-secondary uppercase">
          Constants
        </summary>
        <div class="panel-section-body space-y-0">
          <For each={CONSTANT_ITEMS}>
            {(c) => (
              <button
                type="button"
                class="flex w-full items-center gap-2 px-2 py-1.5 text-left hover:bg-active"
                title={`Insert ${c.insert}`}
                onClick={() => session.insertSnippet(c.insert)}
              >
                <span class="font-mono text-[12px] text-keyword">{c.label}</span>
                <span class="ml-auto font-mono text-[11px] text-fg-muted">{c.detail}</span>
              </button>
            )}
          </For>
        </div>
      </details>
    </div>
  );
}
