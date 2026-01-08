import { createMemo, createResource, createSignal, For, Show } from "solid-js";
import { IndexStatus } from "../components/IndexStatus";
import { TrendChart } from "../components/TrendChart";
import {
  backendLabel,
  buildTrendLines,
  defaultMachineId,
  formatScore,
  NO_DATA_HINT,
  seriesBenchIds,
  seriesMachineIds,
  tryLoadSeries,
  type AppDataIndex,
  type AppDataSeries,
  type TrendLine,
} from "../lib/data";

export function TrendsPage() {
  return (
    <div class="mx-auto flex w-full max-w-5xl flex-col gap-4">
      <header class="flex flex-col gap-1">
        <h1 class="text-lg font-semibold tracking-tight">Trends</h1>
        <p class="text-xs text-fg-muted">
          Performance scores over version packages (X = seq, Y = score). One series
          per backend@threads.
        </p>
      </header>

      <IndexStatus>{(data) => <TrendsBody index={data} />}</IndexStatus>
    </div>
  );
}

function TrendsBody(props: { index: AppDataIndex }) {
  const [seriesResult] = createResource(tryLoadSeries);

  return (
    <>
      <Show when={seriesResult.loading}>
        <p class="text-sm text-fg-muted">Loading series…</p>
      </Show>

      <Show
        when={(() => {
          const r = seriesResult();
          return r && !r.ok ? r.message : null;
        })()}
      >
        {(msg) => (
          <div class="rounded-md border border-line bg-panel px-4 py-6 text-sm text-fg-secondary">
            {msg()}
          </div>
        )}
      </Show>

      <Show
        when={(() => {
          const r = seriesResult();
          return r?.ok ? r.data : null;
        })()}
      >
        {(series) => <TrendsPanel index={props.index} series={series()} />}
      </Show>
    </>
  );
}

