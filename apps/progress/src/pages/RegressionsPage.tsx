import { createMemo, createResource, createSignal, For, Show } from "solid-js";
import { A } from "@solidjs/router";
import { IndexStatus } from "../components/IndexStatus";
import { StatusPill } from "../components/StatusPill";
import {
  backendLabel,
  comparePerformanceClient,
  DEFAULT_REGRESSION_THRESHOLD_PCT,
  defaultMachineId,
  formatPctDelta,
  formatScore,
  latestCompareToClientRows,
  NO_DATA_HINT,
  packagesWithPerformance,
  regressionPair,
  tryLoadLatestCompare,
  tryLoadPackages,
  type AppDataIndex,
  type ClientCompareRow,
  type ProgressIndexEntry,
  type SlimPackage,
} from "../lib/data";

export function RegressionsPage() {
  return (
    <div class="mx-auto flex w-full max-w-5xl flex-col gap-4">
      <header class="flex flex-col gap-1">
        <h1 class="text-lg font-semibold tracking-tight">Regressions</h1>
        <p class="text-xs text-fg-muted">
          Auto: latest run vs previous (written by <span class="font-mono">bun run mz</span>
          → <span class="font-mono">latest_compare.json</span>). No manual tags.
        </p>
      </header>

      <IndexStatus>{(data) => <RegressionsBody index={data} />}</IndexStatus>
    </div>
  );
}

