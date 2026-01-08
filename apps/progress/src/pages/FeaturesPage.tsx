import {
  createEffect,
  createMemo,
  createResource,
  createSignal,
  For,
  Show,
} from "solid-js";
import { A } from "@solidjs/router";
import {
  FeatureMatrixTable,
  type SelectedCell,
} from "../components/FeatureMatrixTable";
import { StatusPill } from "../components/StatusPill";
import {
  featureBackends,
  featureCategories,
  FEATURE_STATUSES,
  formatPct,
  NO_DATA_HINT,
  parityBackendLabel,
  tryLoadFeaturesLatest,
  unknownStatusBadge,
  type FeatureCell,
  type FeaturesDocument,
  type FeatureStatusName,
} from "../lib/data";

const STATUS_LEGEND: Array<{ status: FeatureStatusName; note: string }> = [
  { status: "done", note: "all matched cases pass" },
  { status: "partial", note: "mixed pass/fail or skips" },
  { status: "broken", note: "failures dominate" },
  { status: "skipped", note: "all cases skipped" },
  { status: "missing", note: "catalog sticky missing" },
  { status: "n/a", note: "not applicable" },
  { status: "unknown", note: "no evidence / not executed" },
];

export function FeaturesPage() {
  const [featuresResult] = createResource(tryLoadFeaturesLatest);

  return (
    <div class="mx-auto flex w-full max-w-6xl flex-col gap-4">
      <header class="flex flex-col gap-1">
        <h1 class="text-lg font-semibold tracking-tight">Features</h1>
        <p class="text-xs text-fg-muted">
          Feature × backend matrix from{" "}
          <span class="font-mono">features_latest.json</span>. Packages embed
          summary only — full cells always from latest snapshot.
        </p>
      </header>

      <Show when={featuresResult.loading}>
        <p class="text-sm text-fg-muted">Loading feature matrix…</p>
      </Show>

      <Show when={featuresResult.error}>
        <p class="text-sm text-err">Failed to load features_latest.json.</p>
      </Show>

      <Show
        when={(() => {
          const r = featuresResult();
          return r && !r.ok ? r.message : null;
        })()}
      >
        {(msg) => (
          <div class="rounded-md border border-line bg-panel px-4 py-6 text-sm text-fg-secondary">
            {msg() || NO_DATA_HINT}
          </div>
        )}
      </Show>

      <Show
        when={(() => {
          const r = featuresResult();
          return r?.ok ? r.data : null;
        })()}
      >
        {(doc) => <FeaturesBody doc={doc()} />}
      </Show>
    </div>
  );
}

