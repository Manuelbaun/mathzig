#!/usr/bin/env bun
/**
 * Flatten progress packages into static JSON for apps/progress (public/data).
 *
 * Outputs (default: apps/progress/public/data/):
 *   index.json           — packages sorted by seq + machine filter metadata
 *   packages.json        — version_id → slim { meta, correctness, features, performance }
 *   series.json          — bench_id → backend → [{seq, version_id, score, ...}]
 *   features_latest.json — full features matrix of the latest package (or empty stub)
 *
 * Does not embed full correctness step logs or parity report paths.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { writeJsonAtomic } from "../testing/feature_gate_steps.ts";
import {
  comparePerformance,
  performanceDocToRows,
} from "./compare_performance.ts";
import { DEFAULT_APP_DATA_DIR, ROOT, getProgressPaths } from "./paths.ts";
import type {
  AppDataIndex,
  AppDataPackages,
  AppDataSeries,
  AppDataSeriesPoint,
  CorrectnessDocument,
  FeaturesDocument,
  MetaDocument,
  PerformanceCompareDocument,
  PerformanceDocument,
  ProgressIndexEntry,
  SlimCorrectness,
  SlimFeatures,
  SlimPackage,
  SlimPerformance,
  StatusHistogram,
} from "./types.ts";

export type BuildAppDataOptions = {
  /** Progress root (default: PROGRESS_DIR / tests/artifacts/progress). */
  progressDir?: string;
  /** Output directory (default: apps/progress/public/data). */
  outDir?: string;
  /** Suppress console logging (tests). */
  quiet?: boolean;
};

export type BuildAppDataResult = {
  outDir: string;
  package_count: number;
  machine_ids: string[];
  mixed_machines: boolean;
  series_bench_ids: string[];
  features_latest_version_id: string | null;
  files: string[];
};

type LoadedPackage = {
  meta: MetaDocument;
  correctness: CorrectnessDocument | null;
  features: FeaturesDocument | null;
  performance: PerformanceDocument | null;
  packageDir: string;
};

function log(quiet: boolean | undefined, msg: string): void {
  if (!quiet) console.log(msg);
}

function warn(quiet: boolean | undefined, msg: string): void {
  if (!quiet) console.warn(msg);
}

function readJsonIfExists<T>(filePath: string): T | null {
  if (!fs.existsSync(filePath)) return null;
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8")) as T;
  } catch {
    return null;
  }
}

/**
 * Scan packages dir; skip entries without readable meta / version_id.
 * Sorted by seq asc, then sort_key.
 */
export function loadPackagesSorted(progressDir?: string): LoadedPackage[] {
  const { PACKAGES_DIR } = getProgressPaths(progressDir);
  const loaded: LoadedPackage[] = [];

  if (!fs.existsSync(PACKAGES_DIR)) return loaded;

  for (const name of fs.readdirSync(PACKAGES_DIR)) {
    if (name.startsWith(".")) continue;
    const packageDir = path.join(PACKAGES_DIR, name);
    if (!fs.statSync(packageDir).isDirectory()) continue;

    const metaPath = path.join(packageDir, "meta.json");
    if (!fs.existsSync(metaPath)) continue;

    let meta: MetaDocument;
    try {
      meta = JSON.parse(fs.readFileSync(metaPath, "utf8")) as MetaDocument;
    } catch {
      continue;
    }
    if (!meta.version_id) continue;
    if (name !== meta.version_id) {
      // Match build_progress_index: reject phantom/staging dirs
      continue;
    }

    loaded.push({
      meta,
      correctness: readJsonIfExists<CorrectnessDocument>(path.join(packageDir, "correctness.json")),
      features: readJsonIfExists<FeaturesDocument>(path.join(packageDir, "features.json")),
      performance: readJsonIfExists<PerformanceDocument>(path.join(packageDir, "performance.json")),
      packageDir,
    });
  }

  loaded.sort((a, b) => {
    const sa = a.meta.seq ?? 0;
    const sb = b.meta.seq ?? 0;
    if (sa !== sb) return sa - sb;
    const ka = a.meta.sort_key ?? a.meta.version_id;
    const kb = b.meta.sort_key ?? b.meta.version_id;
    return ka.localeCompare(kb);
  });

  return loaded;
}

