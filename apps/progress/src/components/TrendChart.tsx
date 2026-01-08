import { createMemo, For, Show } from "solid-js";
import {
  backendLabel,
  formatScore,
  trendColor,
  type TrendLine,
} from "../lib/data";

export type TrendChartProps = {
  lines: TrendLine[];
  /** SVG width; height is fixed aspect. */
  width?: number;
  height?: number;
};

/**
 * Minimal multi-series SVG polyline chart.
 * X = package seq (categorical positions), Y = score (ops/s).
 */
export function TrendChart(props: TrendChartProps) {
  const width = () => props.width ?? 720;
  const height = () => props.height ?? 260;
  const pad = { top: 16, right: 16, bottom: 36, left: 64 };

  const layout = createMemo(() => {
    const lines = props.lines;
    const allPoints = lines.flatMap((l) => l.points);
    const seqs = [...new Set(allPoints.map((p) => p.seq))].sort((a, b) => a - b);

    let yMin = Infinity;
    let yMax = -Infinity;
    for (const p of allPoints) {
      if (p.score < yMin) yMin = p.score;
      if (p.score > yMax) yMax = p.score;
    }
    if (!Number.isFinite(yMin) || !Number.isFinite(yMax)) {
      yMin = 0;
      yMax = 1;
    }
    if (yMin === yMax) {
      yMin = yMin * 0.9;
      yMax = yMax * 1.1 || 1;
    }
    // Pad 8% so lines don't hug the border
    const span = yMax - yMin || 1;
    yMin = Math.max(0, yMin - span * 0.08);
    yMax = yMax + span * 0.08;

    const innerW = width() - pad.left - pad.right;
    const innerH = height() - pad.top - pad.bottom;

    const xOf = (seq: number): number => {
      if (seqs.length <= 1) return pad.left + innerW / 2;
      const i = seqs.indexOf(seq);
      return pad.left + (i / (seqs.length - 1)) * innerW;
    };
    const yOf = (score: number): number => {
      const t = (score - yMin) / (yMax - yMin || 1);
      return pad.top + innerH * (1 - t);
    };

    const yTicks = niceTicks(yMin, yMax, 4);

    return { seqs, yMin, yMax, xOf, yOf, yTicks, innerW, innerH };
  });

  return (
    <Show
      when={props.lines.some((l) => l.points.length > 0)}
      fallback={
        <div class="rounded-md border border-line bg-panel px-4 py-6 text-sm text-fg-secondary">
          No points to plot for this filter.
        </div>
      }
    >
      <div class="flex flex-col gap-3">
        <div class="overflow-x-auto rounded-md border border-line bg-panel p-2">
          <svg
            viewBox={`0 0 ${width()} ${height()}`}
            class="w-full max-w-full"
            role="img"
            aria-label="Performance trend chart"
          >
            {/* grid + y labels */}
            <For each={layout().yTicks}>
              {(tick) => {
                const y = () => layout().yOf(tick);
                return (
                  <g>
                    <line
                      x1={pad.left}
                      x2={width() - pad.right}
                      y1={y()}
                      y2={y()}
                      stroke="currentColor"
                      class="text-line"
                      stroke-opacity="0.5"
                      stroke-dasharray="3 3"
                    />
                    <text
                      x={pad.left - 8}
                      y={y()}
                      text-anchor="end"
                      dominant-baseline="middle"
                      class="fill-fg-muted"
                      font-size="10"
                      font-family="var(--font-mono)"
                    >
                      {formatScore(tick)}
                    </text>
                  </g>
                );
              }}
            </For>

            {/* x labels (seq) */}
            <For each={layout().seqs}>
              {(seq) => (
                <text
                  x={layout().xOf(seq)}
                  y={height() - 12}
                  text-anchor="middle"
                  class="fill-fg-muted"
                  font-size="10"
                  font-family="var(--font-mono)"
                >
                  s{seq}
                </text>
              )}
            </For>

            {/* axes */}
            <line
              x1={pad.left}
              y1={pad.top}
              x2={pad.left}
              y2={height() - pad.bottom}
              stroke="currentColor"
              class="text-line"
            />
            <line
              x1={pad.left}
              y1={height() - pad.bottom}
              x2={width() - pad.right}
              y2={height() - pad.bottom}
              stroke="currentColor"
              class="text-line"
            />

            {/* series */}
            <For each={props.lines}>
              {(line, i) => {
                const color = () => trendColor(i());
                const pts = () =>
                  line.points
                    .map((p) => `${layout().xOf(p.seq)},${layout().yOf(p.score)}`)
                    .join(" ");
                return (
                  <g>
                    <Show when={line.points.length >= 2}>
                      <polyline
                        fill="none"
                        stroke={color()}
                        stroke-width="2"
                        stroke-linejoin="round"
                        stroke-linecap="round"
                        points={pts()}
                      />
                    </Show>
                    <For each={line.points}>
                      {(p) => (
                        <circle
                          cx={layout().xOf(p.seq)}
                          cy={layout().yOf(p.score)}
                          r="3.5"
                          fill={color()}
                        >
                          <title>
                            {`${line.key} · seq ${p.seq} · ${formatScore(p.score)} · ${p.version_id}`}
                          </title>
                        </circle>
                      )}
                    </For>
                  </g>
                );
              }}
            </For>
          </svg>
        </div>

        <ul class="flex flex-wrap gap-x-4 gap-y-1 text-[11px]">
          <For each={props.lines}>
            {(line, i) => (
              <li class="flex items-center gap-1.5 font-mono text-fg-secondary">
                <span
                  class="inline-block h-2 w-2 rounded-full"
                  style={{ background: trendColor(i()) }}
                />
                <span title={line.backend}>
                  {backendLabel(line.backend)}@t{line.threads}
                </span>
                <span class="text-fg-muted">({line.points.length})</span>
              </li>
            )}
          </For>
        </ul>
      </div>
    </Show>
  );
}

/** Simple nice tick generation for score axis. */
function niceTicks(min: number, max: number, count: number): number[] {
  if (!Number.isFinite(min) || !Number.isFinite(max) || max <= min) {
    return [min || 0];
  }
  const span = max - min;
  const step = niceStep(span / Math.max(1, count));
  const start = Math.ceil(min / step) * step;
  const ticks: number[] = [];
  for (let v = start; v <= max + step * 0.001; v += step) {
    ticks.push(v);
    if (ticks.length > 12) break;
  }
  if (ticks.length === 0) ticks.push(min, max);
  return ticks;
}

function niceStep(rough: number): number {
  if (!(rough > 0) || !Number.isFinite(rough)) return 1;
  const exp = Math.floor(Math.log10(rough));
  const base = Math.pow(10, exp);
  const frac = rough / base;
  let nice: number;
  if (frac <= 1) nice = 1;
  else if (frac <= 2) nice = 2;
  else if (frac <= 5) nice = 5;
  else nice = 10;
  return nice * base;
}
