#!/usr/bin/env bun
/**
 * Assemble a progress version package from steps.json (+ optional perf snapshot).
 *
 * version_id = {seq:08d}__{YYYYMMDDTHHMMSS}Z__{slug}__{short_sha}
 * Always-new, append-only: never overwrites existing package directories.
 */
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  assertStepsDocumentV1,
  type StepsDocument,
  writeJsonAtomic,
} from "../testing/feature_gate_steps.ts";
import { machineId } from "../bench/snapshot.ts";
import type { Snapshot } from "../bench/types.ts";
import {
  ensureProgressDirs,
  PARITY_ARTIFACTS_DIR,
  ROOT,
  RUNS_DIR,
  SNAPSHOTS_DIR,
  VERSION_FILE,
} from "./paths.ts";
import {
  MATRIX_BACKENDS,
  type BenchMode,
  type CorrectnessDocument,
  type CorrectnessStep,
  type FeaturesDocument,
  type MetaDocument,
  type PackageKind,
  type PackageStatus,
  type ParityBackendSummary,
  type PerformanceCompareDocument,
  type PerformanceDocument,
} from "./types.ts";
import { buildProgressIndex } from "./build_progress_index.ts";
import { buildFeaturesDocument, splitCsvLine } from "./build_features.ts";
import { comparePerformance, performanceDocToRows } from "./compare_performance.ts";

const CORRECTNESS_STEP_IDS = ["zig_vm_baseline", "zig_tests", "ts_tests", "parity_full"] as const;

export type WritePackageOptions = {
  featureId: string;
  stepsPath?: string;
  baselineFeatureId?: string | null;
  /**
   * Optional package version_id for baseline linkage (PR3 will resolve from index).
   * Stored in meta.baseline_version_id when provided.
   */
  baselineVersionId?: string | null;
  /**
   * When true, write performance_compare.json via structured SoT (CSV/feature path).
   * Default false — opt in via --compare. Full package baseline resolution is PR3.
   */
  writeCompare?: boolean;
  benchMode?: BenchMode;
  tier?: string;
  snapshotPath?: string | null;
  /** Override progress root (tests). Also honors PROGRESS_DIR. */
  progressDir?: string;
  /** Override parity CSV root (tests). Default: tests/artifacts/parity. */
  parityArtifactsDir?: string;
  /** Override snapshots root for auto-discovery. Default: tests/artifacts/performance/snapshots. */
  snapshotsDir?: string;
  /** Override feature catalog path (tests). Default: bench/features/catalog.json. */
  catalogPath?: string;
  /** Override parity cases dir (tests). Default: tests/parity/cases. */
  casesDir?: string;
  /** Override git sha (tests). */
  gitSha?: string;
  /** Override recorded_at / timestamp for version_id (tests). */
  recordedAt?: string;
  /** Skip rebuilding index (caller can rebuild). Default: rebuild. */
  rebuildIndex?: boolean;
};

export type WritePackageResult = {
  version_id: string;
  seq: number;
  package_dir: string;
  status: PackageStatus;
  has_performance: boolean;
  meta: MetaDocument;
};

function usage(): never {
  console.error(
    [
      "Usage:",
      "  bun tools/progress/write_package.ts --feature <feature_id> [options]",
      "  bun tools/progress/write_package.ts <feature_id>",
      "",
      "Options:",
      "  --steps <path>              default: tests/artifacts/runs/<feature_id>/steps.json",
      "  --baseline-feature <id>     override baseline feature id",
      "  --baseline-version <id>     set meta.baseline_version_id (package version_id)",
      "  --compare / --no-compare    write performance_compare.json when baseline+perf exist",
      "  --bench-mode zig|ts|all     default: zig",
      "  --tier <tier>               default: smoke",
      "  --snapshot <path>           embed this performance snapshot",
    ].join("\n")
  );
  process.exit(2);
}

