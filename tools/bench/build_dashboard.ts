#!/usr/bin/env bun
import * as fs from "node:fs";
import * as path from "node:path";
import { loadManifest } from "./manifest";
import { buildIndex } from "./build_index";
import type { Snapshot, SnapshotIndex } from "./types";
import { DASHBOARD_HTML, INDEX_FILE, SNAPSHOTS_DIR, ensurePerfDirs } from "./paths";

type DashboardData = {
  generatedAt: string;
  machineId: string;
  benchmarks: Array<{ id: string; description: string; suite: string }>;
  snapshots: Array<{
    id: string;
    kind: string;
    git_tag: string | null;
    feature_id: string;
    recorded_at: string;
    label: string;
  }>;
  series: Record<string, Record<string, Array<{ snapshotId: string; score: number; backend: string }>>>;
  latest: Record<string, Record<string, number>>;
  previous: Record<string, Record<string, number>>;
};

function loadSnapshots(index: SnapshotIndex): Snapshot[] {
  const out: Snapshot[] = [];
  for (const entry of index.snapshots) {
    const full = path.join(SNAPSHOTS_DIR, path.basename(entry.file));
    if (!fs.existsSync(full)) continue;
    out.push(JSON.parse(fs.readFileSync(full, "utf8")) as Snapshot);
  }
  return out;
}

function buildDashboardData(index: SnapshotIndex, snapshots: Snapshot[]): DashboardData {
  const manifest = loadManifest();
  const benchmarks = manifest.benchmarks.map((b) => ({
    id: b.id,
    description: b.description,
    suite: b.suite,
  }));

  const snapshotMeta = index.snapshots.map((s) => ({
    id: s.id,
    kind: s.kind,
    git_tag: s.git_tag,
    feature_id: s.feature_id,
    recorded_at: s.recorded_at,
    label: s.git_tag ?? s.feature_id,
  }));

  const series: DashboardData["series"] = {};
  for (const bench of manifest.benchmarks) {
    series[bench.id] = {};
  }

  for (const snap of snapshots) {
    for (const result of snap.results) {
      const benchSeries = series[result.bench_id] ?? (series[result.bench_id] = {});
      const key = `${result.backend}@t${result.threads}`;
      const arr = benchSeries[key] ?? (benchSeries[key] = []);
      arr.push({
        snapshotId: snap.snapshot.id,
        score: result.ops_p50,
        backend: result.backend,
      });
    }
  }

  const latestSnap = snapshots[snapshots.length - 1];
  const prevSnap = snapshots.length > 1 ? snapshots[snapshots.length - 2] : null;

  const latest: DashboardData["latest"] = {};
  const previous: DashboardData["previous"] = {};

  if (latestSnap) {
    for (const r of latestSnap.results) {
      const key = `${r.backend}@t${r.threads}`;
      latest[r.bench_id] ??= {};
      latest[r.bench_id][key] = r.ops_p50;
    }
  }
  if (prevSnap) {
    for (const r of prevSnap.results) {
      const key = `${r.backend}@t${r.threads}`;
      previous[r.bench_id] ??= {};
      previous[r.bench_id][key] = r.ops_p50;
    }
  }

  return {
    generatedAt: new Date().toISOString(),
    machineId: index.machine_id,
    benchmarks,
    snapshots: snapshotMeta,
    series,
    latest,
    previous,
  };
}

