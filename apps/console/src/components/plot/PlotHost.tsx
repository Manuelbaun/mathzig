import { createEffect, onCleanup, Show } from "solid-js";
import uPlot from "uplot";
import type { PlotEntry } from "../../state/session";
import { session } from "../../state/session";
import { chartAxes, chartSeriesColors, readThemeTokens, withAlpha } from "../../engine/theme";
import { getPlotly, plainClone, purgePlotly } from "../../lib/plotly";

export function PlotHost(props: { entry: PlotEntry }) {
  let host!: HTMLDivElement;
  let plotlyEl!: HTMLDivElement;
  let chart: uPlot | null = null;
  let plotlyReady = false;

  createEffect(() => {
    const entry = props.entry;
    if (entry.collapsed) {
      if (chart) {
        chart.destroy();
        chart = null;
      }
      return;
    }

    if (entry.mode === "uplot" && entry.x && entry.ys) {
      if (chart) {
        chart.destroy();
        chart = null;
      }
      if (!host) return;

      const theme = readThemeTokens();
      const colors = chartSeriesColors(theme);
      const series = [
        {},
        ...entry.labels!.map((l, i) => ({
          stroke: colors[i % colors.length],
          label: l,
          width: 2,
        })),
      ];
      const width = Math.max(280, host.clientWidth || 480);
      chart = new uPlot(
        {
          title: entry.title,
          width,
          height: 300,
          scales: { x: { time: false } },
          series: series as any,
          axes: chartAxes(theme) as any,
        },
        [entry.x, ...entry.ys],
        host,
      );
      return;
    }

    if (entry.mode === "uplot-grid" && entry.trajectory) {
      if (!host) return;
      host.innerHTML = "";
      const grid = document.createElement("div");
      grid.className = "grid grid-cols-1 gap-3 lg:grid-cols-2";
      host.appendChild(grid);
      const theme = readThemeTokens();
      const axes = chartAxes(theme);
      const t = entry.trajectory;
      const cells: [string, number[], string, string][] = [
        ["Altitude vs Time", t.altitude, "Altitude (km)", theme.type],
        ["Velocity vs Time", t.velocity, "Velocity (m/s)", theme.keyword],
        ["Gamma vs Time", t.gamma, "Gamma (deg)", theme.function],
      ];
      const plots: uPlot[] = [];
      for (const [title, y, label, color] of cells) {
        const cell = document.createElement("div");
        cell.className = "min-w-0 rounded-md border border-line bg-inset p-2";
        grid.appendChild(cell);
        const w = Math.max(240, cell.clientWidth || 300);
        plots.push(
          new uPlot(
            {
              title,
              width: w,
              height: 240,
              scales: { x: { time: false } },
              axes: axes as any,
              series: [{}, { stroke: color, fill: withAlpha(color, 0.1), label }],
            },
            [t.time, y],
            cell,
          ),
        );
      }
      const combined = document.createElement("div");
      combined.className = "min-w-0 rounded-md border border-line bg-inset p-2 lg:col-span-2";
      grid.appendChild(combined);
      plots.push(
        new uPlot(
          {
            title: "Combined Trajectory",
            width: Math.max(280, combined.clientWidth || 480),
            height: 260,
            scales: { x: { time: false } },
            axes: [
              axes[0],
              { stroke: theme.type, scale: "y", grid: { stroke: theme.borderSubtle } },
              { stroke: theme.keyword, scale: "y1", side: 1, grid: { show: false } },
            ] as any,
            series: [
              {},
              { stroke: theme.type, scale: "y", label: "Altitude" },
              { stroke: theme.keyword, scale: "y1", label: "Velocity" },
            ] as any,
          },
          [t.time, t.altitude, t.velocity],
          combined,
        ),
      );
      onCleanup(() => plots.forEach((p) => p.destroy()));
      return;
    }

    if (entry.mode === "plotly3d" && entry.plotly) {
      // Read store fields (for dependency tracking), then clone off the proxy tree.
      const rawData = entry.plotly.data;
      const rawLayout = entry.plotly.layout;
      const el = plotlyEl;
      if (!el) return;

      const data = plainClone(rawData);
      const layout = plainClone(rawLayout);
      // Explicit size — Plotly 3d can choke on zero-sized containers mid-layout
      layout.height = layout.height ?? 400;
      layout.width = layout.width ?? Math.max(320, el.clientWidth || 480);
      layout.autosize = false;

      let cancelled = false;
      void getPlotly()
        .then((Plotly) => {
          if (cancelled || !el.isConnected) return;
          const config = { responsive: true, displayModeBar: false };
          if (!plotlyReady) {
            return Plotly.newPlot(el, data, layout, config).then(() => {
              plotlyReady = true;
            });
          }
          return Plotly.react(el, data, layout, config);
        })
        .catch((err) => {
          console.error("Plotly render failed:", err);
          if (el.isConnected) {
            el.textContent = `Plot failed: ${err?.message || err}`;
          }
          plotlyReady = false;
        });

      onCleanup(() => {
        cancelled = true;
      });
    }
  });

  onCleanup(() => {
    if (chart) chart.destroy();
    if (plotlyReady) purgePlotly(plotlyEl);
    plotlyReady = false;
  });

  return (
    <div class="border-b border-line/50 px-3 py-3 sm:px-4">
      <div class="mb-2 flex items-center justify-between gap-2">
        <h3 class="font-mono text-xs font-medium text-fg-secondary">{props.entry.title}</h3>
        <div class="flex items-center gap-1">
          <button
            type="button"
            class="ghost-btn"
            aria-expanded={!props.entry.collapsed}
            onClick={() => session.togglePlotCollapsed(props.entry.id)}
          >
            {props.entry.collapsed ? "Expand" : "Collapse"}
          </button>
          <button
            type="button"
            class="ghost-btn"
            aria-label={`Remove plot ${props.entry.title}`}
            onClick={() => session.removePlot(props.entry.id)}
          >
            Dismiss
          </button>
        </div>
      </div>
      <Show when={!props.entry.collapsed}>
        <Show when={props.entry.mode === "plotly3d"}>
          <div
            ref={plotlyEl}
            class="h-[400px] w-full min-h-[400px] rounded-md border border-line bg-inset"
            data-plot="plotly3d"
          />
        </Show>
        <Show when={props.entry.mode !== "plotly3d"}>
          <div ref={host} class="w-full min-w-0" />
        </Show>
      </Show>
    </div>
  );
}