function toIndexEntry(meta: MetaDocument): ProgressIndexEntry {
  return {
    version_id: meta.version_id,
    seq: meta.seq ?? 0,
    sort_key: meta.sort_key ?? meta.version_id,
    label: meta.label ?? meta.feature_id,
    kind: meta.kind,
    status: meta.status,
    feature_id: meta.feature_id,
    git_sha: meta.git_sha,
    git_tag: meta.git_tag,
    recorded_at: meta.recorded_at,
    machine_id: meta.machine_id,
    has_performance: meta.has_performance,
    tier: meta.tier,
    bench_mode: meta.bench_mode,
    path: `packages/${meta.version_id}`,
    source: "local",
  };
}

function slimCorrectness(doc: CorrectnessDocument | null): SlimCorrectness {
  if (!doc) {
    return {
      overall: "fail",
      gate_started_at: "",
      steps: [],
      parity: {
        task_id: "",
        backends_executed: [],
        backends: {},
        backends_not_executed: [],
      },
    };
  }

  const backends: SlimCorrectness["parity"]["backends"] = {};
  for (const [backend, summary] of Object.entries(doc.parity?.backends ?? {})) {
    backends[backend] = {
      pass: summary.pass,
      fail: summary.fail,
      skip: summary.skip,
      total: summary.total,
      ...(summary.missing ? { missing: true } : {}),
    };
  }

  return {
    overall: doc.overall,
    gate_started_at: doc.gate_started_at,
    steps: (doc.steps ?? []).map((s) => ({
      id: s.id,
      status: s.status,
      duration_sec: s.duration_sec,
      reason: s.reason,
      // intentionally omit log paths
    })),
    parity: {
      task_id: doc.parity?.task_id ?? "",
      backends_executed: doc.parity?.backends_executed ?? [],
      backends,
      backends_not_executed: doc.parity?.backends_not_executed ?? [],
    },
  };
}

function slimFeatures(doc: FeaturesDocument | null): SlimFeatures | null {
  if (!doc) return null;
  return {
    version_id: doc.version_id,
    ...(doc.seq !== undefined ? { seq: doc.seq } : {}),
    catalog_hash: doc.catalog_hash,
    backends: doc.backends ?? [],
    backends_executed: doc.backends_executed ?? [],
    summary: doc.summary ?? {},
    cell_count: doc.cells?.length ?? 0,
  };
}

function slimPerformance(doc: PerformanceDocument | null): SlimPerformance {
  if (!doc) {
    return { status: "error", reason: "missing_performance", results: [] };
  }
  if (doc.status !== "ok") {
    return {
      status: doc.status,
      reason: doc.reason,
      results: [],
    };
  }
  return {
    status: "ok",
    snapshot_id: doc.snapshot?.id ?? null,
    results: (doc.results ?? []).map((r) => ({
      bench_id: r.bench_id,
      backend: r.backend,
      threads: r.threads,
      score: r.score,
      unit: r.unit,
      ...(r.ops_p50 !== undefined ? { ops_p50: r.ops_p50 } : {}),
      ...(r.ops_p95 !== undefined ? { ops_p95: r.ops_p95 } : {}),
      ...(r.sample_count !== undefined ? { sample_count: r.sample_count } : {}),
    })),
  };
}

function toSlimPackage(pkg: LoadedPackage): SlimPackage {
  return {
    meta: pkg.meta,
    correctness: slimCorrectness(pkg.correctness),
    features: slimFeatures(pkg.features),
    performance: slimPerformance(pkg.performance),
  };
}

