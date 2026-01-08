#!/usr/bin/env bun
/**
 * task-17 / C6 — graph tick perf tripwire.
 *
 * Compares a fresh `tools/bench/graph_tick.ts` multi-runtime run against the
 * committed baseline in `docs/reference/graph_tick_baseline.md`.
 *
 * Fail rule (documented): any tracked metric is a REGRESSION if
 *   current_ns > baseline_ns * (1 + threshold)
 * where threshold defaults to 0.30 (30%). Higher ns/tick = slower = fail.
 *
 * Tracked metrics (4 graph shapes from B4 results.md only):
 *   scalar_3.runNs, scalar_3.batchNs
 *   scalar_10.runNs, scalar_10.batchNs
 *   scalar_50.runNs, scalar_50.batchNs
 *   matrix_edge.runNs  (batch N/A)
 *
 * Does NOT modify tools/bench/ — read-only wrapper.
 *
 * Usage:
 *   bun tools/testing/graph_perf_tripwire.ts
 *   bun tools/testing/graph_perf_tripwire.ts --threshold 0.30
 *   bun tools/testing/graph_perf_tripwire.ts --baseline path/to/results.md
 *   bun tools/testing/graph_perf_tripwire.ts --current path/to/fresh.json
 *   bun tools/testing/graph_perf_tripwire.ts --skip-run   # require --current
 *
 * Negative (prove compare direction):
 *   doctored results.md with 2× better (half ns) baselines → must FAIL.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { ROOT } from "../progress/paths.ts";

export const DEFAULT_THRESHOLD = 0.3;
export const DEFAULT_BASELINE = path.join(
  ROOT,
  "docs/reference/graph_tick_baseline.md"
);

/** Metrics present in task-10 results.md raw JSON. */
export const TRACKED: Array<{
  case: string;
  field: "runNs" | "batchNs";
  key: string;
}> = [
  { case: "scalar_3", field: "runNs", key: "scalar_3.runNs" },
  { case: "scalar_3", field: "batchNs", key: "scalar_3.batchNs" },
  { case: "scalar_10", field: "runNs", key: "scalar_10.runNs" },
  { case: "scalar_10", field: "batchNs", key: "scalar_10.batchNs" },
  { case: "scalar_50", field: "runNs", key: "scalar_50.runNs" },
  { case: "scalar_50", field: "batchNs", key: "scalar_50.batchNs" },
  { case: "matrix_edge", field: "runNs", key: "matrix_edge.runNs" },
];

export type MetricMap = Record<string, number>;

export type CompareRow = {
  key: string;
  baseline: number;
  current: number;
  ratio: number;
  pctWorse: number;
  ok: boolean;
};

export type CompareResult = {
  threshold: number;
  rows: CompareRow[];
  regressions: CompareRow[];
  missing: string[];
  ok: boolean;
};

/** Parse the first fenced ```json block that contains `"rows"` from results.md. */
export function parseBaselineResultsMd(text: string): MetricMap {
  const fence = /```json\s*([\s\S]*?)```/g;
  let m: RegExpExecArray | null;
  while ((m = fence.exec(text)) !== null) {
    const body = m[1]!.trim();
    if (!body.includes('"rows"')) continue;
    try {
      const parsed = JSON.parse(body) as {
        rows?: Array<{
          case: string;
          runNs?: number | null;
          batchNs?: number | null;
        }>;
      };
      if (!Array.isArray(parsed.rows)) continue;
      return rowsToMetrics(parsed.rows);
    } catch {
      continue;
    }
  }
  throw new Error(
    "graph_perf_tripwire: no parseable ```json rows block in baseline file"
  );
}

export function rowsToMetrics(
  rows: Array<{
    case: string;
    runNs?: number | null;
    batchNs?: number | null;
    runtime?: string;
  }>
): MetricMap {
  const out: MetricMap = {};
  for (const r of rows) {
    // Prefer multi runtime rows when present (fresh graph_tick --runtime multi
    // only emits multi; results.md has no runtime field).
    if (r.runtime != null && r.runtime !== "multi") continue;
    if (typeof r.runNs === "number" && Number.isFinite(r.runNs)) {
      out[`${r.case}.runNs`] = r.runNs;
    }
    if (typeof r.batchNs === "number" && Number.isFinite(r.batchNs)) {
      out[`${r.case}.batchNs`] = r.batchNs;
    }
  }
  return out;
}