function parseArgs(argv: string[]): WritePackageOptions {
  if (argv.length === 0) usage();

  // Positional: feature_id only
  if (!argv[0].startsWith("-") && argv.length === 1) {
    return { featureId: argv[0] };
  }

  let featureId = "";
  let stepsPath: string | undefined;
  let baselineFeatureId: string | null | undefined;
  let baselineVersionId: string | null | undefined;
  let writeCompare: boolean | undefined;
  let benchMode: BenchMode | undefined;
  let tier: string | undefined;
  let snapshotPath: string | null | undefined;

  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--feature") {
      featureId = argv[++i] ?? "";
    } else if (a === "--steps") {
      stepsPath = argv[++i];
    } else if (a === "--baseline-feature") {
      baselineFeatureId = argv[++i] ?? null;
    } else if (a === "--baseline-version") {
      baselineVersionId = argv[++i] ?? null;
    } else if (a === "--compare") {
      writeCompare = true;
    } else if (a === "--no-compare") {
      writeCompare = false;
    } else if (a === "--bench-mode") {
      const m = argv[++i];
      if (m !== "zig" && m !== "ts" && m !== "all") usage();
      benchMode = m;
    } else if (a === "--tier") {
      tier = argv[++i];
    } else if (a === "--snapshot") {
      snapshotPath = argv[++i] ?? null;
    } else if (!a.startsWith("-") && !featureId) {
      featureId = a;
    } else {
      usage();
    }
  }

  if (!featureId) usage();
  return {
    featureId,
    stepsPath,
    baselineFeatureId,
    baselineVersionId,
    writeCompare,
    benchMode,
    tier,
    snapshotPath,
  };
}

/** Re-export quoted-field CSV splitter (SoT: build_features.ts). */
export { splitCsvLine };

/**
 * Summarize a parity CSV (`id,expr,status,reason`). Proper quoted-field parse.
 * Status column is matched case-insensitively as PASS|FAIL|SKIP.
 */
export function summarizeParityCsv(csvPath: string): {
  pass: number;
  fail: number;
  skip: number;
  total: number;
} {
  const text = fs.readFileSync(csvPath, "utf8");
  const lines = text.split(/\r?\n/).filter(Boolean);
  if (lines.length < 2) {
    return { pass: 0, fail: 0, skip: 0, total: 0 };
  }

  const header = splitCsvLine(lines[0]).map((h) => h.trim().toLowerCase());
  let statusIdx = header.indexOf("status");
  if (statusIdx < 0) statusIdx = 2; // conventional: id,expr,status,reason

  const counts = { pass: 0, fail: 0, skip: 0, total: 0 };
  for (let i = 1; i < lines.length; i += 1) {
    const cols = splitCsvLine(lines[i]);
    const raw = (cols[statusIdx] ?? "").trim().toUpperCase();
    if (raw !== "PASS" && raw !== "FAIL" && raw !== "SKIP") continue;
    counts.total += 1;
    if (raw === "PASS") counts.pass += 1;
    else if (raw === "FAIL") counts.fail += 1;
    else counts.skip += 1;
  }
  return counts;
}

export function slugifyFeatureId(featureId: string): string {
  return featureId
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 80) || "feature";
}

export function formatVersionTimestamp(d: Date): string {
  const y = d.getUTCFullYear();
  const mo = String(d.getUTCMonth() + 1).padStart(2, "0");
  const day = String(d.getUTCDate()).padStart(2, "0");
  const h = String(d.getUTCHours()).padStart(2, "0");
  const mi = String(d.getUTCMinutes()).padStart(2, "0");
  const s = String(d.getUTCSeconds()).padStart(2, "0");
  return `${y}${mo}${day}T${h}${mi}${s}Z`;
}

/** Scan packages dir for max seq (do not trust index alone). */
export function scanMaxSeq(packagesDir: string): number {
  if (!fs.existsSync(packagesDir)) return 0;
  let max = 0;
  for (const name of fs.readdirSync(packagesDir)) {
    const m = /^(\d{8})__/.exec(name);
    if (!m) continue;
    const n = Number(m[1]);
    if (Number.isFinite(n) && n > max) max = n;
  }
  return max;
}

export function buildVersionId(opts: {
  seq: number;
  recordedAt: string;
  slug: string;
  shortSha: string;
}): string {
  const ts = formatVersionTimestamp(new Date(opts.recordedAt));
  return `${String(opts.seq).padStart(8, "0")}__${ts}__${opts.slug}__${opts.shortSha}`;
}

