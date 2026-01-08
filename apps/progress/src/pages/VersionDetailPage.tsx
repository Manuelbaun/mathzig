import { createMemo, createResource, For, Show, type Accessor } from "solid-js";
import { A, useParams } from "@solidjs/router";
import { IndexStatus } from "../components/IndexStatus";
import { PerfResultsTable } from "../components/PerfResultsTable";
import { StatusPill } from "../components/StatusPill";
import {
  aggregateStatusHistogram,
  HISTOGRAM_KEYS,
  NO_DATA_HINT,
  tryLoadPackages,
  type AppDataIndex,
  type ProgressIndexEntry,
  type SlimFeatures,
  type SlimMeta,
  type SlimPackage,
} from "../lib/data";

export function VersionDetailPage() {
  const params = useParams<{ id: string }>();
  const versionId = () => decodeURIComponent(params.id ?? "");

  return (
    <div class="mx-auto flex w-full max-w-5xl flex-col gap-4">
      <header class="flex flex-col gap-1">
        <div class="text-xs">
          <A href="/versions" class="text-keyword hover:underline">
            ← Versions
          </A>
          <span class="text-fg-muted"> · </span>
          <A href="/" class="text-keyword hover:underline">
            Overview
          </A>
        </div>
        <h1 class="text-lg font-semibold tracking-tight font-mono break-all">
          {versionId() || "Version"}
        </h1>
        <p class="text-xs text-fg-muted">
          Structured package fields (meta, correctness, features summary, performance).
        </p>
      </header>

      <IndexStatus>
        {(data) => <VersionDetailBody index={data} versionId={versionId()} />}
      </IndexStatus>
    </div>
  );
}

function VersionDetailBody(props: { index: AppDataIndex; versionId: string }) {
  const [packagesResult] = createResource(tryLoadPackages);

  const entry = createMemo(
    (): ProgressIndexEntry | undefined =>
      props.index.packages.find((p) => p.version_id === props.versionId)
  );

  const slim = createMemo((): SlimPackage | null => {
    const res = packagesResult();
    if (!res?.ok) return null;
    return res.data.packages[props.versionId] ?? null;
  });

  return (
    <Show
      when={entry()}
      fallback={
        <div class="rounded-md border border-line bg-panel px-4 py-6 text-sm text-fg-secondary">
          Package not found in index:{" "}
          <span class="font-mono text-fg">{props.versionId}</span>
          <Show when={props.index.package_count === 0}>
            <span class="block mt-2 text-xs">{NO_DATA_HINT}</span>
          </Show>
        </div>
      }
    >
      {(p) => (
        <div class="flex flex-col gap-5">
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
              <div class="rounded-md border border-line bg-panel px-4 py-4 text-sm text-fg-secondary">
                Could not load packages.json — showing index fields only.
                <div class="mt-1 text-xs text-fg-muted">{msg()}</div>
              </div>
            )}
          </Show>

          <section class="flex flex-col gap-2">
            <h2 class="text-sm font-semibold text-fg">Meta</h2>
            <MetaPanel entry={p} meta={() => slim()?.meta} />
          </section>

          <section class="flex flex-col gap-2">
            <h2 class="text-sm font-semibold text-fg">Correctness</h2>
            <Show
              when={slim()?.correctness}
              fallback={
                <div class="rounded-md border border-line bg-panel px-4 py-4 text-sm text-fg-secondary">
                  Correctness payload not loaded.
                </div>
              }
            >
              {(c) => (
                <div class="rounded-md border border-line bg-panel px-4 py-4 flex flex-col gap-3">
                  <div class="flex flex-wrap items-center gap-2 text-sm">
                    <span class="text-fg-muted text-xs">Overall</span>
                    <StatusPill status={c().overall} />
                    <Show when={c().gate_started_at}>
                      <span class="font-mono text-[11px] text-fg-muted">
                        gate {c().gate_started_at}
                      </span>
                    </Show>
                  </div>
                  <div class="overflow-x-auto">
                    <table class="w-full min-w-[24rem] border-collapse text-left text-xs">
                      <thead>
                        <tr class="border-b border-line text-fg-muted">
                          <th class="py-1.5 pr-3 font-medium">step</th>
                          <th class="py-1.5 pr-3 font-medium">status</th>
                          <th class="py-1.5 pr-3 font-medium text-right">
                            duration_sec
                          </th>
                          <th class="py-1.5 font-medium">reason</th>
                        </tr>
                      </thead>
                      <tbody>
                        <For each={c().steps}>
                          {(step) => (
                            <tr class="border-b border-line/50 last:border-0">
                              <td class="py-1.5 pr-3 font-mono text-fg">
                                {step.id}
                              </td>
                              <td class="py-1.5 pr-3">
                                <StatusPill status={step.status} />
                              </td>
                              <td class="py-1.5 pr-3 font-mono text-right text-fg-secondary">
                                {step.duration_sec ?? "—"}
                              </td>
                              <td class="py-1.5 font-mono text-fg-muted">
                                {step.reason ?? ""}
                              </td>
                            </tr>
                          )}
                        </For>
                      </tbody>
                    </table>
                  </div>
                  <Show when={c().parity}>
                    {(parity) => (
                      <div class="text-[11px] text-fg-muted">
                        Parity task{" "}
                        <span class="font-mono text-fg-secondary">
                          {parity().task_id}
                        </span>
                        {" · "}
                        backends executed:{" "}
                        <span class="font-mono text-fg-secondary">
                          {parity().backends_executed.join(", ") || "—"}
                        </span>
                      </div>
                    )}
                  </Show>
                </div>
              )}
            </Show>
          </section>

          <section class="flex flex-col gap-2">
            <h2 class="text-sm font-semibold text-fg">Features summary</h2>
            <FeaturesSummaryPanel features={slim()?.features ?? null} />
          </section>

          <section class="flex flex-col gap-2">
            <h2 class="text-sm font-semibold text-fg">Performance</h2>
            <Show
              when={slim()?.performance}
              fallback={
                <div class="rounded-md border border-line bg-panel px-4 py-4 text-sm text-fg-secondary">
                  {p().has_performance
                    ? "Performance payload not loaded."
                    : "No performance recorded for this package."}
                </div>
              }
            >
              {(perf) => <PerfResultsTable performance={perf()} />}
            </Show>
          </section>
        </div>
      )}
    </Show>
  );
}

