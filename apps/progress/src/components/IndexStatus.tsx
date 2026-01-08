import type { JSX } from "solid-js";
import { createResource, Show } from "solid-js";
import {
  indexData,
  indexMessage,
  NO_DATA_HINT,
  tryLoadIndex,
  type AppDataIndex,
} from "../lib/data";
import { MachineBanner } from "./MachineBanner";

export type IndexStatusProps = {
  /** Render body when index loaded successfully. */
  children: (data: AppDataIndex) => JSX.Element;
};

/**
 * Shared loader shell: fetches /data/index.json and shows loading / empty / body.
 */
export function IndexStatus(props: IndexStatusProps) {
  const [index] = createResource(tryLoadIndex);

  return (
    <>
      <Show when={index.loading}>
        <p class="text-sm text-fg-muted">Loading index…</p>
      </Show>

      <Show when={index.error}>
        <p class="text-sm text-err">Failed to load data.</p>
      </Show>

      <Show when={index()}>
        {(result) => {
          const data = () => indexData(result());
          const message = () => indexMessage(result()) || NO_DATA_HINT;
          return (
            <Show
              when={data()}
              fallback={
                <div class="rounded-md border border-line bg-panel px-4 py-6 text-sm text-fg-secondary">
                  {message()}
                </div>
              }
            >
              {(d) => (
                <div class="flex flex-col gap-3">
                  <MachineBanner
                    machineIds={d().machine_ids}
                    mixedMachines={d().mixed_machines}
                  />
                  {props.children(d())}
                </div>
              )}
            </Show>
          );
        }}
      </Show>
    </>
  );
}