function readMathzigVersion(): string {
  try {
    return fs.readFileSync(VERSION_FILE, "utf8").trim() || "0.0.0";
  } catch {
    return "0.0.0";
  }
}

function gitRevParse(override?: string): { short: string; full: string } {
  if (override) {
    const full = override;
    const short = full.slice(0, 7);
    return { short, full };
  }
  try {
    const full = Bun.spawnSync({
      cmd: ["git", "rev-parse", "HEAD"],
      cwd: ROOT,
      stdout: "pipe",
      stderr: "pipe",
    });
    const shortProc = Bun.spawnSync({
      cmd: ["git", "rev-parse", "--short=7", "HEAD"],
      cwd: ROOT,
      stdout: "pipe",
      stderr: "pipe",
    });
    const fullSha = new TextDecoder().decode(full.stdout ?? new Uint8Array()).trim() || "unknown";
    const shortSha =
      new TextDecoder().decode(shortProc.stdout ?? new Uint8Array()).trim() || fullSha.slice(0, 7);
    return { short: shortSha, full: fullSha };
  } catch {
    return { short: "unknown", full: "unknown" };
  }
}

function loadSteps(stepsPath: string): StepsDocument {
  if (!fs.existsSync(stepsPath)) {
    throw new Error(`steps.json not found: ${stepsPath}`);
  }
  const raw = JSON.parse(fs.readFileSync(stepsPath, "utf8"));
  assertStepsDocumentV1(raw);
  return raw;
}

function stepMap(steps: StepsDocument["steps"]): Map<string, StepsDocument["steps"][number]> {
  return new Map(steps.map((s) => [s.id, s]));
}

/**
 * Correctness overall from the four gate correctness steps only:
 *   zig_vm_baseline, zig_tests, ts_tests, parity_full
 *
 * Do **not** use steps.final_status — that includes post-correctness steps
 * (perf_zig_record, perf_compare, testing_overview). Correctness pass + perf
 * fail must yield package status partial/pass with performance attached, not
 * correctness fail + skipped perf.
 *
 * Missing correctness steps are treated as fail (incomplete gate).
 * Skipped correctness steps count as not-pass.
 */
export function evaluateCorrectness(steps: StepsDocument): {
  overall: "pass" | "fail";
  correctnessSteps: CorrectnessStep[];
} {
  const map = stepMap(steps.steps);
  const correctnessSteps: CorrectnessStep[] = CORRECTNESS_STEP_IDS.map((id) => {
    const s = map.get(id);
    if (!s) {
      return { id, status: "fail", duration_sec: null, log: null, reason: "step_missing" };
    }
    return {
      id: s.id,
      status: s.status,
      duration_sec: s.duration_sec,
      log: s.log,
      reason: s.reason,
    };
  });

  const overall = correctnessSteps.every((s) => s.status === "pass") ? "pass" : "fail";
  return { overall, correctnessSteps };
}

export function buildParitySummary(
  featureId: string,
  backendsExecuted: string[],
  parityArtifactsDir: string = PARITY_ARTIFACTS_DIR
): CorrectnessDocument["parity"] {
  const backends: Record<string, ParityBackendSummary> = {};
  for (const backend of backendsExecuted) {
    const rel = `tests/artifacts/parity/${featureId}_${backend}.csv`;
    const abs = path.join(parityArtifactsDir, `${featureId}_${backend}.csv`);
    if (!fs.existsSync(abs)) {
      backends[backend] = {
        pass: 0,
        fail: 0,
        skip: 0,
        total: 0,
        csv: rel,
        missing: true,
      };
      continue;
    }
    const counts = summarizeParityCsv(abs);
    backends[backend] = {
      ...counts,
      csv: rel,
    };
  }

  const notExecuted = MATRIX_BACKENDS.filter((b) => !backendsExecuted.includes(b));
  return {
    task_id: featureId,
    backends_executed: [...backendsExecuted],
    backends,
    backends_not_executed: [...notExecuted],
    report: `tests/artifacts/parity/${featureId}_report.md`,
  };
}

