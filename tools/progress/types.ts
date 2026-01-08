import type { BenchResult, Snapshot, SnapshotMeta } from "../bench/types";

export type PackageStatus = "pass" | "fail" | "partial";
export type PackageKind = "dev" | "release" | "failed";
export type CorrectnessOverall = "pass" | "fail";
export type PerformanceStatus = "ok" | "skipped" | "error";
export type ThresholdSource = "manifest" | "heuristic_hot" | "heuristic_integration" | "cli_max";
export type CompareRowStatus =
  | "OK"
  | "REGRESSION_REL"
  | "REGRESSION_ABS"
  | "UNSTABLE"
  | "MISSING_AFTER"
  | "NEW_IN_AFTER";

export type BenchMode = "zig" | "ts" | "all";

/** Matrix backends (v1 product columns). */
export const MATRIX_BACKENDS = ["zig_vm", "ts_ffi", "ts_wasm_vm", "wasm_aot"] as const;
export type MatrixBackend = (typeof MATRIX_BACKENDS)[number];

export type CorrectnessStep = {
  id: string;
  status: "pass" | "fail" | "skipped";
  duration_sec: number | null;
  log: string | null;
  reason: string | null;
};

export type ParityBackendSummary = {
  pass: number;
  fail: number;
  skip: number;
  total: number;
  csv: string;
  missing?: boolean;
};

export type CorrectnessDocument = {
  schema_version: 1;
  overall: CorrectnessOverall;
  gate_started_at: string;
  steps: CorrectnessStep[];
  parity: {
    task_id: string;
    backends_executed: string[];
    backends: Record<string, ParityBackendSummary>;
    backends_not_executed: string[];
    report: string;
  };
};

/** Re-export SoT from feature_status to avoid dual definitions. */
export type { FeatureStatus } from "./feature_status.ts";
import type { FeatureStatus } from "./feature_status.ts";

export type FeatureCellBackend = {
  status: FeatureStatus;
  pass?: number;
  fail?: number;
  skip?: number;
  evidence: string;
};

export type FeatureCell = {
  feature_id: string;
  category: string;
  label: string;
  related_bench_ids: string[];
  by_backend: Record<string, FeatureCellBackend>;
};

/** Per-backend status histogram (§C.6). */
export type StatusHistogram = {
  done: number;
  partial: number;
  broken: number;
  skipped: number;
  missing: number;
  "n/a": number;
  unknown: number;
};

/** Versioned feature matrix snapshot (§C.6). */
export type FeaturesDocument = {
  schema_version: 1;
  version_id: string;
  /** Optional package sequence (present when written via write_package). */
  seq?: number;
  generated_at: string;
  catalog_hash: string;
  backends: string[];
  backends_executed: string[];
  cells: FeatureCell[];
  summary: Record<string, StatusHistogram>;
};

export type PerformanceDocumentOk = {
  schema_version: 1;
  status: "ok";
  snapshot: SnapshotMeta;
  results: BenchResult[];
  source_path?: string;
};

export type PerformanceDocumentStub = {
  schema_version: 1;
  status: "skipped" | "error";
  reason: string;
  exit_code?: number | null;
  results: [];
};

export type PerformanceDocument = PerformanceDocumentOk | PerformanceDocumentStub;

export type PerformanceCompareRow = {
  test_name: string;
  bench_id: string;
  backend: string;
  threads: number;
  baseline_score: number | null;
  after_score: number | null;
  pct_delta: number | null;
  threshold_pct: number;
  threshold_source: ThresholdSource;
  status: CompareRowStatus;
  cv_after?: number | null;
  class?: string;
};

export type PerformanceCompareDocument = {
  schema_version: 1;
  baseline_version_id: string | null;
  after_version_id: string | null;
  baseline_feature_id: string;
  after_feature_id: string;
  machine_id: string | null;
  suite: string;
  source_module: string;
  max_regression_pct: number;
  rows: PerformanceCompareRow[];
  failure_count: number;
};

