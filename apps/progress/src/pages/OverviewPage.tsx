import { createMemo, createResource, Show, type Accessor } from "solid-js";
import { A } from "@solidjs/router";
import { IndexStatus } from "../components/IndexStatus";
import { PerfResultsTable } from "../components/PerfResultsTable";
import { StatusPill } from "../components/StatusPill";
import {
  latestIndexEntry,
  NO_DATA_HINT,
  tryLoadPackages,
  type AppDataIndex,
  type ProgressIndexEntry,
  type SlimPackage,
} from "../lib/data";

export function OverviewPage() {
  return (
    <div class="mx-auto flex w-full max-w-5xl flex-col gap-4">
      <header class="flex flex-col gap-1">
        <h1 class="text-lg font-semibold tracking-tight">Overview</h1>
        <p class="text-xs text-fg-muted">
          Latest package performance (by max seq). Ratios vs Zig when present.
        </p>
      </header>

      <IndexStatus>
        {(data) => <OverviewBody index={data} />}
      </IndexStatus>
    </div>
  );
}

function OverviewBody(props: { index: AppDataIndex }) {
  const [packagesResult] = createResource(tryLoadPackages);
  const latest = createMemo(() => latestIndexEntry(props.index));

  const slim = createMemo((): SlimPackage | null => {
    const entry = latest();
    const res = packagesResult();
    if (!entry || !res?.ok) return null;
    return res.data.packages[entry.version_id] ?? null;
  });

  return (
    <Show
      when={latest()}
      fallback={
        <div class="rounded-md border border-line bg-panel px-4 py-6 text-sm text-fg-secondary">
          {NO_DATA_HINT}
        </div>
      }
    >
      {(entry) => (
        <div class="flex flex-col gap-4">
          <LatestPackageCard entry={entry} />

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

          <Show when={slim()}>
            {(pkg) => (
              <section class="flex flex-col gap-2">
                <div class="flex items-baseline justify-between gap-2">
                  <h2 class="text-sm font-semibold text-fg">Performance</h2>
                  <span class="text-[11px] text-fg-muted">
                    correctness backends ≠ perf backends
                  </span>
                </div>
                <PerfResultsTable performance={pkg().performance} />
              </section>
            )}
          </Show>

          <Show
            when={
              packagesResult() &&
              packagesResult()!.ok &&
              latest() &&
              !slim()
            }
          >
            <div class="rounded-md border border-line bg-panel px-4 py-6 text-sm text-fg-secondary">
              Package payload missing for{" "}
              <span class="font-mono text-fg">{entry().version_id}</span>.
            </div>
          </Show>
        </div>
      )}
    </Show>
  );
}

function LatestPackageCard(props: { entry: Accessor<ProgressIndexEntry> }) {
  const e = () => props.entry();
  return (
    <div class="rounded-md border border-line bg-panel px-4 py-4">
      <div class="mb-3 flex flex-wrap items-center justify-between gap-2">
        <div class="min-w-0">
          <div class="text-[11px] uppercase tracking-wide text-fg-muted">
            Latest package · seq {e().seq}
          </div>
          <A
            href={`/versions/${encodeURIComponent(e().version_id)}`}
            class="font-mono text-sm text-keyword hover:underline break-all"
          >
            {e().version_id}
          </A>
        </div>
        <div class="flex flex-wrap items-center gap-1.5">
          <StatusPill status={e().status} />
          <span class="rounded border border-line bg-inset px-1.5 py-0.5 font-mono text-[11px] text-fg-secondary">
            {e().kind}
          </span>
          <span class="rounded border border-line bg-inset px-1.5 py-0.5 font-mono text-[11px] text-fg-secondary">
            tier={e().tier}
          </span>
          <span class="rounded border border-line bg-inset px-1.5 py-0.5 font-mono text-[11px] text-fg-secondary">
            mode={e().bench_mode}
          </span>
        </div>
      </div>
      <dl class="grid gap-2 text-sm sm:grid-cols-2 lg:grid-cols-3">
        <div class="sm:col-span-2">
          <dt class="text-fg-muted text-xs">Automatic tag</dt>
          <dd class="font-mono text-fg text-xs break-all">{e().label || e().feature_id}</dd>
        </div>
        <div>
          <dt class="text-fg-muted text-xs">Recorded</dt>
          <dd class="font-mono text-fg-secondary text-xs">{e().recorded_at}</dd>
        </div>
        <div>
          <dt class="text-fg-muted text-xs">Git</dt>
          <dd class="font-mono text-fg-secondary text-xs">
            {e().git_sha}
            {e().git_tag ? ` (${e().git_tag})` : ""}
          </dd>
        </div>
        <div>
          <dt class="text-fg-muted text-xs">Machine</dt>
          <dd class="font-mono text-fg-secondary text-xs">{e().machine_id}</dd>
        </div>
        <div>
          <dt class="text-fg-muted text-xs">Has performance</dt>
          <dd class="font-mono text-fg-secondary text-xs">
            {e().has_performance ? "yes" : "no"}
          </dd>
        </div>
      </dl>
    </div>
  );
}
