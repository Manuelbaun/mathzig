import { For, Show } from "solid-js";
import { A } from "@solidjs/router";
import { IndexStatus } from "../components/IndexStatus";
import { StatusPill } from "../components/StatusPill";
import { NO_DATA_HINT, packagesSortedBySeqDesc } from "../lib/data";

export function VersionsPage() {
  return (
    <div class="mx-auto flex w-full max-w-5xl flex-col gap-4">
      <header class="flex flex-col gap-1">
        <h1 class="text-lg font-semibold tracking-tight">Versions</h1>
        <p class="text-xs text-fg-muted">
          Progress packages sorted by seq (newest first).
        </p>
      </header>

      <IndexStatus>
        {(data) => (
          <Show
            when={data.package_count > 0}
            fallback={
              <div class="rounded-md border border-line bg-panel px-4 py-6 text-sm text-fg-secondary">
                {NO_DATA_HINT}
              </div>
            }
          >
            <p class="text-xs text-fg-muted">{data.package_count} package(s)</p>
            <div class="overflow-x-auto rounded-md border border-line bg-panel">
              <table class="w-full min-w-[40rem] border-collapse text-left text-xs">
                <thead>
                  <tr class="border-b border-line bg-inset text-fg-muted">
                    <th class="px-3 py-2 font-medium">seq</th>
                    <th class="px-3 py-2 font-medium">label</th>
                    <th class="px-3 py-2 font-medium">status</th>
                    <th class="px-3 py-2 font-medium">feature_id</th>
                    <th class="px-3 py-2 font-medium">recorded_at</th>
                    <th class="px-3 py-2 font-medium">perf</th>
                    <th class="px-3 py-2 font-medium"></th>
                  </tr>
                </thead>
                <tbody>
                  <For each={packagesSortedBySeqDesc(data.packages)}>
                    {(pkg) => (
                      <tr class="border-b border-line/60 last:border-0 hover:bg-raised/50">
                        <td class="px-3 py-2 font-mono text-fg-muted">{pkg.seq}</td>
                        <td class="px-3 py-2">
                          <div class="text-fg">{pkg.label}</div>
                          <div class="font-mono text-[11px] text-fg-muted truncate max-w-[16rem]">
                            {pkg.version_id}
                          </div>
                        </td>
                        <td class="px-3 py-2">
                          <StatusPill status={pkg.status} />
                        </td>
                        <td class="px-3 py-2 font-mono text-fg-secondary">
                          {pkg.feature_id}
                        </td>
                        <td class="px-3 py-2 font-mono text-fg-muted whitespace-nowrap">
                          {pkg.recorded_at}
                        </td>
                        <td class="px-3 py-2 font-mono text-fg-secondary">
                          {pkg.has_performance ? "yes" : "no"}
                        </td>
                        <td class="px-3 py-2 text-right">
                          <A
                            href={`/versions/${encodeURIComponent(pkg.version_id)}`}
                            class="text-keyword hover:underline"
                          >
                            open
                          </A>
                        </td>
                      </tr>
                    )}
                  </For>
                </tbody>
              </table>
            </div>
          </Show>
        )}
      </IndexStatus>
    </div>
  );
}