/**
 * Prefer --snapshot path; else latest snapshot for this feature_id.
 * Matching rules (precise — no loose prefix of unrelated feature ids):
 * 1. Filename equals featureId, or `{featureId}_{hexsha}` (git short/full)
 * 2. Or JSON meta.snapshot.feature_id === featureId
 */
export function findLatestSnapshotForFeature(
  featureId: string,
  snapshotsDir: string = SNAPSHOTS_DIR
): string | null {
  if (!fs.existsSync(snapshotsDir)) return null;

  const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  // Snapshot ids: {feature_id}_{sha} where sha is hex (short or full)
  const exactNameRe = new RegExp(`^${escapeRe(featureId)}(?:_[0-9a-fA-F]+)?$`);

  const candidates: Array<{ full: string; mtime: number }> = [];
  for (const f of fs.readdirSync(snapshotsDir)) {
    if (!f.endsWith(".json")) continue;
    const base = f.slice(0, -".json".length);
    const full = path.join(snapshotsDir, f);
    let matched = exactNameRe.test(base);
    if (!matched) {
      try {
        const raw = JSON.parse(fs.readFileSync(full, "utf8")) as Snapshot;
        if (raw?.snapshot?.feature_id === featureId) matched = true;
      } catch {
        // ignore unreadable / non-snapshot JSON
      }
    }
    if (!matched) continue;
    candidates.push({ full, mtime: fs.statSync(full).mtimeMs });
  }

  candidates.sort((a, b) => b.mtime - a.mtime);
  return candidates[0]?.full ?? null;
}

function loadSnapshot(snapshotPath: string): Snapshot {
  const raw = JSON.parse(fs.readFileSync(snapshotPath, "utf8")) as Snapshot;
  if (!raw?.snapshot || !Array.isArray(raw.results)) {
    throw new Error(`Invalid snapshot shape: ${snapshotPath}`);
  }
  return raw;
}

function hasRealPerformance(perf: PerformanceDocument): boolean {
  // Real results only — not skipped/error stubs.
  return perf.status === "ok" && "snapshot" in perf && Array.isArray(perf.results);
}

function packageStatus(
  correctnessOverall: "pass" | "fail",
  hasPerf: boolean,
  perf: PerformanceDocument
): PackageStatus {
  if (correctnessOverall === "fail") return "fail";
  if (!hasPerf || perf.status !== "ok") return "partial";
  return "pass";
}

function packageKind(status: PackageStatus, gitTag: string | null): PackageKind {
  if (gitTag) return "release";
  if (status === "fail") return "failed";
  return "dev";
}

function writeTextAtomic(filePath: string, text: string): void {
  const dir = path.dirname(filePath);
  const base = path.basename(filePath);
  const tmpPath = path.join(dir, `.${base}.${process.pid}.tmp`);
  fs.writeFileSync(tmpPath, text, "utf8");
  fs.renameSync(tmpPath, filePath);
}

function buildSummaryMd(meta: MetaDocument, correctness: CorrectnessDocument, perf: PerformanceDocument): string {
  const lines: string[] = [];
  lines.push(`# Progress Package ${meta.version_id}`);
  lines.push("");
  lines.push(`- status: **${meta.status}**`);
  lines.push(`- feature_id: \`${meta.feature_id}\``);
  lines.push(`- seq: ${meta.seq}`);
  lines.push(`- label: ${meta.label}`);
  lines.push(`- git: ${meta.git_sha} (${meta.git_sha_full})`);
  lines.push(`- recorded_at: ${meta.recorded_at}`);
  lines.push(`- mathzig_version: ${meta.mathzig_version}`);
  lines.push(`- correctness: ${correctness.overall}`);
  lines.push(`- has_performance: ${meta.has_performance}`);
  lines.push(`- bench_mode: ${meta.bench_mode}`);
  lines.push(`- tier: ${meta.tier}`);
  lines.push(`- parity_backends_executed: ${meta.parity_backends_executed.join(", ") || "(none)"}`);
  lines.push("");
  lines.push("## Correctness steps");
  lines.push("");
  for (const s of correctness.steps) {
    lines.push(`- \`${s.id}\`: ${s.status}${s.duration_sec != null ? ` (${s.duration_sec}s)` : ""}`);
  }
  lines.push("");
  lines.push("## Parity");
  lines.push("");
  for (const [backend, summary] of Object.entries(correctness.parity.backends)) {
    const miss = summary.missing ? " (csv missing)" : "";
    lines.push(
      `- \`${backend}\`: pass=${summary.pass} fail=${summary.fail} skip=${summary.skip} total=${summary.total}${miss}`
    );
  }
  if (correctness.parity.backends_not_executed.length > 0) {
    lines.push(`- not executed: ${correctness.parity.backends_not_executed.join(", ")}`);
  }
  lines.push("");
  lines.push("## Performance");
  lines.push("");
  if (perf.status === "ok") {
    lines.push(`- status: ok (results=${perf.results.length}, snapshot_id=${perf.snapshot.id})`);
  } else {
    lines.push(`- status: ${perf.status}`);
    lines.push(`- reason: ${perf.reason}`);
  }
  lines.push("");
  return `${lines.join("\n")}\n`;
}

