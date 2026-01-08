export type CsvRow = {
  timestamp: number;
  featureId: string;
  testName: string;
  iterations: number;
  durationMs: number;
  opsPerSec: number;
  memAllocated: number;
  memReserved: number;
  memPeak: number;
  sampleCount?: number;
  opsP50?: number;
  opsP95?: number;
  opsStddev?: number;
  runMode?: string;
  gitSha?: string;
  cpuModel?: string;
  cpuCores?: number;
  osInfo?: string;
  bunVersion?: string;
  zigVersion?: string;
  perfSamples?: number;
};

export type BenchResult = {
  bench_id: string;
  backend: string;
  threads: number;
  raw_test_name: string;
  score: number;
  unit: string;
  iterations: number;
  duration_ms: number;
  ops_p50: number;
  ops_p95?: number;
  ops_stddev?: number;
  sample_count: number;
  mem_peak: number;
};

export type SnapshotMeta = {
  id: string;
  kind: "release" | "dev";
  git_tag: string | null;
  git_sha: string;
  feature_id: string;
  recorded_at: string;
  machine_id: string;
  tier: string;
  cpu_model: string;
  cpu_cores: number;
  os: string;
  zig_version: string;
  bun_version: string;
  perf_samples: number;
};

export type Snapshot = {
  snapshot: SnapshotMeta;
  results: BenchResult[];
};

export type SnapshotIndexEntry = {
  id: string;
  kind: "release" | "dev";
  git_tag: string | null;
  git_sha: string;
  feature_id: string;
  recorded_at: string;
  machine_id: string;
  tier: string;
  bench_count: number;
  file: string;
};

export type SnapshotIndex = {
  generated_at: string;
  machine_id: string;
  snapshots: SnapshotIndexEntry[];
};