function buildSeries(packages: LoadedPackage[]): AppDataSeries["series"] {
  const series: AppDataSeries["series"] = {};

  for (const pkg of packages) {
    const perf = pkg.performance;
    if (!perf || perf.status !== "ok") continue;

    for (const r of perf.results ?? []) {
      const benchSeries = series[r.bench_id] ?? (series[r.bench_id] = {});
      const arr = benchSeries[r.backend] ?? (benchSeries[r.backend] = []);
      const point: AppDataSeriesPoint = {
        seq: pkg.meta.seq ?? 0,
        version_id: pkg.meta.version_id,
        score: r.score,
        threads: r.threads,
        unit: r.unit,
        machine_id: pkg.meta.machine_id,
        recorded_at: pkg.meta.recorded_at,
        feature_id: pkg.meta.feature_id,
      };
      arr.push(point);
    }
  }

  // Ensure points within each series are ordered by seq (packages already sorted)
  for (const byBackend of Object.values(series)) {
    for (const points of Object.values(byBackend)) {
      points.sort((a, b) => {
        if (a.seq !== b.seq) return a.seq - b.seq;
        return a.version_id.localeCompare(b.version_id);
      });
    }
  }

  return series;
}

function emptyFeaturesLatest(generatedAt: string): FeaturesDocument {
  return {
    schema_version: 1,
    version_id: "",
    generated_at: generatedAt,
    catalog_hash: "",
    backends: [],
    backends_executed: [],
    cells: [],
    summary: {},
  };
}

/** Aggregate status histogram across all backends in a features summary. */
export function aggregateStatusHistogram(
  summary: Record<string, StatusHistogram> | undefined
): StatusHistogram {
  const totals: StatusHistogram = {
    done: 0,
    partial: 0,
    broken: 0,
    skipped: 0,
    missing: 0,
    "n/a": 0,
    unknown: 0,
  };
  if (!summary) return totals;
  for (const hist of Object.values(summary)) {
    for (const key of Object.keys(totals) as Array<keyof StatusHistogram>) {
      totals[key] += hist[key] ?? 0;
    }
  }
  return totals;
}

function formatHistogram(hist: StatusHistogram): string {
  return (Object.keys(hist) as Array<keyof StatusHistogram>)
    .map((k) => `${k}=${hist[k]}`)
    .join(" ");
}

/**
 * Build static app data JSON under outDir from progress packages.
 */