function renderHtml(data: DashboardData): string {
  const payload = JSON.stringify(data).replaceAll("<", "\\u003c");
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>MathZig Benchmark Dashboard</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
  <style>
    :root {
      color-scheme: light dark;
      --bg: #0f1115;
      --panel: #171a21;
      --text: #e8ecf1;
      --muted: #9aa4b2;
      --accent: #5b9cff;
      --good: #3ecf8e;
      --bad: #ff6b6b;
      --border: #2a3140;
    }
    @media (prefers-color-scheme: light) {
      :root {
        --bg: #f6f8fb;
        --panel: #ffffff;
        --text: #1a1f29;
        --muted: #5c6778;
        --accent: #2563eb;
        --good: #059669;
        --bad: #dc2626;
        --border: #d8dee9;
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, sans-serif;
      background: var(--bg);
      color: var(--text);
      line-height: 1.45;
    }
    header {
      padding: 1.25rem 1.5rem;
      border-bottom: 1px solid var(--border);
      background: var(--panel);
      position: sticky;
      top: 0;
      z-index: 2;
    }
    h1 { margin: 0 0 0.25rem; font-size: 1.35rem; }
    .meta { color: var(--muted); font-size: 0.9rem; }
    main { padding: 1.25rem 1.5rem 2rem; max-width: 1400px; margin: 0 auto; }
    .controls {
      display: flex;
      gap: 0.75rem;
      flex-wrap: wrap;
      margin-bottom: 1rem;
    }
    select, input {
      background: var(--panel);
      color: var(--text);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 0.45rem 0.65rem;
      font: inherit;
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(360px, 1fr));
      gap: 1rem;
    }
    .card {
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 1rem;
    }
    .card h3 { margin: 0 0 0.35rem; font-size: 1rem; }
    .card p { margin: 0 0 0.75rem; color: var(--muted); font-size: 0.85rem; }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.88rem;
    }
    th, td {
      border-bottom: 1px solid var(--border);
      padding: 0.45rem 0.35rem;
      text-align: right;
    }
    th:first-child, td:first-child { text-align: left; }
    .delta-good { color: var(--good); }
    .delta-bad { color: var(--bad); }
    .suite-tag {
      display: inline-block;
      font-size: 0.72rem;
      color: var(--muted);
      border: 1px solid var(--border);
      border-radius: 999px;
      padding: 0.1rem 0.45rem;
      margin-left: 0.35rem;
    }
    canvas { width: 100% !important; height: 220px !important; }
    .empty { color: var(--muted); padding: 2rem; text-align: center; }
  </style>