/** Extract metrics from graph_tick.ts `--- json ---` footer payload. */
export function parseGraphTickJson(payload: unknown): MetricMap {
  if (!payload || typeof payload !== "object") {
    throw new Error("graph_perf_tripwire: current payload is not an object");
  }
  const rows = (payload as { rows?: unknown }).rows;
  if (!Array.isArray(rows)) {
    throw new Error("graph_perf_tripwire: current payload missing rows[]");
  }
  return rowsToMetrics(
    rows as Array<{
      case: string;
      runNs?: number | null;
      batchNs?: number | null;
      runtime?: string;
    }>
  );
}

/**
 * Parse stdout of graph_tick.ts for the trailing JSON object after `--- json ---`.
 */
export function extractJsonFromGraphTickStdout(stdout: string): unknown {
  const marker = "--- json ---";
  const idx = stdout.lastIndexOf(marker);
  if (idx < 0) {
    throw new Error(
      "graph_perf_tripwire: graph_tick stdout missing '--- json ---' footer"
    );
  }
  const rest = stdout.slice(idx + marker.length).trim();
  // Find outermost object
  const start = rest.indexOf("{");
  if (start < 0) throw new Error("graph_perf_tripwire: no JSON object after marker");
  let depth = 0;
  let end = -1;
  for (let i = start; i < rest.length; i++) {
    const ch = rest[i];
    if (ch === "{") depth++;
    else if (ch === "}") {
      depth--;
      if (depth === 0) {
        end = i;
        break;
      }
    }
  }
  if (end < 0) throw new Error("graph_perf_tripwire: unclosed JSON object in stdout");
  return JSON.parse(rest.slice(start, end + 1));
}

/**
 * Compare current vs baseline. REGRESSION when current is slower than baseline
 * by more than `threshold` (fraction). Missing keys collected separately.
 */
export function compareMetrics(
  baseline: MetricMap,
  current: MetricMap,
  threshold: number = DEFAULT_THRESHOLD
): CompareResult {
  const rows: CompareRow[] = [];
  const missing: string[] = [];

  for (const t of TRACKED) {
    const b = baseline[t.key];
    const c = current[t.key];
    if (b == null || !Number.isFinite(b) || b <= 0) {
      missing.push(`baseline:${t.key}`);
      continue;
    }
    if (c == null || !Number.isFinite(c)) {
      missing.push(`current:${t.key}`);
      continue;
    }
    const ratio = c / b;
    const pctWorse = (ratio - 1) * 100;
    const ok = c <= b * (1 + threshold);
    rows.push({
      key: t.key,
      baseline: b,
      current: c,
      ratio,
      pctWorse,
      ok,
    });
  }

  const regressions = rows.filter((r) => !r.ok);
  return {
    threshold,
    rows,
    regressions,
    missing,
    ok: regressions.length === 0 && missing.length === 0,
  };
}

export function formatCompareReport(result: CompareResult): string {
  const lines: string[] = [
    `graph_perf_tripwire threshold=${(result.threshold * 100).toFixed(0)}% (fail if current > baseline × ${1 + result.threshold})`,
    "",
    "metric".padEnd(22) +
      "baseline".padStart(12) +
      "current".padStart(12) +
      "ratio".padStart(10) +
      "  status",
  ];
  for (const r of result.rows) {
    const status = r.ok ? "OK" : "REGRESSION";
    lines.push(
      r.key.padEnd(22) +
        r.baseline.toFixed(2).padStart(12) +
        r.current.toFixed(2).padStart(12) +
        `${r.ratio.toFixed(3)}×`.padStart(10) +
        `  ${status}` +
        (r.ok ? "" : ` (+${r.pctWorse.toFixed(1)}%)`)
    );
  }
  if (result.missing.length) {
    lines.push("", "missing:");
    for (const m of result.missing) lines.push(`  - ${m}`);
  }
  lines.push(
    "",
    result.ok
      ? "PASS — no tracked metric regressed beyond threshold"
      : `FAIL — ${result.regressions.length} regression(s), ${result.missing.length} missing`
  );
  return lines.join("\n");
}