export function buildAppData(opts: BuildAppDataOptions = {}): BuildAppDataResult {
  const quiet = opts.quiet === true;
  const progressDir = opts.progressDir;
  const outDir = opts.outDir
    ? path.isAbsolute(opts.outDir)
      ? opts.outDir
      : path.resolve(ROOT, opts.outDir)
    : DEFAULT_APP_DATA_DIR;

  const packages = loadPackagesSorted(progressDir);
  const generated_at = new Date().toISOString();

  const machineIdSet = new Set<string>();
  for (const pkg of packages) {
    if (pkg.meta.machine_id) machineIdSet.add(pkg.meta.machine_id);
  }
  const machine_ids = [...machineIdSet].sort();
  const mixed_machines = machine_ids.length > 1;

  if (mixed_machines) {
    warn(
      quiet,
      `build_app_data: WARNING mixed machine_ids (${machine_ids.length}): ${machine_ids.join(", ")}`
    );
  }

  const indexEntries = packages.map((p) => toIndexEntry(p.meta));
  const index: AppDataIndex = {
    schema_version: 1,
    generated_at,
    package_count: packages.length,
    machine_ids,
    mixed_machines,
    packages: indexEntries,
  };

  const packagesMap: Record<string, SlimPackage> = {};
  for (const pkg of packages) {
    packagesMap[pkg.meta.version_id] = toSlimPackage(pkg);
  }
  const packagesDoc: AppDataPackages = {
    schema_version: 1,
    generated_at,
    packages: packagesMap,
  };

  const seriesMap = buildSeries(packages);
  const seriesDoc: AppDataSeries = {
    schema_version: 1,
    generated_at,
    series: seriesMap,
  };

  const latest = packages.length > 0 ? packages[packages.length - 1]! : null;
  const featuresLatest: FeaturesDocument =
    latest?.features != null
      ? latest.features
      : emptyFeaturesLatest(generated_at);

  // Log matrix histogram from latest package when features present
  if (latest?.features && Object.keys(latest.features.summary ?? {}).length > 0) {
    const agg = aggregateStatusHistogram(latest.features.summary);
    const executed = latest.features.backends_executed ?? [];
    log(
      quiet,
      `build_app_data: features (latest ${latest.meta.version_id}) backends_executed=[${executed.join(",")}] cells=${latest.features.cells?.length ?? 0}`
    );
    log(quiet, `build_app_data: cell status histogram: ${formatHistogram(agg)}`);
    for (const backend of latest.features.backends ?? []) {
      const hist = latest.features.summary[backend];
      if (hist) {
        log(quiet, `  ${backend}: ${formatHistogram(hist)}`);
      }
    }
  }

  // Always materialize latest vs previous compare for the dashboard (no manual step).
  const latestCompare = buildLatestCompare(packages);

  fs.mkdirSync(outDir, { recursive: true });

  const files = [
    "index.json",
    "packages.json",
    "series.json",
    "features_latest.json",
    "latest_compare.json",
  ] as const;
  writeJsonAtomic(path.join(outDir, "index.json"), index);
  writeJsonAtomic(path.join(outDir, "packages.json"), packagesDoc);
  writeJsonAtomic(path.join(outDir, "series.json"), seriesDoc);
  writeJsonAtomic(path.join(outDir, "features_latest.json"), featuresLatest);
  writeJsonAtomic(path.join(outDir, "latest_compare.json"), latestCompare);

  log(
    quiet,
    `build_app_data: wrote ${packages.length} packages → ${path.relative(ROOT, outDir) || outDir} (machines=${machine_ids.length || 0})`
  );
  if (latestCompare.status === "ok") {
    log(
      quiet,
      `build_app_data: latest_compare ${latestCompare.baseline_automatic_tag} → ${latestCompare.after_automatic_tag} (regressions=${latestCompare.failure_count})`
    );
  } else {
    log(quiet, `build_app_data: latest_compare: ${latestCompare.reason ?? latestCompare.status}`);
  }

  return {
    outDir,
    package_count: packages.length,
    machine_ids,
    mixed_machines,
    series_bench_ids: Object.keys(seriesMap).sort(),
    features_latest_version_id: featuresLatest.version_id || null,
    files: [...files],
  };
}

export type LatestCompareDocument = {
  schema_version: 1;
  generated_at: string;
  status: "ok" | "insufficient" | "error";
  reason?: string;
  after_version_id: string | null;
  baseline_version_id: string | null;
  after_automatic_tag: string | null;
  baseline_automatic_tag: string | null;
  machine_id: string | null;
  failure_count: number;
  /** Embedded structured compare when available. */
  compare: PerformanceCompareDocument | null;
};

/**
 * Latest package (with perf) vs previous package (with perf) on the same machine.
 * Prefer package-embedded performance_compare.json; else compute package-to-package.
 */
