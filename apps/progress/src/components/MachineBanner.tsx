import { Show } from "solid-js";

export type MachineBannerProps = {
  machineIds: string[];
  mixedMachines: boolean;
};

/**
 * Warns when progress packages span multiple machine_ids
 * (cross-machine perf compare is forbidden / misleading).
 */
export function MachineBanner(props: MachineBannerProps) {
  return (
    <Show when={props.mixedMachines || props.machineIds.length > 0}>
      <div
        class="rounded-md border px-3 py-2 text-xs"
        classList={{
          "border-warn/40 bg-warn/10 text-warn": props.mixedMachines,
          "border-line bg-inset text-fg-secondary": !props.mixedMachines,
        }}
        role={props.mixedMachines ? "alert" : "status"}
      >
        <Show
          when={props.mixedMachines}
          fallback={
            <span>
              Machine:{" "}
              <span class="font-mono text-fg">
                {props.machineIds[0] ?? "unknown"}
              </span>
            </span>
          }
        >
          <span class="font-semibold">Mixed machines</span>
          <span class="text-fg-muted"> — </span>
          <span>
            packages span {props.machineIds.length} machine_ids:{" "}
            <span class="font-mono text-fg">{props.machineIds.join(", ")}</span>
            . Filter to one machine before comparing performance.
          </span>
        </Show>
      </div>
    </Show>
  );
}
