/**
 * Structured gate step document helpers (schema_version: 1).
 *
 * Package writer (PR1) contract notes:
 * - `parity_backends` is the list of backends the gate ran (env FEATURE_GATE_PARITY_BACKENDS).
 *   Map this to meta `parity_backends_executed` / correctness.parity.backends_executed —
 *   do not invent a different source.
 * - `max_regression_pct` is always the configured threshold (CLI default "5"), even when
 *   `baseline_source === "none"` and no compare step ran. It is the configured default,
 *   which may be unused for that run.
 * - `bench_mode` / `bench_tier` / `perf_strict` record FEATURE_GATE_BENCH_MODE,
 *   FEATURE_GATE_BENCH_TIER, and PERF_STRICT for the run (defaults: zig / smoke / false).
 * - Incomplete runs leave `finished_at` and `final_status` null with a partial `steps` array.
 * - Soft post-correctness fails may set step.status=fail while final_status remains
 *   pass when PERF_STRICT is off (exit policy is in feature_gate, not per-step reason).
 */
import * as fs from "node:fs";
import * as path from "node:path";

export type JsonStepStatus = "pass" | "fail" | "skipped";
export type FinalStatus = "pass" | "fail" | null;
export type BaselineSource = "explicit" | "auto" | "none";
export type BenchMode = "zig" | "ts" | "all";

export type GateStep = {
  id: string;
  status: JsonStepStatus;
  duration_sec: number | null;
  command: string[] | null;
  log: string | null;
  reason: string | null;
};

export type StepsDocument = {
  schema_version: 1;
  feature_id: string;
  started_at: string;
  finished_at: string | null;
  baseline_feature_id: string | null;
  baseline_source: BaselineSource;
  /** Configured threshold; present even when no baseline / compare step ran. */
  max_regression_pct: string;
  /**
   * Backends passed to parity CLI for this gate run.
   * PR1 package writer: map → meta.parity_backends_executed.
   */
  parity_backends: string[];
  /**
   * FEATURE_GATE_BENCH_MODE used for perf capture after correctness (default zig).
   * PR3 package writer: map → meta.bench_mode when not overridden.
   */
  bench_mode: BenchMode;
  /**
   * FEATURE_GATE_BENCH_TIER label (default smoke). Metadata only until tier-filter PR.
   */
  bench_tier: string;
  /**
   * PERF_STRICT for this run. When false, post-correctness step fails do not force
   * final_status=fail / non-zero gate exit.
   */
  perf_strict: boolean;
  steps: GateStep[];
  final_status: FinalStatus;
  artifacts: {
    parity_report: string;
    perf_log: string;
    perf_compare: string | null;
    overview: string;
  };
};

const JSON_STEP_STATUSES = new Set<JsonStepStatus>(["pass", "fail", "skipped"]);
const BASELINE_SOURCES = new Set<BaselineSource>(["explicit", "auto", "none"]);
const BENCH_MODES = new Set<BenchMode>(["zig", "ts", "all"]);