function parseArgs(argv: string[]) {
  let threshold = DEFAULT_THRESHOLD;
  let baselinePath = DEFAULT_BASELINE;
  let currentPath: string | null = null;
  let skipRun = false;
  let ticks = 100_000;
  let batches = 7;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    if (a === "--threshold") threshold = Number(argv[++i]);
    else if (a === "--baseline") baselinePath = path.resolve(argv[++i]!);
    else if (a === "--current") currentPath = path.resolve(argv[++i]!);
    else if (a === "--skip-run") skipRun = true;
    else if (a === "--ticks") ticks = Number(argv[++i]);
    else if (a === "--batches") batches = Number(argv[++i]);
    else if (a === "--help" || a === "-h") {
      console.log(`Usage: bun tools/testing/graph_perf_tripwire.ts [options]

Options:
  --threshold <f>   regression fraction (default ${DEFAULT_THRESHOLD})
  --baseline <path> results.md (default ${path.relative(ROOT, DEFAULT_BASELINE)})
  --current <path>  pre-captured graph_tick JSON (skips bench if set with --skip-run)
  --skip-run        do not invoke graph_tick (requires --current)
  --ticks <n>       graph_tick --ticks (default 100000)
  --batches <n>     graph_tick --batches (default 7)

Fail if any tracked multi ns/tick is > baseline × (1+threshold).
`);
      process.exit(0);
    } else if (a.startsWith("-")) {
      console.error(`Unknown flag: ${a}`);
      process.exit(2);
    }
  }
  if (!Number.isFinite(threshold) || threshold < 0) {
    console.error("--threshold must be a non-negative number");
    process.exit(2);
  }
  return { threshold, baselinePath, currentPath, skipRun, ticks, batches };
}

async function runFreshBench(ticks: number, batches: number): Promise<MetricMap> {
  const cmd = [
    "bun",
    path.join(ROOT, "tools/bench/graph_tick.ts"),
    "--runtime",
    "multi",
    "--mode",
    "both",
    "--ticks",
    String(ticks),
    "--batches",
    String(batches),
  ];
  console.log(`$ ${cmd.join(" ")}`);
  const proc = Bun.spawn({
    cmd,
    cwd: ROOT,
    env: process.env,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  if (code !== 0) {
    console.error(stderr || stdout);
    throw new Error(`graph_tick exited ${code}`);
  }
  // Mirror live output for CI logs
  process.stdout.write(stdout);
  if (stderr) process.stderr.write(stderr);
  const payload = extractJsonFromGraphTickStdout(stdout);
  return parseGraphTickJson(payload);
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (!fs.existsSync(opts.baselinePath)) {
    console.error(`Missing baseline: ${opts.baselinePath}`);
    process.exit(2);
  }
  const baselineText = fs.readFileSync(opts.baselinePath, "utf8");
  const baseline = parseBaselineResultsMd(baselineText);

  let current: MetricMap;
  if (opts.currentPath) {
    const raw = JSON.parse(fs.readFileSync(opts.currentPath, "utf8"));
    // Accept either full graph_tick payload or flat metric map
    current =
      raw && typeof raw === "object" && Array.isArray((raw as { rows?: unknown }).rows)
        ? parseGraphTickJson(raw)
        : (raw as MetricMap);
  } else if (opts.skipRun) {
    console.error("--skip-run requires --current <path>");
    process.exit(2);
  } else {
    current = await runFreshBench(opts.ticks, opts.batches);
  }

  const result = compareMetrics(baseline, current, opts.threshold);
  console.log("\n" + formatCompareReport(result));
  process.exit(result.ok ? 0 : 1);
}

if (import.meta.main) {
  main().catch((err) => {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  });
}