function FeaturesBody(props: { doc: FeaturesDocument }) {
  const backends = createMemo(() => featureBackends(props.doc));
  const allCells = createMemo(() => props.doc.cells ?? []);
  const categories = createMemo(() => featureCategories(allCells()));
  const badge = createMemo(() => unknownStatusBadge(props.doc));

  const [category, setCategory] = createSignal<string>("");
  const [statusFilter, setStatusFilter] = createSignal<string>("");
  const [search, setSearch] = createSignal("");
  const [selected, setSelected] = createSignal<SelectedCell | null>(null);

  const filtered = createMemo((): FeatureCell[] => {
    const cat = category();
    const st = statusFilter();
    const q = search().trim().toLowerCase();
    const beList = backends();

    return allCells().filter((cell) => {
      if (cat && cell.category !== cat) return false;
      if (q) {
        const hay = `${cell.label} ${cell.feature_id} ${cell.category}`.toLowerCase();
        if (!hay.includes(q)) return false;
      }
      if (st) {
        const any = beList.some(
          (be) => (cell.by_backend?.[be]?.status ?? "unknown") === st
        );
        if (!any) return false;
      }
      return true;
    });
  });

  // Clear selection if filtered out
  createEffect(() => {
    const sel = selected();
    if (!sel) return;
    if (!filtered().some((c) => c.feature_id === sel.feature.feature_id)) {
      setSelected(null);
    }
  });

  const versionLabel = createMemo(() => {
    const id = props.doc.version_id;
    if (!id) return "latest package";
    return id;
  });

  return (
    <div class="flex flex-col gap-4">
      {/* Version + unknown badges */}
      <div class="flex flex-wrap items-start justify-between gap-3 rounded-md border border-line bg-panel px-4 py-3">
        <div class="flex min-w-0 flex-col gap-1.5">
          <label class="flex flex-col gap-1 text-xs text-fg-secondary">
            <span class="text-fg-muted">version</span>
            <select
              class="min-w-[16rem] max-w-full rounded-md border border-line bg-inset px-2 py-1.5 font-mono text-xs text-fg"
              value="latest"
              disabled
              title="packages.json embeds feature summary only; full matrix is features_latest"
            >
              <option value="latest">
                latest package — {versionLabel()}
              </option>
            </select>
          </label>
          <p class="text-[11px] text-fg-muted">
            Full cell matrix from{" "}
            <span class="font-mono">features_latest.json</span> only. Historical
            packages store summary counts, not per-cell evidence.
          </p>
          <Show when={props.doc.version_id}>
            <A
              href={`/versions/${encodeURIComponent(props.doc.version_id)}`}
              class="w-fit font-mono text-[11px] text-keyword hover:underline break-all"
            >
              open version detail →
            </A>
          </Show>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <span class="rounded border border-line bg-inset px-2 py-1 font-mono text-[11px] text-fg-secondary">
            cells={allCells().length}
          </span>
          <span
            class="rounded border border-line bg-inset px-2 py-1 font-mono text-[11px] text-fg-secondary"
            title="backends_executed"
          >
            executed=
            {(props.doc.backends_executed ?? []).join(",") || "—"}
          </span>
          <UnknownBadgePill badge={badge()} />
        </div>
      </div>

      {/* Filters */}
      <div class="flex flex-wrap items-end gap-3">
        <label class="flex flex-col gap-1 text-xs text-fg-secondary">
          <span class="text-fg-muted">category</span>
          <select
            class="min-w-[10rem] rounded-md border border-line bg-inset px-2 py-1.5 font-mono text-xs text-fg"
            value={category()}
            onChange={(e) => setCategory(e.currentTarget.value)}
          >
            <option value="">all</option>
            <For each={categories()}>
              {(c) => <option value={c}>{c}</option>}
            </For>
          </select>
        </label>

        <label class="flex flex-col gap-1 text-xs text-fg-secondary">
          <span class="text-fg-muted">status (any cell)</span>
          <select
            class="min-w-[10rem] rounded-md border border-line bg-inset px-2 py-1.5 font-mono text-xs text-fg"
            value={statusFilter()}
            onChange={(e) => setStatusFilter(e.currentTarget.value)}
          >
            <option value="">all</option>
            <For each={[...FEATURE_STATUSES]}>
              {(s) => <option value={s}>{s}</option>}
            </For>
          </select>
        </label>

        <label class="flex min-w-[12rem] flex-1 flex-col gap-1 text-xs text-fg-secondary">
          <span class="text-fg-muted">search label / id</span>
          <input
            type="search"
            class="rounded-md border border-line bg-inset px-2 py-1.5 font-mono text-xs text-fg placeholder:text-fg-muted"
            placeholder="e.g. scalar, arith…"
            value={search()}
            onInput={(e) => setSearch(e.currentTarget.value)}
          />
        </label>

        <div class="pb-1 text-[11px] font-mono text-fg-muted">
          showing {filtered().length}/{allCells().length}
        </div>
      </div>

      {/* Legend */}
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1.5 rounded-md border border-line bg-panel px-3 py-2">
        <span class="text-[11px] uppercase tracking-wide text-fg-muted">
          legend
        </span>
        <For each={STATUS_LEGEND}>
          {(item) => (
            <span class="inline-flex items-center gap-1.5 text-[11px] text-fg-muted">
              <StatusPill status={item.status} />
              <span>{item.note}</span>
            </span>
          )}
        </For>
      </div>

      {/* Matrix + evidence drawer */}
      <div class="flex flex-col gap-3 lg:flex-row lg:items-start">
        <div class="min-w-0 flex-1">
          <FeatureMatrixTable
            cells={filtered()}
            backends={backends()}
            backendsExecuted={props.doc.backends_executed ?? []}
            selected={selected()}
            onSelect={setSelected}
          />
        </div>

        <Show when={selected()}>
          {(sel) => (
            <aside class="w-full shrink-0 rounded-md border border-line bg-panel px-4 py-3 lg:w-72">
              <EvidenceDrawer
                selected={sel()}
                executed={(props.doc.backends_executed ?? []).includes(
                  sel().backend
                )}
                onClose={() => setSelected(null)}
              />
            </aside>
          )}
        </Show>
      </div>
    </div>
  );
}