function TrendsPanel(props: { index: AppDataIndex; series: AppDataSeries }) {
  const benchIds = createMemo(() => seriesBenchIds(props.series));
  const machinesInSeries = createMemo(() => seriesMachineIds(props.series));

  const machineChoices = createMemo(() => {
    const fromIndex = props.index.machine_ids;
    if (fromIndex.length > 0) return fromIndex;
    return machinesInSeries();
  });

  const [benchId, setBenchId] = createSignal<string>("");
  const [machineId, setMachineId] = createSignal<string>("");

  const activeBench = createMemo(() => {
    const ids = benchIds();
    const cur = benchId();
    if (cur && ids.includes(cur)) return cur;
    return ids[0] ?? "";
  });

  const activeMachine = createMemo(() => {
    const choices = machineChoices();
    const cur = machineId();
    if (cur === "__all__") return null;
    if (cur && choices.includes(cur)) return cur;
    return defaultMachineId(props.index, choices);
  });

  const lines = createMemo((): TrendLine[] => {
    const bench = activeBench();
    if (!bench) return [];
    return buildTrendLines(props.series, bench, activeMachine());
  });

  const multiMachine = createMemo(() => machineChoices().length > 1);

  // Flatten for table: one row per point, sorted by seq then series key
  const tableRows = createMemo(() => {
    const rows: Array<{
      seq: number;
      version_id: string;
      backend: string;
      threads: number;
      key: string;
      score: number;
      unit: string;
      recorded_at: string;
    }> = [];
    for (const line of lines()) {
      for (const p of line.points) {
        rows.push({
          seq: p.seq,
          version_id: p.version_id,
          backend: line.backend,
          threads: line.threads,
          key: line.key,
          score: p.score,
          unit: line.unit,
          recorded_at: p.recorded_at,
        });
      }
    }
    rows.sort((a, b) => {
      if (a.seq !== b.seq) return a.seq - b.seq;
      const kc = a.key.localeCompare(b.key);
      if (kc !== 0) return kc;
      return a.version_id.localeCompare(b.version_id);
    });
    return rows;
  });

  return (
    <Show
      when={benchIds().length > 0}
      fallback={
        <div class="rounded-md border border-line bg-panel px-4 py-6 text-sm text-fg-secondary">
          {props.index.package_count > 0
            ? "No performance series points — packages may lack has_performance results."
            : NO_DATA_HINT}
        </div>
      }
    >
      <div class="flex flex-col gap-4">
        <div class="flex flex-wrap items-end gap-3">
          <label class="flex flex-col gap-1 text-xs text-fg-secondary">
            <span class="text-fg-muted">bench_id</span>
            <select
              class="min-w-[12rem] rounded-md border border-line bg-inset px-2 py-1.5 font-mono text-xs text-fg"
              value={activeBench()}
              onChange={(e) => setBenchId(e.currentTarget.value)}
            >
              <For each={benchIds()}>
                {(id) => <option value={id}>{id}</option>}
              </For>
            </select>
          </label>

          <Show when={multiMachine()}>
            <label class="flex flex-col gap-1 text-xs text-fg-secondary">
              <span class="text-fg-muted">machine_id</span>
              <select
                class="min-w-[14rem] rounded-md border border-line bg-inset px-2 py-1.5 font-mono text-xs text-fg"
                value={activeMachine() ?? "__all__"}
                onChange={(e) => setMachineId(e.currentTarget.value)}
              >
                <For each={machineChoices()}>
                  {(id) => <option value={id}>{id}</option>}
                </For>
                <option value="__all__">all (mixed — not recommended)</option>
              </select>
            </label>
          </Show>

          <Show when={!multiMachine() && activeMachine()}>
            <span class="pb-1.5 font-mono text-[11px] text-fg-muted">
              machine={activeMachine()}
            </span>
          </Show>
        </div>

        <Show when={multiMachine() && activeMachine() === null}>
          <div
            class="rounded-md border border-warn/40 bg-warn/10 px-3 py-2 text-xs text-warn"
            role="alert"
          >
            Showing all machines — scores are not comparable across machines.
            Prefer a single machine_id.
          </div>
        </Show>

        <section class="flex flex-col gap-2">
          <div class="flex items-baseline justify-between gap-2">
            <h2 class="text-sm font-semibold text-fg">
              <span class="font-mono">{activeBench()}</span>
            </h2>
            <span class="text-[11px] text-fg-muted">
              {lines().length} series · {tableRows().length} point(s)
            </span>
          </div>
          <TrendChart lines={lines()} />
        </section>

        <section class="flex flex-col gap-2">
          <h2 class="text-sm font-semibold text-fg">Scores by version</h2>
          <Show
            when={tableRows().length > 0}
            fallback={
              <div class="rounded-md border border-line bg-panel px-4 py-6 text-sm text-fg-secondary">
                No points for this bench / machine filter.
              </div>
            }
          >
            <div class="overflow-x-auto rounded-md border border-line bg-panel">
              <table class="w-full min-w-[36rem] border-collapse text-left text-xs">
                <thead>
                  <tr class="border-b border-line bg-inset text-fg-muted">
                    <th class="px-3 py-2 font-medium">seq</th>
                    <th class="px-3 py-2 font-medium">version</th>
                    <th class="px-3 py-2 font-medium">backend@threads</th>
                    <th class="px-3 py-2 font-medium text-right">score</th>
                    <th class="px-3 py-2 font-medium">unit</th>
                    <th class="px-3 py-2 font-medium">recorded_at</th>
                  </tr>
                </thead>
                <tbody>
                  <For each={tableRows()}>
                    {(r) => (
                      <tr class="border-b border-line/60 last:border-0 hover:bg-raised/50">
                        <td class="px-3 py-1.5 font-mono text-fg-muted">{r.seq}</td>
                        <td
                          class="px-3 py-1.5 font-mono text-fg-secondary max-w-[14rem] truncate"
                          title={r.version_id}
                        >
                          {r.version_id}
                        </td>
                        <td
                          class="px-3 py-1.5 font-mono text-fg"
                          title={r.backend}
                        >
                          {backendLabel(r.backend)}@t{r.threads}
                        </td>
                        <td class="px-3 py-1.5 font-mono text-number text-right">
                          {formatScore(r.score)}
                        </td>
                        <td class="px-3 py-1.5 font-mono text-fg-muted">{r.unit}</td>
                        <td class="px-3 py-1.5 font-mono text-fg-muted whitespace-nowrap">
                          {r.recorded_at}
                        </td>
                      </tr>
                    )}
                  </For>
                </tbody>
              </table>
            </div>
          </Show>
        </section>
      </div>
    </Show>
  );
}