/** Write JSON atomically (temp file + rename) so readers never see a truncated document. */
export function writeJsonAtomic(filePath: string, value: unknown): void {
  const dir = path.dirname(filePath);
  const base = path.basename(filePath);
  const tmpPath = path.join(dir, `.${base}.${process.pid}.tmp`);
  fs.writeFileSync(tmpPath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  fs.renameSync(tmpPath, filePath);
}

export function isJsonStepStatus(value: unknown): value is JsonStepStatus {
  return typeof value === "string" && JSON_STEP_STATUSES.has(value as JsonStepStatus);
}

/**
 * Lightweight schema_version: 1 shape check for fixtures / package-writer consumers.
 * Throws with a descriptive message on violation.
 */
export function assertStepsDocumentV1(doc: unknown): asserts doc is StepsDocument {
  if (doc === null || typeof doc !== "object") {
    throw new Error("steps.json: expected object");
  }
  const d = doc as Record<string, unknown>;

  if (d.schema_version !== 1) {
    throw new Error(`steps.json: schema_version must be 1, got ${String(d.schema_version)}`);
  }
  if (typeof d.feature_id !== "string" || d.feature_id.length === 0) {
    throw new Error("steps.json: feature_id must be a non-empty string");
  }
  if (typeof d.started_at !== "string") {
    throw new Error("steps.json: started_at must be a string");
  }
  if (!(d.finished_at === null || typeof d.finished_at === "string")) {
    throw new Error("steps.json: finished_at must be string | null");
  }
  if (!(d.baseline_feature_id === null || typeof d.baseline_feature_id === "string")) {
    throw new Error("steps.json: baseline_feature_id must be string | null");
  }
  if (typeof d.baseline_source !== "string" || !BASELINE_SOURCES.has(d.baseline_source as BaselineSource)) {
    throw new Error(`steps.json: invalid baseline_source ${String(d.baseline_source)}`);
  }
  if (typeof d.max_regression_pct !== "string") {
    throw new Error("steps.json: max_regression_pct must be a string (configured default, may be unused)");
  }
  if (!Array.isArray(d.parity_backends) || !d.parity_backends.every((b) => typeof b === "string")) {
    throw new Error("steps.json: parity_backends must be string[] (map to parity_backends_executed in packages)");
  }
  if (typeof d.bench_mode !== "string" || !BENCH_MODES.has(d.bench_mode as BenchMode)) {
    throw new Error(`steps.json: bench_mode must be zig|ts|all, got ${String(d.bench_mode)}`);
  }
  if (typeof d.bench_tier !== "string" || d.bench_tier.length === 0) {
    throw new Error("steps.json: bench_tier must be a non-empty string (label; not filtered yet)");
  }
  if (typeof d.perf_strict !== "boolean") {
    throw new Error("steps.json: perf_strict must be a boolean");
  }
  if (!(d.final_status === null || d.final_status === "pass" || d.final_status === "fail")) {
    throw new Error(`steps.json: final_status must be pass|fail|null, got ${String(d.final_status)}`);
  }
  if (!Array.isArray(d.steps)) {
    throw new Error("steps.json: steps must be an array");
  }

  for (let i = 0; i < d.steps.length; i++) {
    const step = d.steps[i] as Record<string, unknown>;
    if (step === null || typeof step !== "object") {
      throw new Error(`steps.json: steps[${i}] must be an object`);
    }
    if (typeof step.id !== "string") {
      throw new Error(`steps.json: steps[${i}].id must be a string`);
    }
    if (!isJsonStepStatus(step.status)) {
      throw new Error(
        `steps.json: steps[${i}].status must be lowercase pass|fail|skipped, got ${String(step.status)}`
      );
    }
    if (step.status === "skipped") {
      if (typeof step.reason !== "string" || step.reason.length === 0) {
        throw new Error(`steps.json: steps[${i}] skipped requires non-empty reason`);
      }
      if (step.duration_sec !== null || step.command !== null || step.log !== null) {
        throw new Error(`steps.json: steps[${i}] skipped must have null duration_sec/command/log`);
      }
    } else {
      if (typeof step.duration_sec !== "number" || !Number.isFinite(step.duration_sec)) {
        throw new Error(`steps.json: steps[${i}].duration_sec must be a number`);
      }
      if (!Array.isArray(step.command) || !step.command.every((c) => typeof c === "string")) {
        throw new Error(`steps.json: steps[${i}].command must be string[]`);
      }
      if (typeof step.log !== "string") {
        throw new Error(`steps.json: steps[${i}].log must be a string`);
      }
      if (step.reason !== null) {
        throw new Error(`steps.json: steps[${i}] pass/fail reason must be null`);
      }
    }
  }

  const artifacts = d.artifacts as Record<string, unknown> | null;
  if (artifacts === null || typeof artifacts !== "object") {
    throw new Error("steps.json: artifacts must be an object");
  }
  for (const key of ["parity_report", "perf_log", "overview"] as const) {
    if (typeof artifacts[key] !== "string") {
      throw new Error(`steps.json: artifacts.${key} must be a string`);
    }
  }
  if (!(artifacts.perf_compare === null || typeof artifacts.perf_compare === "string")) {
    throw new Error("steps.json: artifacts.perf_compare must be string | null");
  }
}