export type MetaDocument = {
  schema_version: 1;
  version_id: string;
  /** Append-only sequence (disk-scanned max+1). */
  seq: number;
  /** Same as version_id; stable sort key for history. */
  sort_key: string;
  /**
   * Automatic tag for the run (same as feature_id from `bun run mz`):
   * `{branch}__{UTC_time}__{short_sha}[__dirty]`
   */
  label: string;
  kind: PackageKind;
  status: PackageStatus;
  /**
   * Automatic tag / run identity (pipeline deriveRunId).
   * Not a user-supplied feature name.
   */
  feature_id: string;
  git_sha: string;
  git_sha_full: string;
  /** Real git release tag if any; not the automatic run tag. */
  git_tag: string | null;
  recorded_at: string;
  gate_started_at: string;
  machine_id: string;
  cpu_model: string;
  cpu_cores: number;
  os: string;
  zig_version: string;
  bun_version: string;
  mathzig_version: string;
  baseline_feature_id: string | null;
  baseline_version_id: string | null;
  tier: string;
  bench_mode: BenchMode;
  has_performance: boolean;
  bench_snapshot_id: string | null;
  gate_run_dir: string;
  parity_backends_executed: string[];
};

export type ProgressIndexEntry = {
  version_id: string;
  seq: number;
  sort_key: string;
  label: string;
  kind: PackageKind;
  status: PackageStatus;
  feature_id: string;
  git_sha: string;
  git_tag: string | null;
  recorded_at: string;
  machine_id: string;
  has_performance: boolean;
  tier: string;
  bench_mode: BenchMode;
  path: string;
  source: "local" | "release";
};

export type ProgressIndex = {
  schema_version: 1;
  generated_at: string;
  packages: ProgressIndexEntry[];
};

/** Static UI app data (build_app_data.ts → apps/progress/public/data). */

export type AppDataIndex = {
  schema_version: 1;
  generated_at: string;
  package_count: number;
  machine_ids: string[];
  /** True when more than one distinct machine_id is present. */
  mixed_machines: boolean;
  packages: ProgressIndexEntry[];
};

/** Per-point in precomputed perf trend series. */
export type AppDataSeriesPoint = {
  seq: number;
  version_id: string;
  score: number;
  threads: number;
  unit: string;
  machine_id: string;
  recorded_at: string;
  feature_id: string;
};

/**
 * Precomputed series: bench_id → backend → ordered points (by package seq).
 * Threads are fields on each point so multi-thread runs share the same backend key.
 */
export type AppDataSeries = {
  schema_version: 1;
  generated_at: string;
  series: Record<string, Record<string, AppDataSeriesPoint[]>>;
};

/** Correctness without full step logs / report paths. */
export type SlimCorrectness = {
  overall: CorrectnessOverall;
  gate_started_at: string;
  steps: Array<{
    id: string;
    status: CorrectnessStep["status"];
    duration_sec: number | null;
    reason: string | null;
  }>;
  parity: {
    task_id: string;
    backends_executed: string[];
    backends: Record<
      string,
      {
        pass: number;
        fail: number;
        skip: number;
        total: number;
        missing?: boolean;
      }
    >;
    backends_not_executed: string[];
  };
};

/** Features summary only (full matrix lives in features_latest.json). */
export type SlimFeatures = {
  version_id: string;
  seq?: number;
  catalog_hash: string;
  backends: string[];
  backends_executed: string[];
  summary: Record<string, StatusHistogram>;
  cell_count: number;
};

export type SlimPerformanceResult = {
  bench_id: string;
  backend: string;
  threads: number;
  score: number;
  unit: string;
  ops_p50?: number;
  ops_p95?: number;
  sample_count?: number;
};

export type SlimPerformance = {
  status: PerformanceStatus;
  reason?: string;
  snapshot_id?: string | null;
  results: SlimPerformanceResult[];
};

export type SlimPackage = {
  meta: MetaDocument;
  correctness: SlimCorrectness;
  features: SlimFeatures | null;
  performance: SlimPerformance;
};

export type AppDataPackages = {
  schema_version: 1;
  generated_at: string;
  packages: Record<string, SlimPackage>;
};

export type { Snapshot, SnapshotMeta, BenchResult };
