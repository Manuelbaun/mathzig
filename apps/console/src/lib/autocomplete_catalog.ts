import type { VarEntry } from "../engine/value_tags";

export type SuggestKind = "variable" | "constant" | "command" | "snippet" | "function";

export type SuggestItem = {
  /** Stable unique id for list keys */
  id: string;
  /** Primary label (usually the insert text or short name) */
  label: string;
  /** Text inserted into the editor */
  insert: string;
  /** Human-readable description */
  detail: string;
  kind: SuggestKind;
};

/** Built-in constants always available in the engine. */
export const CONSTANT_ITEMS: SuggestItem[] = [
  { id: "const:pi", label: "pi", insert: "pi", detail: "3.14159…", kind: "constant" },
  { id: "const:e", label: "e", insert: "e", detail: "2.71828…", kind: "constant" },
];

/** REPL commands (submit as whole expression when used alone). */
export const COMMAND_ITEMS: SuggestItem[] = [
  { id: "cmd:help", label: "help", insert: "help", detail: "Show commands", kind: "command" },
  { id: "cmd:clear", label: "clear", insert: "clear", detail: "Clear output", kind: "command" },
  { id: "cmd:reset", label: "reset", insert: "reset", detail: "Reset VM", kind: "command" },
  { id: "cmd:sample", label: "sample", insert: "sample", detail: "Load demo series", kind: "command" },
  { id: "cmd:load", label: "load", insert: "load", detail: "Import CSV", kind: "command" },
  { id: "cmd:rocket", label: "rocket", insert: "rocket", detail: "Trajectory simulation", kind: "command" },
  { id: "cmd:lorenz", label: "lorenz", insert: "lorenz", detail: "Lorenz attractor", kind: "command" },
  { id: "cmd:plot", label: "plot", insert: "plot", detail: "Rocket trajectory charts", kind: "command" },
  { id: "cmd:version", label: "version", insert: "version", detail: "Engine version", kind: "command" },
];

/** Common math helpers users type often. */
export const FUNCTION_ITEMS: SuggestItem[] = [
  { id: "fn:sin", label: "sin", insert: "sin(", detail: "Sine", kind: "function" },
  { id: "fn:cos", label: "cos", insert: "cos(", detail: "Cosine", kind: "function" },
  { id: "fn:tan", label: "tan", insert: "tan(", detail: "Tangent", kind: "function" },
  { id: "fn:det", label: "det", insert: "det(", detail: "Determinant", kind: "function" },
  { id: "fn:sma", label: "sma", insert: "sma(", detail: "Simple moving average", kind: "function" },
  { id: "fn:plot(", label: "plot(", insert: "plot(", detail: "Plot series / matrix / arrays", kind: "function" },
];

/** Getting started + data + plot cheatsheet snippets (shared with sidebar). */
export const SNIPPET_GROUPS = {
  start: [
    { expr: "help", label: "Help" },
    { expr: "sin(pi/4)", label: "Trig" },
    { expr: "m = [1,2;3,4]", label: "Matrix" },
  ],
  data: [
    { expr: "sample", label: "Load Demo Data" },
    { expr: "det(m)", label: "Determinant" },
    { expr: "sma(demo_data, 5)", label: "Series SMA" },
    { expr: "load", label: "Import CSV" },
  ],
  sims: [
    { expr: "rocket", label: "Trajectory Simulation" },
    { expr: "lorenz", label: "Lorenz Attractor" },
  ],
  plots: [
    { expr: "plot", label: "Rocket Trajectory" },
    { expr: "plot(demo_data)", label: "Series" },
    { expr: "plot(m, 0, 1)", label: "Matrix Cols" },
    { expr: "plot(m, {x:0, y:[1,2]})", label: "Multi Cols" },
    { expr: "plot([1,2,3], [2,3,5])", label: "Arrays" },
  ],
} as const;

export const SNIPPET_ITEMS: SuggestItem[] = [
  ...SNIPPET_GROUPS.start.map((s) => ({
    id: `snip:start:${s.expr}`,
    label: s.expr,
    insert: s.expr,
    detail: s.label,
    kind: "snippet" as const,
  })),
  ...SNIPPET_GROUPS.data.map((s) => ({
    id: `snip:data:${s.expr}`,
    label: s.expr,
    insert: s.expr,
    detail: s.label,
    kind: "snippet" as const,
  })),
  ...SNIPPET_GROUPS.sims.map((s) => ({
    id: `snip:sim:${s.expr}`,
    label: s.expr,
    insert: s.expr,
    detail: s.label,
    kind: "snippet" as const,
  })),
  ...SNIPPET_GROUPS.plots.map((s) => ({
    id: `snip:plot:${s.expr}`,
    label: s.expr,
    insert: s.expr,
    detail: s.label,
    kind: "snippet" as const,
  })),
];

const KIND_ORDER: Record<SuggestKind, number> = {
  variable: 0,
  constant: 1,
  function: 2,
  command: 3,
  snippet: 4,
};

function scoreItem(item: SuggestItem, q: string): number | null {
  if (!q) return 50 + KIND_ORDER[item.kind];
  const label = item.label.toLowerCase();
  const insert = item.insert.toLowerCase();
  const detail = item.detail.toLowerCase();
  if (label === q || insert === q) return 0 + KIND_ORDER[item.kind] * 0.01;
  if (label.startsWith(q) || insert.startsWith(q)) return 10 + KIND_ORDER[item.kind];
  if (label.includes(q) || insert.includes(q)) return 30 + KIND_ORDER[item.kind];
  if (detail.includes(q)) return 40 + KIND_ORDER[item.kind];
  return null;
}

/** Build ranked autocomplete items for the current query and live variables. */
export function buildSuggestItems(
  query: string,
  variables: Record<string, VarEntry>,
  limit = 12,
): SuggestItem[] {
  const q = query.trim().toLowerCase();

  const varItems: SuggestItem[] = Object.keys(variables)
    .sort()
    .map((name) => {
      const v = variables[name]!;
      return {
        id: `var:${name}`,
        label: name,
        insert: name,
        detail: `${v.type} · ${v.value}`,
        kind: "variable" as const,
      };
    });

  // Deduplicate by insert text, preferring variables > constants > functions > commands > snippets
  const pool = [...varItems, ...CONSTANT_ITEMS, ...FUNCTION_ITEMS, ...COMMAND_ITEMS, ...SNIPPET_ITEMS];
  const best = new Map<string, { item: SuggestItem; score: number }>();

  for (const item of pool) {
    const score = scoreItem(item, q);
    if (score === null) continue;
    const key = item.insert;
    const prev = best.get(key);
    if (!prev || score < prev.score || (score === prev.score && KIND_ORDER[item.kind] < KIND_ORDER[prev.item.kind])) {
      best.set(key, { item, score });
    }
  }

  return [...best.values()]
    .sort((a, b) => a.score - b.score || a.item.label.localeCompare(b.item.label))
    .slice(0, limit)
    .map((x) => x.item);
}

export function kindLabel(kind: SuggestKind): string {
  switch (kind) {
    case "variable":
      return "var";
    case "constant":
      return "const";
    case "command":
      return "cmd";
    case "snippet":
      return "demo";
    case "function":
      return "fn";
  }
}