function RegressionsBody(props: { index: AppDataIndex }) {
  const [packagesResult] = createResource(tryLoadPackages);
  const [latestCompareResult] = createResource(tryLoadLatestCompare);
  const [threshold, setThreshold] = createSignal(DEFAULT_REGRESSION_THRESHOLD_PCT);
  const [machineOverride, setMachineOverride] = createSignal<string>("");

  const machineChoices = createMemo(() => props.index.machine_ids);

  const activeMachine = createMemo(() => {
    const cur = machineOverride();
    if (cur && machineChoices().includes(cur)) return cur;
    return defaultMachineId(props.index);
  });

  const pair = createMemo(() => regressionPair(props.index, activeMachine()));

  const packagesMap = createMemo((): Record<string, SlimPackage> | null => {
    const r = packagesResult();
    if (!r?.ok) return null;
    return r.data.packages;
  });

  /** Prefer server auto-compare from mz; fall back to client recompute. */
  const autoCompare = createMemo(() => {
    const r = latestCompareResult();
    if (!r?.ok) return null;
    return r.data;
  });

  const rows = createMemo((): ClientCompareRow[] => {
    const auto = autoCompare();
    if (auto?.status === "ok" && auto.compare) {
      return latestCompareToClientRows(auto);
    }
    const { after, baseline } = pair();
    const pkgs = packagesMap();
    if (!after || !baseline || !pkgs) return [];
    const afterPkg = pkgs[after.version_id];
    const basePkg = pkgs[baseline.version_id];
    if (!afterPkg || !basePkg) return [];
    if (afterPkg.performance.status !== "ok" || basePkg.performance.status !== "ok") {
      return [];
    }
    return comparePerformanceClient(
      basePkg.performance.results ?? [],
      afterPkg.performance.results ?? [],
      threshold()
    );
  });

  const failureCount = createMemo(() => {
    const auto = autoCompare();
    if (auto?.status === "ok" && auto.failure_count != null) return auto.failure_count;
    return rows().filter((r) => r.status === "REGRESSION").length;
  });

  const perfOnMachine = createMemo(() =>
    packagesWithPerformance(props.index, activeMachine())
  );

  const pairFromAuto = createMemo(() => {
    const auto = autoCompare();
    if (!auto || auto.status !== "ok") return null;
    const pkgs = props.index.packages;
    const after =
      pkgs.find((p) => p.version_id === auto.after_version_id) ??
      pkgs.find((p) => p.feature_id === auto.after_automatic_tag) ??
      null;
    const baseline =
      pkgs.find((p) => p.version_id === auto.baseline_version_id) ??
      pkgs.find((p) => p.feature_id === auto.baseline_automatic_tag) ??
      null;
    return { after, baseline };
  });

  return (
    <div class="flex flex-col gap-4">
      <div class="flex flex-wrap items-end gap-3">
        <Show when={machineChoices().length > 1}>
          <label class="flex flex-col gap-1 text-xs text-fg-secondary">
            <span class="text-fg-muted">machine_id</span>
            <select
              class="min-w-[14rem] rounded-md border border-line bg-inset px-2 py-1.5 font-mono text-xs text-fg"
              value={activeMachine() ?? ""}
              onChange={(e) => setMachineOverride(e.currentTarget.value)}
            >
              <For each={machineChoices()}>
                {(id) => <option value={id}>{id}</option>}
              </For>
            </select>
          </label>
        </Show>
        <Show when={machineChoices().length <= 1 && activeMachine()}>
          <span class="pb-1.5 font-mono text-[11px] text-fg-muted">
            machine={activeMachine()}
          </span>
        </Show>

        <label class="flex flex-col gap-1 text-xs text-fg-secondary">
          <span class="text-fg-muted">threshold %</span>
          <input
            type="number"
            min={0}
            max={100}
            step={0.5}
            class="w-20 rounded-md border border-line bg-inset px-2 py-1.5 font-mono text-xs text-fg"
            value={threshold()}
            onChange={(e) => {
              const n = Number(e.currentTarget.value);
              if (Number.isFinite(n) && n >= 0) setThreshold(n);
            }}
          />
        </label>
      </div>

      <Show when={packagesResult.loading}>
        <p class="text-sm text-fg-muted">Loading package data…</p>
      </Show>

      <Show
        when={(() => {
          const r = packagesResult();
          return r && !r.ok ? r.message : null;
        })()}
      >
        {(msg) => (
          <div class="rounded-md border border-line bg-panel px-4 py-6 text-sm text-fg-secondary">
            {msg()}
          </div>
        )}
      </Show>

      <Show when={latestCompareResult.loading || packagesResult.loading}>
        <p class="text-sm text-fg-muted">Loading auto-compare…</p>
      </Show>

      <Show
        when={(() => {
          const auto = autoCompare();
          return auto?.status === "insufficient" || auto?.status === "error"
            ? auto.reason ?? auto.status
            : null;
        })()}
      >
        {(reason) => (
          <div class="rounded-md border border-line bg-panel px-4 py-4 text-sm text-fg-secondary">
            {reason()}
            <p class="mt-2 text-xs text-fg-muted">
              Full runs auto-compare after the second package with performance.
            </p>
          </div>
        )}
      </Show>

      <Show
        when={rows().length > 0 || perfOnMachine().length >= 2}
        fallback={
          <div class="rounded-md border border-line bg-panel px-4 py-6 text-sm text-fg-secondary">
            <Show
              when={props.index.package_count > 0}
              fallback={<span>{NO_DATA_HINT}</span>}
            >
              <span>
                Need at least two packages with performance to auto-compare.
                Run <span class="font-mono">bun run mz</span> twice (full, not
                --skip-measure).
              </span>
            </Show>
          </div>
        }
      >
        <PairCard
          after={pairFromAuto()?.after ?? pair().after}
          baseline={pairFromAuto()?.baseline ?? pair().baseline}
          afterTag={autoCompare()?.after_automatic_tag}
          baselineTag={autoCompare()?.baseline_automatic_tag}
        />

        <Show
          when={rows().length > 0}
          fallback={
            <div class="rounded-md border border-line bg-panel px-4 py-6 text-sm text-fg-secondary">
              Compare not ready yet (missing performance on latest and/or previous
              package).
            </div>
          }
        >
          <div class="flex flex-wrap items-center justify-between gap-2 text-xs">
            <span class="text-fg-muted">
              {rows().length} row(s)
              {autoCompare()?.status === "ok"
                ? " · auto latest_compare.json"
                : ` · threshold ±${threshold()}%`}{" "}
              (higher score = better)
            </span>
            <span
              class="font-mono"
              classList={{
                "text-err": failureCount() > 0,
                "text-ok": failureCount() === 0,
              }}
            >
              {failureCount()} regression(s)
            </span>
          </div>

          <div class="overflow-x-auto rounded-md border border-line bg-panel">
            <table class="w-full min-w-[40rem] border-collapse text-left text-xs">
              <thead>
                <tr class="border-b border-line bg-inset text-fg-muted">
                  <th class="px-3 py-2 font-medium">bench_id</th>
                  <th class="px-3 py-2 font-medium">backend</th>
                  <th class="px-3 py-2 font-medium">threads</th>
                  <th class="px-3 py-2 font-medium text-right">baseline</th>
                  <th class="px-3 py-2 font-medium text-right">after</th>
                  <th class="px-3 py-2 font-medium text-right">pct</th>
                  <th class="px-3 py-2 font-medium">status</th>
                </tr>
              </thead>
              <tbody>
                <For each={rows()}>
                  {(r) => <CompareRow r={r} />}
                </For>
              </tbody>
            </table>
          </div>
          <p class="text-[11px] text-fg-muted">
            Prepared automatically after each full <span class="font-mono">mz</span>{" "}
            run. No tags to pick.
          </p>
        </Show>
      </Show>
    </div>
  );
}