function MetaPanel(props: {
  entry: Accessor<ProgressIndexEntry>;
  meta: Accessor<SlimMeta | undefined>;
}) {
  const rows = createMemo(() => {
    const meta = props.meta();
    const entry = props.entry();
    const fields: Array<[string, string]> = [
      ["version_id", meta?.version_id ?? entry.version_id],
      ["seq", String(meta?.seq ?? entry.seq)],
      ["label", meta?.label ?? entry.label],
      ["kind", meta?.kind ?? entry.kind],
      ["status", meta?.status ?? entry.status],
      ["feature_id", meta?.feature_id ?? entry.feature_id],
      ["git_sha", meta?.git_sha ?? entry.git_sha],
      ["git_tag", (meta?.git_tag ?? entry.git_tag) || "—"],
      ["recorded_at", meta?.recorded_at ?? entry.recorded_at],
      ["machine_id", meta?.machine_id ?? entry.machine_id],
      ["tier", meta?.tier ?? entry.tier],
      ["bench_mode", meta?.bench_mode ?? entry.bench_mode],
      [
        "has_performance",
        String(meta?.has_performance ?? entry.has_performance),
      ],
      ["source", entry.source],
    ];
    if (meta?.cpu_model) fields.push(["cpu_model", meta.cpu_model]);
    if (meta?.cpu_cores != null) fields.push(["cpu_cores", String(meta.cpu_cores)]);
    if (meta?.os) fields.push(["os", meta.os]);
    if (meta?.zig_version) fields.push(["zig_version", meta.zig_version]);
    if (meta?.bun_version) fields.push(["bun_version", meta.bun_version]);
    if (meta?.mathzig_version) fields.push(["mathzig_version", meta.mathzig_version]);
    if (meta?.baseline_version_id)
      fields.push(["baseline_version_id", meta.baseline_version_id]);
    if (meta?.baseline_feature_id)
      fields.push(["baseline_feature_id", meta.baseline_feature_id]);
    if (meta?.bench_snapshot_id)
      fields.push(["bench_snapshot_id", meta.bench_snapshot_id]);
    if (meta?.parity_backends_executed?.length)
      fields.push([
        "parity_backends_executed",
        meta.parity_backends_executed.join(", "),
      ]);
    return fields;
  });

  return (
    <div class="rounded-md border border-line bg-panel px-4 py-4">
      <dl class="grid gap-2 text-sm sm:grid-cols-2">
        <For each={rows()}>
          {([key, value]) => (
            <div>
              <dt class="text-fg-muted text-xs">{key}</dt>
              <dd class="font-mono text-fg-secondary text-xs break-all">{value}</dd>
            </div>
          )}
        </For>
      </dl>
    </div>
  );
}