function UnknownBadgePill(props: {
  badge: ReturnType<typeof unknownStatusBadge>;
}) {
  const b = () => props.badge;
  return (
    <div class="flex flex-wrap items-center gap-1.5">
      <span
        class="rounded border border-keyword/40 bg-keyword/10 px-2 py-1 font-mono text-[11px] text-fg"
        title={`unknown cells among executed backends: ${b().executed_unknown}/${b().executed_total}`}
      >
        unknown@executed {formatPct(b().executed_pct)} (
        {b().executed_unknown}/{b().executed_total})
      </span>
      <span
        class="rounded border border-line bg-raised px-2 py-1 font-mono text-[11px] text-fg-secondary"
        title={`unknown cells among backends not executed: ${b().not_executed_unknown}/${b().not_executed_total}`}
      >
        unknown@not-run {formatPct(b().not_executed_pct)} (
        {b().not_executed_unknown}/{b().not_executed_total})
      </span>
      <span
        class="rounded border border-line bg-inset px-2 py-1 font-mono text-[11px] text-fg-muted"
        title="overall unknown rate"
      >
        overall {formatPct(b().overall_pct)}
      </span>
    </div>
  );
}

function EvidenceDrawer(props: {
  selected: SelectedCell;
  executed: boolean;
  onClose: () => void;
}) {
  const cell = () => props.selected.cell;
  const feature = () => props.selected.feature;
  const notRun =
    () =>
      !props.executed ||
      cell().evidence === "not_executed";

  return (
    <div class="flex flex-col gap-3 text-xs">
      <div class="flex items-start justify-between gap-2">
        <div class="min-w-0">
          <div class="text-[11px] uppercase tracking-wide text-fg-muted">
            evidence
          </div>
          <div class="mt-0.5 font-medium text-fg break-words">
            {feature().label}
          </div>
        </div>
        <button
          type="button"
          class="rounded border border-line bg-inset px-1.5 py-0.5 text-[11px] text-fg-secondary hover:bg-raised"
          onClick={() => props.onClose()}
        >
          close
        </button>
      </div>

      <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1.5">
        <dt class="text-fg-muted">feature_id</dt>
        <dd class="font-mono text-fg-secondary break-all">
          {feature().feature_id}
        </dd>
        <dt class="text-fg-muted">category</dt>
        <dd class="font-mono text-fg-secondary">{feature().category}</dd>
        <dt class="text-fg-muted">backend</dt>
        <dd class="font-mono text-fg-secondary">
          {parityBackendLabel(props.selected.backend)}
          <span class="text-fg-muted"> ({props.selected.backend})</span>
        </dd>
        <dt class="text-fg-muted">status</dt>
        <dd>
          <StatusPill status={cell().status} />
        </dd>
        <dt class="text-fg-muted">evidence</dt>
        <dd class="font-mono text-fg-secondary break-all">
          {cell().evidence || "—"}
        </dd>
      </dl>

      <Show when={notRun()}>
        <p class="rounded border border-keyword/30 bg-keyword/10 px-2 py-1.5 text-[11px] text-fg-secondary">
          Backend not run this version — status is{" "}
          <span class="font-mono">unknown</span>, not a product gap.
        </p>
      </Show>

      <div class="grid grid-cols-3 gap-2">
        <CountCard label="pass" value={cell().pass} tone="text-ok" />
        <CountCard label="fail" value={cell().fail} tone="text-err" />
        <CountCard label="skip" value={cell().skip} tone="text-fg-muted" />
      </div>

      <Show when={(feature().related_bench_ids?.length ?? 0) > 0}>
        <div>
          <div class="mb-1 text-[11px] text-fg-muted">related_bench_ids</div>
          <ul class="flex flex-col gap-0.5 font-mono text-[11px] text-fg-secondary">
            <For each={feature().related_bench_ids}>
              {(id) => <li>{id}</li>}
            </For>
          </ul>
        </div>
      </Show>
    </div>
  );
}

function CountCard(props: {
  label: string;
  value: number | undefined;
  tone: string;
}) {
  return (
    <div class="rounded border border-line bg-inset px-2 py-1.5 text-center">
      <div class="text-[10px] uppercase tracking-wide text-fg-muted">
        {props.label}
      </div>
      <div class={`font-mono text-sm ${props.tone}`}>
        {props.value === undefined ? "—" : props.value}
      </div>
    </div>
  );
}