export function buildLatestCompare(packages: LoadedPackage[]): LatestCompareDocument {
  const generated_at = new Date().toISOString();
  const withPerf = packages.filter(
    (p) => p.meta.has_performance && p.performance?.status === "ok"
  );
  if (withPerf.length < 2) {
    const latest = packages.length > 0 ? packages[packages.length - 1]! : null;
    return {
      schema_version: 1,
      generated_at,
      status: "insufficient",
      reason:
        withPerf.length === 0
          ? "no packages with performance yet — run full `bun run mz` (without --skip-measure)"
          : "only one package with performance — next full run will auto-compare",
      after_version_id: latest?.meta.version_id ?? withPerf[0]?.meta.version_id ?? null,
      baseline_version_id: null,
      after_automatic_tag: latest?.meta.feature_id ?? withPerf[0]?.meta.feature_id ?? null,
      baseline_automatic_tag: null,
      machine_id: latest?.meta.machine_id ?? null,
      failure_count: 0,
      compare: null,
    };
  }

  const after = withPerf[withPerf.length - 1]!;
  // Previous on same machine if possible
  let baseline = withPerf[withPerf.length - 2]!;
  for (let i = withPerf.length - 2; i >= 0; i -= 1) {
    if (withPerf[i]!.meta.machine_id === after.meta.machine_id) {
      baseline = withPerf[i]!;
      break;
    }
  }

  // Prefer precomputed compare file in the after package
  const embeddedPath = path.join(after.packageDir, "performance_compare.json");
  if (fs.existsSync(embeddedPath)) {
    try {
      const compare = JSON.parse(
        fs.readFileSync(embeddedPath, "utf8")
      ) as PerformanceCompareDocument;
      return {
        schema_version: 1,
        generated_at,
        status: "ok",
        after_version_id: after.meta.version_id,
        baseline_version_id: compare.baseline_version_id ?? baseline.meta.version_id,
        after_automatic_tag: after.meta.feature_id,
        baseline_automatic_tag: compare.baseline_feature_id ?? baseline.meta.feature_id,
        machine_id: after.meta.machine_id,
        failure_count: compare.failure_count ?? 0,
        compare,
      };
    } catch {
      /* fall through to recompute */
    }
  }

  try {
    const compare = comparePerformance({
      baseline_feature_id: baseline.meta.feature_id,
      after_feature_id: after.meta.feature_id,
      baseline_version_id: baseline.meta.version_id,
      after_version_id: after.meta.version_id,
      baseline_machine_id: baseline.meta.machine_id,
      after_machine_id: after.meta.machine_id,
      machine_id: after.meta.machine_id,
      suite: "all",
      max_regression_pct: 5,
      baseline_rows: performanceDocToRows(baseline.performance!),
      after_rows: performanceDocToRows(after.performance!),
      allow_cross_machine: false,
    });
    // Persist into package for next time (soft)
    try {
      writeJsonAtomic(path.join(after.packageDir, "performance_compare.json"), compare);
    } catch {
      /* ignore */
    }
    return {
      schema_version: 1,
      generated_at,
      status: "ok",
      after_version_id: after.meta.version_id,
      baseline_version_id: baseline.meta.version_id,
      after_automatic_tag: after.meta.feature_id,
      baseline_automatic_tag: baseline.meta.feature_id,
      machine_id: after.meta.machine_id,
      failure_count: compare.failure_count ?? 0,
      compare,
    };
  } catch (err) {
    return {
      schema_version: 1,
      generated_at,
      status: "error",
      reason: err instanceof Error ? err.message : String(err),
      after_version_id: after.meta.version_id,
      baseline_version_id: baseline.meta.version_id,
      after_automatic_tag: after.meta.feature_id,
      baseline_automatic_tag: baseline.meta.feature_id,
      machine_id: after.meta.machine_id,
      failure_count: 0,
      compare: null,
    };
  }
}

function parseArgs(argv: string[]): { progressDir?: string; outDir?: string } {
  let progressDir: string | undefined;
  let outDir: string | undefined;
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i]!;
    if (a === "--out" || a === "-o") {
      outDir = argv[++i];
    } else if (a === "--progress-dir") {
      progressDir = argv[++i];
    } else if (a === "--help" || a === "-h") {
      console.log(`Usage: bun tools/progress/build_app_data.ts [options]

Flatten progress packages into static JSON for apps/progress.

Options:
  --out, -o <dir>       Output directory (default: apps/progress/public/data)
  --progress-dir <dir>  Progress root (default: PROGRESS_DIR or tests/artifacts/progress)
  -h, --help            Show this help

Outputs: index.json, packages.json, series.json, features_latest.json, latest_compare.json
`);
      process.exit(0);
    } else if (!a.startsWith("-") && outDir === undefined) {
      // positional: out dir (plan: build_app_data.ts [--out apps/progress/public/data])
      outDir = a;
    }
  }
  return { progressDir, outDir };
}

if (import.meta.main) {
  const { progressDir, outDir } = parseArgs(process.argv.slice(2));
  // Also honor PROGRESS_DIR via getProgressPaths when progressDir unset
  const result = buildAppData({ progressDir, outDir });
  if (result.package_count === 0) {
    console.log("build_app_data: no packages found (empty index written)");
  }
}