function PairCard(props: {
  after: ProgressIndexEntry | null;
  baseline: ProgressIndexEntry | null;
  afterTag?: string | null;
  baselineTag?: string | null;
}) {
  return (
    <div class="grid gap-3 sm:grid-cols-2">
      <VersionMini
        label="After (latest)"
        entry={props.after}
        automaticTag={props.afterTag}
      />
      <VersionMini
        label="Baseline (previous)"
        entry={props.baseline}
        automaticTag={props.baselineTag}
      />
    </div>
  );
}

function VersionMini(props: {
  label: string;
  entry: ProgressIndexEntry | null;
  automaticTag?: string | null;
}) {
  return (
    <div class="rounded-md border border-line bg-panel px-3 py-3">
      <div class="mb-1 text-[11px] uppercase tracking-wide text-fg-muted">
        {props.label}
      </div>
      <Show
        when={props.entry}
        fallback={
          <div class="flex flex-col gap-1">
            <Show
              when={props.automaticTag}
              fallback={<span class="text-sm text-fg-secondary">—</span>}
            >
              <span class="font-mono text-xs text-fg-secondary break-all">
                {props.automaticTag}
              </span>
            </Show>
          </div>
        }
      >
        {(e) => (
          <div class="flex flex-col gap-1">
            <A
              href={`/versions/${encodeURIComponent(e().version_id)}`}
              class="font-mono text-xs text-keyword hover:underline break-all"
            >
              {e().version_id}
            </A>
            <div class="flex flex-wrap items-center gap-1.5 text-[11px]">
              <span class="font-mono text-fg-muted">seq {e().seq}</span>
              <StatusPill status={e().status} />
            </div>
            <span class="font-mono text-[11px] text-fg-secondary break-all">
              {props.automaticTag || e().label || e().feature_id}
            </span>
          </div>
        )}
      </Show>
    </div>
  );
}

function CompareRow(props: { r: ClientCompareRow }) {
  const r = () => props.r;
  const rowClass = createMemo(() => {
    switch (r().status) {
      case "REGRESSION":
        return "bg-err/10";
      case "IMPROVEMENT":
        return "bg-ok/10";
      default:
        return "";
    }
  });
  const pctClass = createMemo(() => {
    switch (r().status) {
      case "REGRESSION":
        return "text-err";
      case "IMPROVEMENT":
        return "text-ok";
      default:
        return "text-fg-secondary";
    }
  });

  return (
    <tr class={`border-b border-line/60 last:border-0 hover:bg-raised/50 ${rowClass()}`}>
      <td class="px-3 py-1.5 font-mono text-fg">{r().bench_id}</td>
      <td class="px-3 py-1.5 font-mono text-fg-secondary" title={r().backend}>
        {backendLabel(r().backend)}
      </td>
      <td class="px-3 py-1.5 font-mono text-fg-muted">{r().threads}</td>
      <td class="px-3 py-1.5 font-mono text-right text-fg-secondary">
        {r().baseline_score !== null ? formatScore(r().baseline_score!) : "—"}
      </td>
      <td class="px-3 py-1.5 font-mono text-right text-fg-secondary">
        {r().after_score !== null ? formatScore(r().after_score!) : "—"}
      </td>
      <td class={`px-3 py-1.5 font-mono text-right ${pctClass()}`}>
        {formatPctDelta(r().pct_delta)}
      </td>
      <td class="px-3 py-1.5">
        <StatusPill status={r().status} />
      </td>
    </tr>
  );
}
