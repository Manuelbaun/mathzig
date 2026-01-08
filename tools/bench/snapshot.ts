import * as os from "node:os";
import type { BenchResult, CsvRow, Snapshot, SnapshotMeta } from "./types";
import { benchById, resolveBackend, resolveBenchId, resolveThreads } from "./manifest";

export function machineId(cpuModel: string, osInfo: string): string {
  const slug = `${osInfo}-${cpuModel}`.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
  return slug || "unknown-machine";
}

export function rowsToSnapshot(
  rows: CsvRow[],
  opts: {
    featureId: string;
    tier?: string;
    gitTag?: string | null;
    gitSha?: string;
    recordedAt?: string;
  }
): Snapshot | null {
  if (rows.length === 0) return null;

  const featureRows = rows.filter((r) => r.featureId === opts.featureId);
  if (featureRows.length === 0) return null;

  const first = featureRows[0];
  const cpuModel = first.cpuModel || os.cpus()[0]?.model || "unknown";
  const osInfo = first.osInfo || `${process.platform}-${process.arch}`;
  const gitSha = opts.gitSha || first.gitSha || "unknown";
  const gitTag = opts.gitTag ?? null;
  const kind: SnapshotMeta["kind"] = gitTag ? "release" : "dev";
  const snapshotId = gitTag ?? `${opts.featureId}_${gitSha}`;

  const results: BenchResult[] = featureRows.map((row) => {
    const bench_id = resolveBenchId(row.testName);
    const bench = benchById(bench_id);
    const score = row.opsP50 ?? row.opsPerSec;
    return {
      bench_id,
      backend: resolveBackend(row.testName),
      threads: resolveThreads(row.testName),
      raw_test_name: row.testName,
      score,
      unit: bench?.unit ?? "ops/s",
      iterations: row.iterations,
      duration_ms: row.durationMs,
      ops_p50: score,
      ops_p95: row.opsP95,
      ops_stddev: row.opsStddev,
      sample_count: row.sampleCount ?? 1,
      mem_peak: row.memPeak,
    };
  });

  const meta: SnapshotMeta = {
    id: snapshotId,
    kind,
    git_tag: gitTag,
    git_sha: gitSha,
    feature_id: opts.featureId,
    recorded_at: opts.recordedAt ?? new Date(first.timestamp * 1000).toISOString(),
    machine_id: machineId(cpuModel, osInfo),
    tier: opts.tier ?? "standard",
    cpu_model: cpuModel,
    cpu_cores: first.cpuCores || os.cpus().length,
    os: osInfo,
    zig_version: first.zigVersion || "unknown",
    bun_version: first.bunVersion || Bun.version,
    perf_samples: first.perfSamples || first.sampleCount || 1,
  };

  return { snapshot: meta, results };
}