export function writePackage(opts: WritePackageOptions): WritePackageResult {
  const featureId = opts.featureId;
  const stepsPath =
    opts.stepsPath ?? path.join(RUNS_DIR, featureId, "steps.json");
  const steps = loadSteps(path.isAbsolute(stepsPath) ? stepsPath : path.resolve(ROOT, stepsPath));

  if (steps.feature_id !== featureId) {
    // Allow packaging with explicit feature_id matching steps; warn on mismatch
    console.warn(
      `write_package: steps.feature_id=${steps.feature_id} differs from --feature ${featureId}; using steps.feature_id`
    );
  }
  const fid = steps.feature_id;

  const { PROGRESS_DIR, PACKAGES_DIR } = ensureProgressDirs(opts.progressDir);
  const parityArtifactsDir = opts.parityArtifactsDir
    ? path.isAbsolute(opts.parityArtifactsDir)
      ? opts.parityArtifactsDir
      : path.resolve(ROOT, opts.parityArtifactsDir)
    : PARITY_ARTIFACTS_DIR;
  const snapshotsDir = opts.snapshotsDir
    ? path.isAbsolute(opts.snapshotsDir)
      ? opts.snapshotsDir
      : path.resolve(ROOT, opts.snapshotsDir)
    : SNAPSHOTS_DIR;

  const benchMode: BenchMode = opts.benchMode ?? "zig";
  const tier = opts.tier ?? "smoke";
  const recordedAt = opts.recordedAt ?? new Date().toISOString();
  const { short: shortSha, full: fullSha } = gitRevParse(opts.gitSha);
  const slug = slugifyFeatureId(fid);

  // Always-new seq from disk scan; retry if concurrent writer took the same version_id.
  // Also avoid reusing a seq whose directory prefix already exists under another timestamp.
  let seq = scanMaxSeq(PACKAGES_DIR) + 1;
  let versionId = buildVersionId({ seq, recordedAt, slug, shortSha });
  const seqTaken = (n: number) => {
    if (!fs.existsSync(PACKAGES_DIR)) return false;
    const prefix = `${String(n).padStart(8, "0")}__`;
    return fs.readdirSync(PACKAGES_DIR).some((name) => name.startsWith(prefix));
  };
  while (fs.existsSync(path.join(PACKAGES_DIR, versionId)) || seqTaken(seq)) {
    seq += 1;
    versionId = buildVersionId({ seq, recordedAt, slug, shortSha });
  }

  const backendsExecuted = [...steps.parity_backends];
  const { overall: correctnessOverall, correctnessSteps } = evaluateCorrectness(steps);
  const parity = buildParitySummary(fid, backendsExecuted, parityArtifactsDir);

  // Store relative csv paths under the default tree when using default parity dir;
  // for injectable test dirs, keep absolute-looking relative to that root.
  for (const [backend, summary] of Object.entries(parity.backends)) {
    if (parityArtifactsDir !== PARITY_ARTIFACTS_DIR) {
      summary.csv = path.join(parityArtifactsDir, `${fid}_${backend}.csv`);
    }
  }

  const correctness: CorrectnessDocument = {
    schema_version: 1,
    overall: correctnessOverall,
    gate_started_at: steps.started_at,
    steps: correctnessSteps,
    parity,
  };

  // Machine / env defaults
  const cpuModel = os.cpus()[0]?.model ?? "unknown";
  const osInfo = `${process.platform}-${process.arch}`;
  let machine = machineId(cpuModel, osInfo);
  let cpuCores = os.cpus().length;
  let zigVersion = "unknown";
  let bunVersion = typeof Bun !== "undefined" ? Bun.version : "unknown";
  let benchSnapshotId: string | null = null;
  let perfSourcePath: string | undefined;

  let performance: PerformanceDocument;
  if (correctnessOverall === "fail") {
    performance = {
      schema_version: 1,
      status: "skipped",
      reason: "correctness_failed",
      results: [],
    };
  } else {
    const snapPath: string | null =
      opts.snapshotPath != null && opts.snapshotPath !== ""
        ? path.isAbsolute(opts.snapshotPath)
          ? opts.snapshotPath
          : path.resolve(ROOT, opts.snapshotPath)
        : findLatestSnapshotForFeature(fid, snapshotsDir);

    if (snapPath && fs.existsSync(snapPath)) {
      try {
        const snap = loadSnapshot(snapPath);
        // Prefer snapshot machine/env metadata
        machine = snap.snapshot.machine_id || machine;
        cpuCores = snap.snapshot.cpu_cores || cpuCores;
        zigVersion = snap.snapshot.zig_version || zigVersion;
        bunVersion = snap.snapshot.bun_version || bunVersion;
        benchSnapshotId = snap.snapshot.id;
        perfSourcePath = path.relative(ROOT, snapPath);
        performance = {
          schema_version: 1,
          status: "ok",
          snapshot: snap.snapshot,
          results: snap.results,
          source_path: perfSourcePath,
        };
      } catch (err) {
        performance = {
          schema_version: 1,
          status: "error",
          reason: `snapshot_load_failed: ${err instanceof Error ? err.message : String(err)}`,
          results: [],
        };
      }
    } else {
      performance = {
        schema_version: 1,
        status: "error",
        reason: "missing_snapshot",
        results: [],
      };
    }
  }

  const hasPerf = hasRealPerformance(performance);
  const status = packageStatus(correctnessOverall, hasPerf, performance);
  const baselineFeatureId =
    opts.baselineFeatureId !== undefined ? opts.baselineFeatureId : steps.baseline_feature_id;
  const baselineVersionId = opts.baselineVersionId ?? null;
  // Automatic tag: same as feature_id from the pipeline
  //   {branch}__{UTC_time}__{short_sha}[__dirty]
  // Do NOT put this in git_tag — that field is reserved for real release tags.
  const label = fid;
  const kind = packageKind(status, null);

  const meta: MetaDocument = {
    schema_version: 1,
    version_id: versionId,
    seq,
    sort_key: versionId,
    label,
    kind,
    status,
    feature_id: fid,
    git_sha: shortSha,
    git_sha_full: fullSha,
    git_tag: null,
    recorded_at: recordedAt,
    gate_started_at: steps.started_at,
    machine_id: machine,
    cpu_model: performance.status === "ok" ? performance.snapshot.cpu_model : cpuModel,
    cpu_cores: cpuCores,
    os: performance.status === "ok" ? performance.snapshot.os : osInfo,
    zig_version: zigVersion,
    bun_version: bunVersion,
    mathzig_version: readMathzigVersion(),
    baseline_feature_id: baselineFeatureId,
    baseline_version_id: baselineVersionId,
    tier,
    bench_mode: benchMode,
    has_performance: hasPerf,
    bench_snapshot_id: benchSnapshotId,
    gate_run_dir: path.relative(ROOT, path.join(RUNS_DIR, fid)),
    parity_backends_executed: backendsExecuted,
  };

  const features: FeaturesDocument = buildFeaturesDocument({
    versionId,
    seq,
    taskId: fid,
    backendsExecuted,
    generatedAt: recordedAt,
    parityArtifactsDir,
    catalogPath: opts.catalogPath,
    casesDir: opts.casesDir,
  });

  // Auto compare vs previous package when baseline is set (no manual prep).
  // Prefer package performance.json rows (package-to-package); fall back to CSV.
  let compareDoc: PerformanceCompareDocument | null = null;
  if (opts.writeCompare === true && hasPerf && baselineFeatureId) {
    try {
      const afterRows =
        performance.status === "ok" ? performanceDocToRows(performance) : [];
      let baselineRows: ReturnType<typeof performanceDocToRows> | undefined;
      let baselineMachine: string | null = null;
      if (baselineVersionId) {
        const basePerfPath = path.join(PACKAGES_DIR, baselineVersionId, "performance.json");
        const baseMetaPath = path.join(PACKAGES_DIR, baselineVersionId, "meta.json");
        if (fs.existsSync(basePerfPath)) {
          const basePerf = JSON.parse(fs.readFileSync(basePerfPath, "utf8")) as PerformanceDocument;
          baselineRows = performanceDocToRows(basePerf);
        }
        if (fs.existsSync(baseMetaPath)) {
          try {
            const baseMeta = JSON.parse(fs.readFileSync(baseMetaPath, "utf8")) as MetaDocument;
            baselineMachine = baseMeta.machine_id ?? null;
          } catch {
            /* ignore */
          }
        }
      }
      compareDoc = comparePerformance({
        baseline_feature_id: baselineFeatureId,
        after_feature_id: fid,
        baseline_version_id: baselineVersionId,
        after_version_id: versionId,
        machine_id: machine,
        baseline_machine_id: baselineMachine,
        after_machine_id: machine,
        suite: benchMode === "all" ? "all" : benchMode === "ts" ? "ts" : "zig",
        max_regression_pct: Number(steps.max_regression_pct) || 5,
        baseline_rows: baselineRows && baselineRows.length > 0 ? baselineRows : undefined,
        after_rows: afterRows.length > 0 ? afterRows : undefined,
        allow_cross_machine: false,
      });
    } catch (err) {
      console.warn(
        `write_package: performance compare skipped: ${err instanceof Error ? err.message : String(err)}`
      );
      compareDoc = null;
    }
  }

  // Atomic publish: write into temp dir under packages/, then rename to final version_id.
  const packageDir = path.join(PACKAGES_DIR, versionId);
  const tmpDir = path.join(PACKAGES_DIR, `.tmp-${process.pid}-${seq}-${Date.now()}`);
  fs.mkdirSync(tmpDir, { recursive: true });
  try {
    writeJsonAtomic(path.join(tmpDir, "meta.json"), meta);
    writeJsonAtomic(path.join(tmpDir, "correctness.json"), correctness);
    writeJsonAtomic(path.join(tmpDir, "features.json"), features);
    writeJsonAtomic(path.join(tmpDir, "performance.json"), performance);
    if (compareDoc) {
      writeJsonAtomic(path.join(tmpDir, "performance_compare.json"), compareDoc);
    }
    writeTextAtomic(path.join(tmpDir, "summary.md"), buildSummaryMd(meta, correctness, performance));

    // Final collision check before publish
    if (fs.existsSync(packageDir)) {
      throw new Error(`package already exists (refusing overwrite): ${versionId}`);
    }
    fs.renameSync(tmpDir, packageDir);
  } catch (err) {
    try {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
    throw err;
  }

  if (opts.rebuildIndex !== false) {
    buildProgressIndex(PROGRESS_DIR);
  }

  return {
    version_id: versionId,
    seq,
    package_dir: packageDir,
    status,
    has_performance: hasPerf,
    meta,
  };
}

if (import.meta.main) {
  const opts = parseArgs(process.argv.slice(2));
  const result = writePackage(opts);
  console.log(
    JSON.stringify(
      {
        version_id: result.version_id,
        seq: result.seq,
        status: result.status,
        has_performance: result.has_performance,
        package_dir: path.relative(ROOT, result.package_dir),
      },
      null,
      2
    )
  );
}