</head>
<body>
  <header>
    <h1>MathZig Benchmark Dashboard</h1>
    <div class="meta" id="meta"></div>
  </header>
  <main>
    <section class="card" style="margin-bottom: 1rem;">
      <h3>Latest Snapshot Overview</h3>
      <p>Compare backends for the most recent snapshot. Δ% is vs previous snapshot on the same machine.</p>
      <div class="controls">
        <label>Suite
          <select id="suiteFilter">
            <option value="all">all</option>
            <option value="hot">hot</option>
            <option value="vm">vm</option>
            <option value="kernels">kernels</option>
            <option value="integration">integration</option>
            <option value="reference">reference</option>
          </select>
        </label>
        <label>Search <input id="search" placeholder="bench id..." /></label>
      </div>
      <div style="overflow-x:auto;">
        <table id="overviewTable">
          <thead>
            <tr>
              <th>Benchmark</th>
              <th>Backend</th>
              <th>Score (ops/s)</th>
              <th>Δ% vs prev</th>
              <th>ref_zig ratio</th>
            </tr>
          </thead>
          <tbody></tbody>
        </table>
      </div>
    </section>

    <section>
      <h2 style="font-size:1.05rem; margin:0 0 0.75rem;">Trends (X = snapshot, Y = ops/s)</h2>
      <div id="charts" class="grid"></div>
    </section>
  </main>

  <script>
    const DATA = ${payload};

    function fmt(n) {
      if (!Number.isFinite(n)) return "—";
      if (n >= 1e9) return (n / 1e9).toFixed(2) + "B";
      if (n >= 1e6) return (n / 1e6).toFixed(2) + "M";
      if (n >= 1e3) return (n / 1e3).toFixed(2) + "K";
      return n.toFixed(2);
    }

    function pctDelta(cur, prev) {
      if (!Number.isFinite(cur) || !Number.isFinite(prev) || prev === 0) return null;
      return ((cur - prev) / prev) * 100;
    }

    function renderMeta() {
      const latest = DATA.snapshots[DATA.snapshots.length - 1];
      document.getElementById("meta").textContent =
        "Generated: " + DATA.generatedAt +
        " · Machine: " + DATA.machineId +
        " · Snapshots: " + DATA.snapshots.length +
        (latest ? " · Latest: " + latest.label : "");
    }

    function renderOverview() {
      const suite = document.getElementById("suiteFilter").value;
      const q = document.getElementById("search").value.trim().toLowerCase();
      const tbody = document.querySelector("#overviewTable tbody");
      tbody.innerHTML = "";

      for (const bench of DATA.benchmarks) {
        if (suite !== "all" && bench.suite !== suite) continue;
        if (q && !bench.id.includes(q) && !bench.description.toLowerCase().includes(q)) continue;

        const latestScores = DATA.latest[bench.id] || {};
        const prevScores = DATA.previous[bench.id] || {};
        const refKey = Object.keys(latestScores).find((k) => k.startsWith("ref_zig@")) || null;
        const refScore = refKey ? latestScores[refKey] : null;

        const keys = Object.keys(latestScores).sort();
        if (keys.length === 0) {
          const tr = document.createElement("tr");
          tr.innerHTML = '<td>' + bench.id + '<span class="suite-tag">' + bench.suite + '</span></td><td colspan="4" style="text-align:left;color:var(--muted)">no data</td>';
          tbody.appendChild(tr);
          continue;
        }

        for (const key of keys) {
          const score = latestScores[key];
          const prev = prevScores[key];
          const delta = pctDelta(score, prev);
          const ratio = refScore && !key.startsWith("ref_zig@") && refScore > 0 ? score / refScore : null;

          const tr = document.createElement("tr");
          const deltaCls = delta == null ? "" : (delta >= 0 ? "delta-good" : "delta-bad");
          const deltaTxt = delta == null ? "—" : (delta >= 0 ? "+" : "") + delta.toFixed(2) + "%";
          const ratioTxt = ratio == null ? "—" : ratio.toFixed(3) + "×";

          tr.innerHTML =
            '<td>' + bench.id + (keys[0] === key ? '<span class="suite-tag">' + bench.suite + '</span>' : '') + '</td>' +
            '<td>' + key + '</td>' +
            '<td>' + fmt(score) + '</td>' +
            '<td class="' + deltaCls + '">' + deltaTxt + '</td>' +
            '<td>' + ratioTxt + '</td>';
          tbody.appendChild(tr);
        }
      }
    }

    const charts = [];
    function renderCharts() {
      const container = document.getElementById("charts");
      container.innerHTML = "";
      charts.forEach((c) => c.destroy());
      charts.length = 0;

      const labels = DATA.snapshots.map((s) => s.label);
      const suite = document.getElementById("suiteFilter").value;
      const q = document.getElementById("search").value.trim().toLowerCase();

      for (const bench of DATA.benchmarks) {
        if (suite !== "all" && bench.suite !== suite) continue;
        if (q && !bench.id.includes(q) && !bench.description.toLowerCase().includes(q)) continue;

        const series = DATA.series[bench.id] || {};
        const backendKeys = Object.keys(series);
        if (backendKeys.length === 0) continue;

        const card = document.createElement("div");
        card.className = "card";
        card.innerHTML = '<h3>' + bench.id + '</h3><p>' + bench.description + '</p><canvas></canvas>';
        container.appendChild(card);

        const datasets = backendKeys.map((key, idx) => {
          const points = series[key];
          const byId = Object.fromEntries(points.map((p) => [p.snapshotId, p.score]));
          return {
            label: key,
            data: DATA.snapshots.map((s) => byId[s.id] ?? null),
            spanGaps: true,
            borderWidth: 2,
            tension: 0.2,
          };
        });

        const ctx = card.querySelector("canvas").getContext("2d");
        charts.push(new Chart(ctx, {
          type: "line",
          data: { labels, datasets },
          options: {
            responsive: true,
            maintainAspectRatio: false,
            plugins: { legend: { position: "bottom" } },
            scales: {
              y: {
                ticks: {
                  callback: (v) => fmt(v),
                },
              },
            },
          },
        }));
      }

      if (!container.children.length) {
        container.innerHTML = '<div class="empty">No chart data for current filters.</div>';
      }
    }

    document.getElementById("suiteFilter").addEventListener("change", () => {
      renderOverview();
      renderCharts();
    });
    document.getElementById("search").addEventListener("input", () => {
      renderOverview();
      renderCharts();
    });

    renderMeta();
    renderOverview();
    renderCharts();
  </script>
</body>
</html>`;
}

function main() {
  ensurePerfDirs();
  const index = fs.existsSync(INDEX_FILE)
    ? (JSON.parse(fs.readFileSync(INDEX_FILE, "utf8")) as SnapshotIndex)
    : buildIndex();

  const snapshots = loadSnapshots(index);
  if (snapshots.length === 0) {
    console.error("No snapshots found. Run: bun run bench:import");
    process.exit(2);
  }

  const data = buildDashboardData(index, snapshots);
  fs.writeFileSync(DASHBOARD_HTML, renderHtml(data), "utf8");
  console.log(`Wrote ${DASHBOARD_HTML}`);
}

main();