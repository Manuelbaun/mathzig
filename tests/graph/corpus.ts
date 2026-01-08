/**
 * Shared cross-runner graph corpus loader (task-13 / C2).
 *
 * One source of truth under `tests/graph/goldens/`. Bun and Zig adapters both
 * consume these files. Execution modes:
 *   - ts_wasm     — TS GraphRunner (per-node AOT wasm)
 *   - native_vm   — VM-native graph evaluator v1
 *   - zig_vm      — composed-expression oracle (success goldens only)
 *   - native_wasm — pure-wasm node interpreter (phase-2; expected-skip)
 */

import { readdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";

export const GOLDENS_DIR = resolve(import.meta.dir, "goldens");

/** Exact skip reason for native wasm interpreter (phase-2). */
export const NATIVE_WASM_SKIP_ID = "phase2_native_wasm_interpreter" as const;

export type RunnerMode = "ts_wasm" | "native_vm" | "zig_vm" | "native_wasm";

export type GoldenForm = "success" | "load_error";

export type GoldenParam = { nodeId: string; name: string; value: number };

export type GoldenCase = {
  id: string;
  form: GoldenForm;
  graph: Record<string, unknown>;
  inputs?: Record<string, number>;
  params?: GoldenParam[];
  composed_expr?: string;
  composed_vars?: Record<string, number>;
  expected_outputs?: Record<string, unknown>;
  tolerance?: number;
  error_code?: string;
  offending?: string;
  note?: string;
  /** Source file basename (for diagnostics). */
  file: string;
};

export type SkipRecord = {
  case_id: string;
  mode: RunnerMode;
  id: typeof NATIVE_WASM_SKIP_ID;
  reason: string;
};

/** Stable golden filenames required by the task-13 corpus contract. */
export const REQUIRED_GOLDEN_FILES = [
  "scalar.json",
  "matrix.json",
  "complex.json",
  "record.json",
  "series.json",
  "params.json",
  "multi_output.json",
  "diamond.json",
  "empty.json",
  "single_node.json",
  "self_edge_error.json",
  "chain_100.json",
] as const;

export function loadAllGoldens(dir: string = GOLDENS_DIR): GoldenCase[] {
  for (const name of REQUIRED_GOLDEN_FILES) {
    const path = join(dir, name);
    try {
      readFileSync(path, "utf8");
    } catch {
      throw new Error(`Missing required golden file: ${name}`);
    }
  }

  const files = readdirSync(dir).filter((f) => f.endsWith(".json")).sort();
  const cases: GoldenCase[] = [];
  for (const file of files) {
    const raw = JSON.parse(readFileSync(join(dir, file), "utf8")) as GoldenCase | { cases: GoldenCase[] };
    if (raw && typeof raw === "object" && "cases" in raw && Array.isArray(raw.cases)) {
      for (const c of raw.cases) cases.push({ ...c, file });
    } else {
      cases.push({ ...(raw as GoldenCase), file });
    }
  }
  return cases;
}

/** Exact expected skip-ID set for corpus v1 (success cases × native_wasm). */
export function expectedSkipSet(cases: GoldenCase[] = loadAllGoldens()): SkipRecord[] {
  return cases
    .filter((c) => c.form === "success")
    .map((c) => ({
      case_id: c.id,
      mode: "native_wasm" as const,
      id: NATIVE_WASM_SKIP_ID,
      reason: "Pure-wasm node interpreter not landed (VM-native evaluator v1 never loads .wasm bytes).",
    }))
    .sort((a, b) => a.case_id.localeCompare(b.case_id));
}

export function skipKey(s: { case_id: string; mode: string; id: string }): string {
  return `${s.case_id}::${s.mode}::${s.id}`;
}

export function assertExactSkipSet(observed: SkipRecord[], expected: SkipRecord[] = expectedSkipSet()): void {
  const exp = new Set(expected.map(skipKey));
  const obs = new Set(observed.map(skipKey));
  const missing = [...exp].filter((k) => !obs.has(k));
  const extra = [...obs].filter((k) => !exp.has(k));
  if (missing.length || extra.length) {
    throw new Error(
      `Skip-ID set mismatch.\n  missing: ${missing.join(", ") || "(none)"}\n  extra: ${extra.join(", ") || "(none)"}`,
    );
  }
}
