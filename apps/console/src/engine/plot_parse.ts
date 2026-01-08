import type { VarEntry } from "./value_tags";

export type PlotArg =
  | { type: "var"; name: string; val: VarEntry }
  | { type: "val"; val: any; name?: string; names?: (string | null)[] }
  | null;

export function splitArgs(str: string): string[] {
  const args: string[] = [];
  let current = "";
  let depth = 0;
  let quote: string | null = null;
  for (let i = 0; i < str.length; i++) {
    const char = str[i]!;
    if (quote) {
      current += char;
      if (char === quote && str[i - 1] !== "\\") quote = null;
    } else {
      if (char === '"' || char === "'") {
        quote = char;
        current += char;
      } else if (["(", "[", "{"].includes(char)) {
        depth++;
        current += char;
      } else if ([")", "]", "}"].includes(char)) {
        depth--;
        current += char;
      } else if (char === "," && depth === 0) {
        if (current.trim()) args.push(current.trim());
        current = "";
      } else {
        current += char;
      }
    }
  }
  if (current.trim()) args.push(current.trim());
  return args;
}

export function resolveArg(arg: string, userVariables: Record<string, VarEntry>): PlotArg {
  arg = arg.trim();
  if (userVariables[arg]) return { type: "var", name: arg, val: userVariables[arg]! };

  if (arg.startsWith("[") && arg.endsWith("]")) {
    try {
      const val = new Function(`return ${arg}`)();
      if (Array.isArray(val)) return { type: "val", val };
    } catch {
      /* fall through */
    }

    const inner = arg.slice(1, -1);
    if (!inner.trim()) return { type: "val", val: [] };

    const parts = splitArgs(inner);
    const resolved = parts.map((p) => resolveArg(p, userVariables));
    if (resolved.every((r) => r)) {
      const data = resolved.map((r) => extractDataFromVar(r, null, null));
      const names = resolved.map((r) => (r && r.type === "var" ? r.name : r?.name) || null);
      if (data.every((d) => d && Array.isArray(d))) {
        return { type: "val", val: data, names };
      }
    }
  }

  try {
    return { type: "val", val: new Function(`return ${arg}`)() };
  } catch {
    return null;
  }
}

export function extractDataFromVar(
  arg: PlotArg,
  readSeriesData: ((ptr: number) => { values: number[] } | null) | null,
  readMatrixData: ((ptr: number) => { rows: number; cols: number; data: number[][] } | null) | null,
): number[] | null {
  if (!arg) return null;
  if (arg.type === "val" && Array.isArray(arg.val)) return arg.val;
  if (arg.type === "var") {
    const v = arg.val;
    if (v.data && Array.isArray(v.data)) return v.data;
    if (v.type === "series" && readSeriesData && v.ptr) {
      const s = readSeriesData(v.ptr);
      return s ? s.values : null;
    }
    if (v.type === "matrix" && readMatrixData && v.ptr) {
      const m = readMatrixData(v.ptr);
      if (!m) return null;
      if (m.cols === 1) return m.data.map((r) => r[0]!);
      if (m.rows === 1) return m.data[0]!;
      return m.data.map((r) => r[0]!);
    }
  }
  return null;
}

export type BuiltPlot = {
  title: string;
  x: number[];
  ys: number[][];
  labels: string[];
};

export function buildPlotSeries(
  argsStr: string,
  userVariables: Record<string, VarEntry>,
  readSeriesData: (ptr: number) => { timestamps: number[]; values: number[] } | null,
  readMatrixData: (ptr: number) => { rows: number; cols: number; data: number[][] } | null,
): BuiltPlot | { error: string } {
  const raw = splitArgs(argsStr);
  const args = raw.map((a) => resolveArg(a, userVariables));
  if (args.some((a) => !a)) return { error: "Invalid arguments" };

  let x: number[] = [];
  let ys: number[][] = [];
  let labels: string[] = [];
  let title = "Plot";

  if (args.length === 1 && args[0]!.type === "var") {
    const a0 = args[0]!;
    const v = a0.val;
    title = a0.name;
    if (v.type === "series" && v.ptr) {
      const sd = readSeriesData(v.ptr);
      if (sd?.timestamps) {
        x = sd.timestamps;
        ys = [sd.values];
        labels = ["Value"];
      }
    } else if (v.type === "matrix" && v.ptr) {
      const md = readMatrixData(v.ptr);
      if (md) {
        if (md.cols === 1) {
          x = md.data.map((_, i) => i);
          ys = [md.data.map((r) => r[0]!)];
          labels = ["Value"];
        } else if (md.rows === 1) {
          x = md.data[0]!.map((_, i) => i);
          ys = [md.data[0]!];
          labels = ["Value"];
        }
      }
    }
  } else if (args.length >= 2 && args[0]!.type === "var" && args[0]!.val.type === "matrix" && args[0]!.val.ptr) {
    const md = readMatrixData(args[0]!.val.ptr!);
    if (md) {
      if (typeof args[1]!.val === "object" && args[1]!.val && args[1]!.val.x !== undefined) {
        const opts = args[1]!.val as { x: number; y: number | number[] };
        const yCols = Array.isArray(opts.y) ? opts.y : [opts.y];
        x = md.data.map((r) => r[opts.x]!);
        ys = yCols.map((yi) => md.data.map((r) => r[yi]!));
        labels = yCols.map((yi) => `Col ${yi}`);
        title = args[0]!.name!;
      } else if (args.length === 3 && typeof args[1]!.val === "number" && typeof args[2]!.val === "number") {
        const xi = args[1]!.val as number;
        const yi = args[2]!.val as number;
        x = md.data.map((r) => r[xi]!);
        ys = [md.data.map((r) => r[yi]!)];
        labels = [`Col ${yi}`];
        title = `${args[0]!.name} (${xi} vs ${yi})`;
      }
    }
  }

  if (args.length >= 2 && !x.length) {
    const xArr = extractDataFromVar(args[0], readSeriesData, readMatrixData);
    if (xArr) {
      x = xArr;
      if (args.length === 2 && args[1]!.type === "val" && Array.isArray(args[1]!.val) && Array.isArray(args[1]!.val[0])) {
        ys = args[1]!.val as number[][];
        labels = args[1]!.names
          ? args[1]!.names.map((n, i) => n || `Series ${i + 1}`)
          : ys.map((_, i) => `Series ${i + 1}`);
      } else {
        for (let i = 1; i < args.length; i++) {
          const yArr = extractDataFromVar(args[i], readSeriesData, readMatrixData);
          if (yArr && yArr.length === x.length) {
            ys.push(yArr);
            const a = args[i]!;
            labels.push(a.type === "var" ? a.name : (a.name ?? `Y${i}`));
          }
        }
      }
      title = args[0]!.type === "var" ? `${args[0]!.name} Series` : "Multi-Series Plot";
    }
  }

  if (x.length && ys.length) return { title, x, ys, labels };
  if (x.length) return { error: "No valid Y data to plot (check dimensions)" };
  return { error: "No data to plot" };
}