function FeaturesSummaryPanel(props: { features: SlimFeatures | null }) {
  return (
    <Show
      when={props.features}
      fallback={
        <div class="rounded-md border border-line bg-panel px-4 py-4 text-sm text-fg-secondary">
          No features summary for this package.
        </div>
      }
    >
      {(f) => <FeaturesSummaryBody features={f} />}
    </Show>
  );
}

function FeaturesSummaryBody(props: { features: Accessor<SlimFeatures> }) {
  const totals = createMemo(() =>
    aggregateStatusHistogram(props.features().summary)
  );
  const backends = createMemo(() =>
    Object.keys(props.features().summary).sort()
  );

  return (
    <div class="rounded-md border border-line bg-panel px-4 py-4 flex flex-col gap-3">
      <div class="flex flex-wrap gap-3 text-xs text-fg-muted">
        <span>
          cells <span class="font-mono text-fg">{props.features().cell_count}</span>
        </span>
        <span>
          backends_executed{" "}
          <span class="font-mono text-fg-secondary">
            {props.features().backends_executed.join(", ") || "—"}
          </span>
        </span>
        <Show when={props.features().catalog_hash}>
          <span>
            catalog{" "}
            <span class="font-mono text-fg-secondary">
              {props.features().catalog_hash.slice(0, 12)}
            </span>
          </span>
        </Show>
      </div>

      <div>
        <div class="mb-1 text-[11px] uppercase tracking-wide text-fg-muted">
          Aggregate
        </div>
        <HistogramBar hist={totals()} />
      </div>

      <Show when={backends().length > 0}>
        <div class="overflow-x-auto">
          <table class="w-full min-w-[28rem] border-collapse text-left text-xs">
            <thead>
              <tr class="border-b border-line text-fg-muted">
                <th class="py-1.5 pr-2 font-medium">backend</th>
                <For each={HISTOGRAM_KEYS}>
                  {(k) => (
                    <th class="py-1.5 px-1 font-medium text-right">{k}</th>
                  )}
                </For>
              </tr>
            </thead>
            <tbody>
              <For each={backends()}>
                {(be) => (
                  <tr class="border-b border-line/50 last:border-0">
                    <td class="py-1.5 pr-2 font-mono text-fg">{be}</td>
                    <For each={HISTOGRAM_KEYS}>
                      {(k) => (
                        <td class="py-1.5 px-1 font-mono text-right text-fg-secondary">
                          {props.features().summary[be]?.[k] ?? 0}
                        </td>
                      )}
                    </For>
                  </tr>
                )}
              </For>
            </tbody>
          </table>
        </div>
      </Show>
    </div>
  );
}

function HistogramBar(props: {
  hist: ReturnType<typeof aggregateStatusHistogram>;
}) {
  const total = () =>
    HISTOGRAM_KEYS.reduce((s, k) => s + (props.hist[k] ?? 0), 0);

  const segments: Array<{
    key: keyof ReturnType<typeof aggregateStatusHistogram>;
    class: string;
  }> = [
    { key: "done", class: "bg-ok" },
    { key: "partial", class: "bg-warn" },
    { key: "broken", class: "bg-err" },
    { key: "skipped", class: "bg-fg-muted" },
    { key: "missing", class: "bg-line" },
    { key: "n/a", class: "bg-raised" },
    { key: "unknown", class: "bg-active" },
  ];

  return (
    <div class="flex flex-col gap-1.5">
      <div class="flex h-2 w-full overflow-hidden rounded-full bg-inset">
        <Show when={total() > 0}>
          <For each={segments}>
            {(seg) => {
              const n = () => props.hist[seg.key] ?? 0;
              const pct = () => (n() / total()) * 100;
              return (
                <Show when={n() > 0}>
                  <div
                    class={`${seg.class} h-full`}
                    style={{ width: `${pct()}%` }}
                    title={`${seg.key}: ${n()}`}
                  />
                </Show>
              );
            }}
          </For>
        </Show>
      </div>
      <div class="flex flex-wrap gap-x-3 gap-y-1 text-[11px] font-mono text-fg-muted">
        <For each={HISTOGRAM_KEYS}>
          {(k) => (
            <Show when={(props.hist[k] ?? 0) > 0}>
              <span>
                {k}=
                <span class="text-fg-secondary">{props.hist[k]}</span>
              </span>
            </Show>
          )}
        </For>
        <Show when={total() === 0}>
          <span>empty</span>
        </Show>
      </div>
    </div>
  );
}
