import { createMemo, createSignal, For, Show } from "solid-js";
import {
  backendLabel,
  defaultThreadFilter,
  formatRatio,
  formatScore,
  ratioKey,
  RATIO_BASELINES,
  scoreLookup,
  uniqueThreads,
  type SlimPerformance,
  type SlimPerformanceResult,
} from "../lib/data";

export type PerfResultsTableProps = {
  performance: SlimPerformance;
  /** Compact caption under the table header. */
  caption?: string;
};

/**
 * Performance results table with thread filter and optional ratio columns
 * (score / mathzig_zig, native_js, ref_*) when denominators exist.
 */
export function PerfResultsTable(props: PerfResultsTableProps) {
  const allResults = () => props.performance.results ?? [];
  const threads = createMemo(() => uniqueThreads(allResults()));
  const [threadFilter, setThreadFilter] = createSignal<number | null>(null);

  const activeThread = createMemo(() => {
    const t = threadFilter();
    if (t !== null && threads().includes(t)) return t;
    return defaultThreadFilter(threads());
  });

  const filtered = createMemo(() => {
    const thr = activeThread();
    return allResults()
      .filter((r) => r.threads === thr)
      .slice()
      .sort((a, b) => {
        const bc = a.bench_id.localeCompare(b.bench_id);
        if (bc !== 0) return bc;
        return a.backend.localeCompare(b.backend);
      });
  });

  const lookup = createMemo(() => scoreLookup(filtered()));

  /** Which ratio columns have at least one usable baseline in this filter. */
  const activeRatios = createMemo(() => {
    const map = lookup();
    return RATIO_BASELINES.filter((rb) =>
      filtered().some((r) => {
        if (r.backend === rb.backend) return false;
        const base = map.get(ratioKey(r.bench_id, r.threads, rb.backend));
        return base !== undefined && base !== 0;
      })
    );
  });

  const ratioFor = (r: SlimPerformanceResult, baselineBackend: string) => {
    const base = lookup().get(ratioKey(r.bench_id, r.threads, baselineBackend));
    if (base === undefined || base === 0) return null;
    if (r.backend === baselineBackend) return 1;
    return r.score / base;
  };

  return (
    <div class="flex flex-col gap-3">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="text-xs text-fg-muted">
          <Show
            when={props.performance.status === "ok"}
            fallback={
              <span>
                Performance:{" "}
                <span class="font-mono text-fg">{props.performance.status}</span>
                <Show when={props.performance.reason}>
                  {(reason) => (
                    <span class="text-fg-muted"> — {reason()}</span>
                  )}
                </Show>
              </span>
            }
          >
            <span>
              {filtered().length} result(s)
              <Show when={props.performance.snapshot_id}>
                {(id) => (
                  <span class="text-fg-muted">
                    {" "}
                    · snapshot <span class="font-mono text-fg-secondary">{id()}</span>
                  </span>
                )}
              </Show>
              <Show when={props.caption}>
                {(c) => <span class="text-fg-muted"> · {c()}</span>}
              </Show>
            </span>
          </Show>
        </div>

        <Show when={threads().length > 1}>
          <label class="flex items-center gap-2 text-xs text-fg-secondary">
            <span class="text-fg-muted">Threads</span>
            <select
              class="rounded-md border border-line bg-inset px-2 py-1 font-mono text-xs text-fg"
              value={String(activeThread())}
              onChange={(e) => setThreadFilter(Number(e.currentTarget.value))}
            >
              <For each={threads()}>
                {(t) => <option value={String(t)}>{t}</option>}
              </For>
            </select>
          </label>
        </Show>
        <Show when={threads().length === 1}>
          <span class="text-[11px] font-mono text-fg-muted">
            threads={threads()[0]}
          </span>
        </Show>
      </div>

      <Show
        when={props.performance.status === "ok" && allResults().length > 0}
        fallback={
          <div class="rounded-md border border-line bg-panel px-4 py-6 text-sm text-fg-secondary">
            <Show
              when={props.performance.status === "ok"}
              fallback={
                <span>
                  No performance results
                  <Show when={props.performance.reason}>
                    {(r) => <span class="text-fg-muted"> ({r()})</span>}
                  </Show>
                  .
                </span>
              }
            >
              No performance results recorded.
            </Show>
          </div>
        }
      >
        <Show
          when={filtered().length > 0}
          fallback={
            <div class="rounded-md border border-line bg-panel px-4 py-6 text-sm text-fg-secondary">
              No results for threads={activeThread()}.
            </div>
          }
        >
          <div class="overflow-x-auto rounded-md border border-line bg-panel">
            <table class="w-full min-w-[32rem] border-collapse text-left text-xs">
              <thead>
                <tr class="border-b border-line bg-inset text-fg-muted">
                  <th class="px-3 py-2 font-medium">bench_id</th>
                  <th class="px-3 py-2 font-medium">backend</th>
                  <th class="px-3 py-2 font-medium">threads</th>
                  <th class="px-3 py-2 font-medium text-right">score</th>
                  <th class="px-3 py-2 font-medium">unit</th>
                  <For each={activeRatios()}>
                    {(rb) => (
                      <th class="px-3 py-2 font-medium text-right">{rb.column}</th>
                    )}
                  </For>
                </tr>
              </thead>
              <tbody>
                <For each={filtered()}>
                  {(r) => (
                    <tr class="border-b border-line/60 last:border-0 hover:bg-raised/50">
                      <td class="px-3 py-1.5 font-mono text-fg">{r.bench_id}</td>
                      <td class="px-3 py-1.5 font-mono text-fg-secondary" title={r.backend}>
                        {backendLabel(r.backend)}
                      </td>
                      <td class="px-3 py-1.5 font-mono text-fg-muted">{r.threads}</td>
                      <td class="px-3 py-1.5 font-mono text-number text-right">
                        {formatScore(r.score)}
                      </td>
                      <td class="px-3 py-1.5 font-mono text-fg-muted">{r.unit}</td>
                      <For each={activeRatios()}>
                        {(rb) => {
                          const ratio = () => ratioFor(r, rb.backend);
                          return (
                            <td class="px-3 py-1.5 font-mono text-right text-fg-secondary">
                              <Show when={ratio() !== null} fallback={<span class="text-fg-muted">—</span>}>
                                {formatRatio(r.score, lookup().get(ratioKey(r.bench_id, r.threads, rb.backend))!)}
                              </Show>
                            </td>
                          );
                        }}
                      </For>
                    </tr>
                  )}
                </For>
              </tbody>
            </table>
          </div>
          <Show when={activeRatios().length > 0}>
            <p class="text-[11px] text-fg-muted">
              Ratio columns = score / baseline for the same bench_id + threads.
              Empty cells mean the baseline backend is not present for that bench.
            </p>
          </Show>
        </Show>
      </Show>
    </div>
  );
}
