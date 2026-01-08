import type { GraphValue } from "@mathzig/graph";

export type FormattedGraphValue = {
  kind: string;
  text: string;
  /** Optional matrix cells for table render. */
  matrix?: { rows: number; cols: number; data: number[] };
};

export function formatGraphValue(value: GraphValue): FormattedGraphValue {
  if (typeof value === "number") {
    return { kind: "number", text: formatNumber(value) };
  }
  if (typeof value === "boolean") {
    return { kind: "boolean", text: String(value) };
  }
  if (typeof value === "string") {
    return { kind: "string", text: value };
  }
  if (value && typeof value === "object") {
    if ("rows" in value && "cols" in value && "data" in value) {
      const rows = Number(value.rows);
      const cols = Number(value.cols);
      const raw = value.data as ArrayLike<number>;
      const data: number[] = [];
      for (let i = 0; i < rows * cols; i++) data.push(Number(raw[i]));
      return {
        kind: "matrix",
        text: `matrix ${rows}×${cols}`,
        matrix: { rows, cols, data },
      };
    }
    if ("timestamps" in value || "values" in value || "id" in value) {
      const vals = Array.isArray((value as { values?: number[] }).values)
        ? (value as { values: number[] }).values
        : [];
      const maybeLen = (value as { len?: unknown }).len;
      const len =
        typeof maybeLen === "function"
          ? (maybeLen as () => number)()
          : vals.length ||
            (Array.isArray((value as { timestamps?: number[] }).timestamps)
              ? (value as { timestamps: number[] }).timestamps.length
              : 0);
      const last = vals.length > 0 ? vals[vals.length - 1]! : NaN;
      return {
        kind: "series",
        text: `series len=${len} last=${formatNumber(Number(last))}`,
      };
    }
    if ("re" in value && "im" in value) {
      const re = Number((value as { re: number }).re);
      const im = Number((value as { im: number }).im);
      const text = `${formatNumber(re)}${im >= 0 ? "+" : ""}${formatNumber(im)}i`;
      return { kind: "complex", text };
    }
  }
  return { kind: "unknown", text: String(value) };
}

/** Slider range heuristic for a param default value. */
export function paramSliderRange(defaultValue: number): { min: number; max: number; step: number } {
  const d = Number.isFinite(defaultValue) ? defaultValue : 0;
  if (d >= 0 && d <= 1) {
    return { min: 0, max: 1, step: 0.01 };
  }
  if (d > 1 && d <= 10) {
    return { min: 0, max: d * 2, step: 0.1 };
  }
  const span = Math.max(10, Math.abs(d) * 10);
  const min = d - span;
  const max = d + span;
  const step = span > 100 ? 1 : span > 10 ? 0.1 : 0.01;
  return { min, max, step };
}

function formatNumber(n: number): string {
  if (!Number.isFinite(n)) return String(n);
  if (Math.abs(n) >= 1e6 || (Math.abs(n) > 0 && Math.abs(n) < 1e-4)) return n.toExponential(4);
  const s = n.toFixed(6);
  return s.replace(/\.?0+$/, "") || "0";
}
