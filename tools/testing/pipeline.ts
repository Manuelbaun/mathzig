#!/usr/bin/env bun
/**
 * MathZig single test pipeline — the only supported way to run tests.
 *
 *   bun run mz
 *
 * Always:
 *   1. Full correctness (zig → all backends parity → boundary)
 *   2. Measure all backends (zig + ts throughput + snapshot)
 *   3. Write a progress package + refresh apps/progress public data
 *
 * No feature_id / task_id arguments.
 *
 * Automatic tag (run identity, progress package label/feature_id):
 *   {branch}__{UTC_time}__{short_sha}[__dirty]
 *   e.g. main__20260710T121506Z__8e2bed8
 *
 * Progress packages are append-only under tests/artifacts/progress/packages/.
 * The dashboard reads apps/progress/public/data/ (refreshed at end of every run).
 */
import * as fs from "node:fs";
import * as path from "node:path";
import {
  type StepsDocument,
  writeJsonAtomic,
} from "./feature_gate_steps.ts";
import {
  resolveLatestBaselineVersionId,
  writeGateProgressPackage,
} from "./feature_gate_progress.ts";
import { buildAppData } from "../progress/build_app_data.ts";
import { getProgressPaths, ROOT } from "../progress/paths.ts";
import type { MetaDocument, ProgressIndex } from "../progress/types.ts";

const PARITY_BACKENDS = ["zig_vm", "ts_ffi", "ts_wasm_vm", "wasm_aot"] as const;
const BENCH_MODE = "all" as const;
const BENCH_TIER = "standard";

const BOUNDARY_GLOBS = [
  "tests/ts/parity/ffi.test.ts",
  "tests/ts/parity/ffi_boundary_minimal.test.ts",
  "tests/ts/parity/ffi_boundary_validation.test.ts",
  "tests/ts/parity/test_ffi_basic.test.ts",
  "tests/ts/parity/wasm_abi.test.ts",
  "tests/ts/parity/wasm_memory.test.ts",
  "tests/ts/parity/wasm_wrapper_batch.test.ts",
  "tests/ts/parity/test_mathzig_wasm.test.ts",
  "tests/ts/aot_abi.test.ts",
  "tests/ts/aot_abi_json.test.ts",
  "tests/ts/aot_env.test.ts",
];

type StepStatus = "PASS" | "FAIL";

function spawnText(cmd: string[]): { exit: number; stdout: string; stderr: string } {
  const res = Bun.spawnSync({
    cmd,
    cwd: ROOT,
    env: process.env,
    stdout: "pipe",
    stderr: "pipe",
  });
  return {
    exit: res.exitCode ?? 1,
    stdout: new TextDecoder().decode(res.stdout ?? new Uint8Array()),
    stderr: new TextDecoder().decode(res.stderr ?? new Uint8Array()),
  };
}

/**
 * Run a child command, streaming stdout/stderr live to the terminal while
 * also capturing a full log file. Never buffers until the end.
 */
async function spawnStreaming(
  cmd: string[],
  logPath: string,
  env?: NodeJS.ProcessEnv
): Promise<{ exit: number; durationSec: number }> {
  const started = Date.now();
  fs.mkdirSync(path.dirname(logPath), { recursive: true });
  const logFd = fs.openSync(logPath, "w");

  const proc = Bun.spawn({
    cmd,
    cwd: ROOT,
    env: { ...process.env, ...env },
    stdout: "pipe",
    stderr: "pipe",
    stdin: "inherit",
  });

  const pump = async (
    stream: ReadableStream<Uint8Array> | null,
    dest: NodeJS.WriteStream
  ): Promise<void> => {
    if (!stream) return;
    const reader = stream.getReader();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value || value.byteLength === 0) continue;
      dest.write(value);
      fs.writeSync(logFd, value);
    }
  };

  await Promise.all([
    pump(proc.stdout, process.stdout),
    pump(proc.stderr, process.stderr),
  ]);
  const exit = (await proc.exited) ?? 1;
  fs.closeSync(logFd);

  return {
    exit,
    durationSec: Math.max(0, Math.round((Date.now() - started) / 1000)),
  };
}

function phaseBanner(phase: string, title: string) {
  console.log(`\n${"═".repeat(64)}`);
  console.log(`  ${phase}  ${title}`);
  console.log(`${"═".repeat(64)}\n`);
}

function stepBanner(step: string, title: string, cmd: string[]) {
  console.log(`\n${"─".repeat(64)}`);
  console.log(`▶ [${step}] ${title}`);
  console.log(`  $ ${cmd.join(" ")}`);
  console.log(`${"─".repeat(64)}\n`);
}

function gitShortSha(): string {
  const r = spawnText(["git", "rev-parse", "--short=7", "HEAD"]);
  return (r.stdout.trim() || "unknown").replace(/[^a-zA-Z0-9]/g, "") || "unknown";
}

function gitDirty(): boolean {
  const r = spawnText(["git", "status", "--porcelain"]);
  return r.stdout.trim().length > 0;
}

/** Current branch name, or `detached` when not on a branch. */
function gitBranchName(): string {
  const r = spawnText(["git", "rev-parse", "--abbrev-ref", "HEAD"]);
  const raw = r.stdout.trim();
  if (!raw || raw === "HEAD") return "detached";
  return raw;
}

/** Filesystem-safe slug for path / CSV labels. */
function slugifyPart(raw: string, maxLen = 48): string {
  return (
    raw
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "_")
      .replace(/^_+|_+$/g, "")
      .slice(0, maxLen) || "unknown"
  );
}

/** UTC stamp: YYYYMMDDTHHMMSSZ */
function utcRunTimestamp(d: Date = new Date()): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return (
    `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}` +
    `T${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}Z`
  );
}

/**
 * Automatic tag for a full test+record run.
 *   {branch}__{time}__{hash}[__dirty]
 *
 * Used as: runs/ dir name, parity task-id, perf feature label, progress
 * package feature_id + label. Always unique (time included).
 */
export function deriveRunId(now: Date = new Date()): string {
  const branch = slugifyPart(gitBranchName());
  const time = utcRunTimestamp(now);
  const hash = gitShortSha();
  const dirty = gitDirty() ? "__dirty" : "";
  return `${branch}__${time}__${hash}${dirty}`;
}

/** Alias: automatic tag === run id. */
export const automaticTag = deriveRunId;

/** Previous progress package (highest seq), for auto-compare. */
function resolvePreviousPackage(excludeFeatureId: string): {
  feature_id: string;
  version_id: string;
} | null {
  const { INDEX_FILE, PACKAGES_DIR } = getProgressPaths();
  const candidates: Array<{ feature_id: string; version_id: string; seq: number }> = [];

  if (fs.existsSync(INDEX_FILE)) {
    try {
      const index = JSON.parse(fs.readFileSync(INDEX_FILE, "utf8")) as ProgressIndex;
      for (const p of index.packages ?? []) {
        if (p.feature_id && p.feature_id !== excludeFeatureId && p.version_id) {
          candidates.push({
            feature_id: p.feature_id,
            version_id: p.version_id,
            seq: p.seq ?? 0,
          });
        }
      }
    } catch {
      /* fall through */
    }
  }

  if (candidates.length === 0 && fs.existsSync(PACKAGES_DIR)) {
    for (const name of fs.readdirSync(PACKAGES_DIR)) {
      if (name.startsWith(".")) continue;
      const metaPath = path.join(PACKAGES_DIR, name, "meta.json");
      if (!fs.existsSync(metaPath)) continue;
      try {
        const meta = JSON.parse(fs.readFileSync(metaPath, "utf8")) as MetaDocument;
        if (meta.feature_id && meta.feature_id !== excludeFeatureId && meta.version_id) {
          candidates.push({
            feature_id: meta.feature_id,
            version_id: meta.version_id,
            seq: meta.seq ?? 0,
          });
        }
      } catch {
        /* skip */
      }
    }
  }

  if (candidates.length === 0) return null;
  candidates.sort(
    (a, b) => b.seq - a.seq || b.version_id.localeCompare(a.version_id)
  );
  return { feature_id: candidates[0]!.feature_id, version_id: candidates[0]!.version_id };
}

export type PipelineOptions = {
  /** Skip measure + snapshot (still writes correctness-only package). */
  skipMeasure?: boolean;
  /** Parity --quick (dev only; default full). */
  quick?: boolean;
  /** PERF_SAMPLES override. */
  samples?: string;
  /** PERF_WARMUP override. */
  warmup?: string;
};

export type PipelineResult = {
  runId: string;
  exitCode: number;
  correctnessOk: boolean;
  versionId: string | null;
  packageDir: string | null;
};

export async function runPipeline(opts: PipelineOptions = {}): Promise<PipelineResult> {
  const runId = deriveRunId();
  const startedAt = new Date().toISOString();
  const runDir = path.resolve(ROOT, `tests/artifacts/runs/${runId}`);
  const stepsJson = path.join(runDir, "steps.json");
  const summaryMd = path.join(runDir, "summary.md");
  fs.mkdirSync(runDir, { recursive: true });

  // Auto baseline = previous recorded package (by seq). No manual tags.
  const previousPkg = resolvePreviousPackage(runId);
  const baselineFeatureId = previousPkg?.feature_id ?? null;
  const baselineVersionId =
    previousPkg?.version_id ??
    (baselineFeatureId ? resolveLatestBaselineVersionId(baselineFeatureId) : null);

  const branchDisp = gitBranchName();
  const hashDisp = gitShortSha();
  console.log(`\n╔══════════════════════════════════════════════════════════════╗`);
  console.log(`║  MathZig test pipeline (single path)                         ║`);
  console.log(`╠══════════════════════════════════════════════════════════════╣`);
  console.log(`║  automatic tag (branch → time → hash):                       ║`);
  console.log(`║  ${runId.slice(0, 59).padEnd(59)}║`);
  console.log(
    `║  (${(branchDisp + " → UTC time → " + hashDisp).slice(0, 57).padEnd(57)})║`
  );
  console.log(`║  1 correctness → 2 measure all → 3 record progress           ║`);
  console.log(`║  live: every stage / case / measure step                     ║`);
  console.log(`╚══════════════════════════════════════════════════════════════╝\n`);

  const summary: string[] = [
    "# MathZig test run",
    "",
    `- automatic_tag: ${runId}`,
    `- run_id: ${runId}`,
    `- started_at_utc: ${startedAt}`,
    `- bench_mode: ${BENCH_MODE}`,
    `- bench_tier: ${BENCH_TIER}`,
    `- parity_backends: ${PARITY_BACKENDS.join(",")}${opts.quick ? "" : " (+wasm_aot_standalone)"}`,
    baselineFeatureId
      ? `- auto_baseline_tag: ${baselineFeatureId}`
      : "- auto_baseline_tag: none (first package or no prior runs)",
    baselineVersionId ? `- auto_baseline_version: ${baselineVersionId}` : "",
    "",
  ].filter(Boolean);

  const stepsDoc: StepsDocument = {
    schema_version: 1,
    feature_id: runId,
    started_at: startedAt,
    finished_at: null,
    baseline_feature_id: baselineFeatureId,
    baseline_source: baselineFeatureId ? "auto" : "none",
    max_regression_pct: "5",
    parity_backends: [...PARITY_BACKENDS],
    bench_mode: BENCH_MODE,
    bench_tier: BENCH_TIER,
    perf_strict: false,
    steps: [],
    final_status: null,
    artifacts: {
      parity_report: `tests/artifacts/parity/${runId}_report.md`,
      perf_log: "tests/artifacts/performance/performance_log.csv",
      perf_compare: baselineFeatureId
        ? `tests/artifacts/performance/${runId}_vs_${baselineFeatureId}.md`
        : null,
      overview: "tests/artifacts/testing_overview/latest.md",
    },
  };

  const writeSteps = () => writeJsonAtomic(stepsJson, stepsDoc);
  const writeSummary = () => fs.writeFileSync(summaryMd, `${summary.join("\n")}\n`, "utf8");
  const flush = () => {
    writeSteps();
    writeSummary();
  };

  /** Hard fail drives process exit (correctness only). */
  let exitCode = 0;
  let correctnessOk = true;

  async function runStep(
    name: string,
    title: string,
    cmd: string[],
    stepOpts?: { soft?: boolean; env?: NodeJS.ProcessEnv }
  ): Promise<boolean> {
    const soft = stepOpts?.soft === true;
    const log = path.join(runDir, `${name}.log`);

    stepBanner(name, title, cmd);

    const { exit, durationSec } = await spawnStreaming(cmd, log, stepOpts?.env);
    const ok = exit === 0;
    const status: StepStatus = ok ? "PASS" : "FAIL";
    const logRel = path.relative(ROOT, log);

    if (!ok && !soft) exitCode = 1;

    const mark = ok ? "✓ PASS" : soft ? "✗ FAIL [soft]" : "✗ FAIL";
    console.log(`\n◀ [${name}] ${mark} (${durationSec}s)`);
    console.log(`  log: ${logRel}\n`);

    summary.push(`## ${name}`, "");
    summary.push(`- title: ${title}`);
    summary.push(`- status: ${status}`);
    if (soft && !ok) summary.push("- soft_fail: true (does not fail pipeline exit)");
    summary.push(`- duration_sec: ${durationSec}`);
    summary.push(`- command: \`${cmd.join(" ")}\``);
    summary.push(`- log: ${logRel}`);
    summary.push("");

    stepsDoc.steps.push({
      id: name,
      status: ok ? "pass" : "fail",
      duration_sec: durationSec,
      command: cmd,
      log: logRel,
      reason: null,
    });
    flush();
    return ok;
  }

  function skipStep(name: string, reason: string) {
    console.log(`\n○ [${name}] SKIP — ${reason}\n`);
    summary.push(`## ${name}`, "");
    summary.push("- status: SKIPPED");
    summary.push(`- reason: ${reason}`);
    summary.push("");
    stepsDoc.steps.push({
      id: name,
      status: "skipped",
      duration_sec: null,
      command: null,
      log: null,
      reason,
    });
    flush();
  }

  flush();

  // ─── 1. Correctness (hard fail) ───────────────────────────────────────────
  phaseBanner("1/3", "CORRECTNESS — right answers (zig → boundary → all backends)");

  if (
    !(await runStep(
      "zig_vm_baseline",
      "Zig VM baseline (must-pass core)",
      ["zig", "build", "vm-baseline", "--summary", "all"]
    ))
  ) {
    correctnessOk = false;
  }
  if (correctnessOk) {
    if (
      !(await runStep(
        "zig_tests",
        "Zig unit / integration tests (each suite live below)",
        ["zig", "build", "test", "--summary", "all"]
      ))
    ) {
      correctnessOk = false;
    }
  } else {
    skipStep("zig_tests", "zig_vm_baseline failed");
  }

  // Focused boundary / host glue (step id ts_tests matches progress package contract)
  if (correctnessOk) {
    const existing = BOUNDARY_GLOBS.filter((g) => fs.existsSync(path.resolve(ROOT, g)));
    if (existing.length === 0) {
      skipStep("ts_tests", "no boundary test files found");
    } else if (
      !(await runStep(
        "ts_tests",
        "TS boundary harness (FFI / WASM / AOT env) — each test case live",
        ["bun", "test", ...existing]
      ))
    ) {
      correctnessOk = false;
    }
  } else {
    skipStep("ts_tests", "zig correctness failed");
  }

  // Specs task-12: full bun suite under known_failures.json quarantine
  if (correctnessOk) {
    if (
      !(await runStep(
        "strict_bun",
        "Strict bun gate (0 unexpected fail/pass vs tests/known_failures.json)",
        ["bun", "tools/testing/strict_bun_gate.ts"]
      ))
    ) {
      correctnessOk = false;
    }
  } else {
    skipStep("strict_bun", "earlier correctness failed");
  }

  // One parity run → all backends → CSVs named {runId}_{backend}.csv
  // Full (non-quick): also --standalone so wasm_aot_standalone runs and
  // standalone_skip_budget from known_failures.json is enforced (task-12).
  if (correctnessOk) {
    const parityCmd = [
      "bun",
      "tests/parity/cli.ts",
      `--task-id=${runId}`,
      opts.quick ? "--quick" : "--full",
      `--backends=${PARITY_BACKENDS.join(",")}`,
      "--verbose",
    ];
    if (!opts.quick) {
      parityCmd.push("--standalone");
    }
    const parityLabel = opts.quick
      ? "Parity JSON cases × host backends (quick; no standalone)"
      : "Parity JSON cases × host backends + wasm_aot_standalone (budget enforced)";
    if (!(await runStep("parity_full", parityLabel, parityCmd))) {
      correctnessOk = false;
    }
  } else {
    skipStep("parity_full", "earlier correctness failed");
  }

  // task-17 / C6: Playwright chromium smoke for web/graph_demo.html
  // Tag class: smoke (like soak) — full protocol only; skipped on --quick.
  if (opts.quick) {
    skipStep("browser_smoke", "--quick (smoke/soak excluded from quick gate)");
  } else if (correctnessOk) {
    if (
      !(await runStep(
        "browser_smoke",
        "Playwright chromium smoke — web/graph_demo.html (real /api/aot_compile demo)",
        ["bun", "tests/browser/graph_demo.smoke.ts"]
      ))
    ) {
      correctnessOk = false;
    }
  } else {
    skipStep("browser_smoke", "earlier correctness failed");
  }

  // Graph tick tripwire vs docs/reference/graph_tick_baseline.md
  // Fail if any tracked multi ns/tick regresses >30%. Full protocol only.
  if (opts.quick) {
    skipStep("graph_perf_tripwire", "--quick (tripwire excluded from quick gate)");
  } else if (correctnessOk) {
    if (
      !(await runStep(
        "graph_perf_tripwire",
        "Graph tick perf tripwire vs task-10 results.md (>30% ns/tick = fail)",
        ["bun", "tools/testing/graph_perf_tripwire.ts"]
      ))
    ) {
      correctnessOk = false;
    }
  } else {
    skipStep("graph_perf_tripwire", "earlier correctness failed");
  }

  // task-16 / C5: graph soak (handle flatness + reload). Tag class: soak.
  // Default CI-friendly counts (50k ticks / 2k reloads); deep: MATHZIG_SOAK_FULL=1.
  if (opts.quick) {
    skipStep("graph_soak", "--quick (smoke/soak excluded from quick gate)");
  } else if (correctnessOk) {
    if (
      !(await runStep(
        "graph_soak",
        "Graph soak — series+matrix ticks + reload (task-16; MATHZIG_SOAK_FULL=1 for 1M/10k)",
        ["bun", "tests/soak/graph_soak.ts"]
      ))
    ) {
      correctnessOk = false;
    }
  } else {
    skipStep("graph_soak", "earlier correctness failed");
  }

  // ─── 2. Measure all backends (soft; still recorded) ───────────────────────
  phaseBanner("2/3", "MEASURE — throughput (ops/s) on all backends");

  const perfEnv: NodeJS.ProcessEnv = { ...process.env };
  if (opts.samples) perfEnv.PERF_SAMPLES = opts.samples;
  if (opts.warmup) perfEnv.PERF_WARMUP = opts.warmup;

  if (opts.skipMeasure) {
    skipStep("perf_all_record", "--skip-measure");
  } else if (!correctnessOk) {
    skipStep("perf_all_record", "correctness failed — not measuring");
  } else {
    await runStep(
      "perf_all_record",
      "Record perf + snapshot (zig + ts; each bench step live)",
      [
        "bun",
        "tools/bench/run.ts",
        "--feature",
        runId,
        "--mode",
        BENCH_MODE,
        "--tier",
        BENCH_TIER,
      ],
      { soft: true, env: perfEnv }
    );
  }

  if (correctnessOk && baselineFeatureId && !opts.skipMeasure) {
    await runStep(
      "perf_compare",
      `Compare perf vs previous run (${baselineFeatureId})`,
      ["bun", "tools/testing/compare_perf.ts", baselineFeatureId, runId, "5", "all"],
      { soft: true }
    );
  } else if (baselineFeatureId) {
    skipStep(
      "perf_compare",
      !correctnessOk ? "correctness failed" : "no previous run or skipped measure"
    );
  }

  // ─── 3. Always record progress + dashboard data ───────────────────────────
  phaseBanner("3/3", "RECORD — progress package + dashboard data");

  stepsDoc.finished_at = new Date().toISOString();
  stepsDoc.final_status = correctnessOk ? "pass" : "fail";
  flush();

  let versionId: string | null = null;
  let packageDir: string | null = null;

  console.log(`▶ [progress_package] write version package from this run`);
  const pkgResult = writeGateProgressPackage({
    featureId: runId,
    stepsPath: stepsJson,
    baselineFeatureId,
    benchMode: BENCH_MODE,
    tier: BENCH_TIER,
  });

  if (pkgResult.ok && !pkgResult.skipped && pkgResult.versionId) {
    versionId = pkgResult.versionId;
    packageDir = pkgResult.packageDir;
    console.log(
      `✓ [progress_package] ${versionId}\n  → ${packageDir ? path.relative(ROOT, packageDir) : "?"}`
    );
    if (baselineVersionId) {
      console.log(`  baseline package: ${baselineVersionId}`);
    }
    summary.push("## progress_package", "");
    summary.push(`- status: PASS`);
    summary.push(`- version_id: ${versionId}`);
    if (packageDir) summary.push(`- package: ${path.relative(ROOT, packageDir)}`);
    summary.push("");
    stepsDoc.steps.push({
      id: "progress_package",
      status: "pass",
      duration_sec: pkgResult.durationSec,
      command: ["writePackage", runId],
      log: null,
      reason: null,
    });
  } else if (pkgResult.skipped) {
    console.warn(`○ [progress_package] SKIP — ${pkgResult.skipReason}`);
    summary.push("## progress_package", "", `- status: SKIPPED`, `- reason: ${pkgResult.skipReason}`, "");
    stepsDoc.steps.push({
      id: "progress_package",
      status: "skipped",
      duration_sec: null,
      command: null,
      log: null,
      reason: pkgResult.skipReason,
    });
  } else {
    console.error(`✗ [progress_package] FAIL — ${pkgResult.errorMessage}`);
    summary.push(
      "## progress_package",
      "",
      `- status: FAIL`,
      `- error: ${pkgResult.errorMessage}`,
      ""
    );
    stepsDoc.steps.push({
      id: "progress_package",
      status: "fail",
      duration_sec: pkgResult.durationSec,
      command: ["writePackage", runId],
      log: null,
      reason: null,
    });
  }
  flush();

  // Always refresh dashboard static data (index, packages, series, latest_compare)
  console.log(`▶ [dashboard_data] rebuild apps/progress/public/data (fully automated)`);
  try {
    const app = buildAppData({ quiet: false });
    console.log(
      `✓ [dashboard_data] ${path.relative(ROOT, app.outDir)} (${app.package_count} packages)`
    );
    console.log(`  includes: index, packages, series, features_latest, latest_compare`);
    summary.push("## dashboard_data", "");
    summary.push(`- packages: ${app.package_count}`);
    summary.push(`- out: ${path.relative(ROOT, app.outDir)}`);
    summary.push(`- latest_compare: apps/progress/public/data/latest_compare.json`);
    summary.push("");
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`✗ [dashboard_data] FAIL — ${msg}`);
    summary.push("## dashboard_data", "", `- status: FAIL`, `- error: ${msg}`, "");
  }

  stepsDoc.finished_at = new Date().toISOString();
  stepsDoc.final_status = correctnessOk ? "pass" : "fail";
  summary.push("## Final Status", "", correctnessOk ? "PASS" : "FAIL", "");
  flush();

  console.log(`\n╔══════════════════════════════════════════════════════════════╗`);
  console.log(
    `║  ${correctnessOk ? "PASS" : "FAIL"}  correctness=${correctnessOk ? "ok" : "failed"}`.padEnd(63) + "║"
  );
  if (versionId) {
    console.log(`║  package: ${versionId.slice(0, 48).padEnd(48)}║`);
  }
  console.log(`║  auto tag: ${runId.slice(0, 51).padEnd(51)}║`);
  if (baselineFeatureId) {
    console.log(`║  vs:       ${baselineFeatureId.slice(0, 51).padEnd(51)}║`);
  }
  console.log(`║  data:     apps/progress/public/data/ (ready)                ║`);
  console.log(`╚══════════════════════════════════════════════════════════════╝\n`);
  console.log(`No manual prep. Open dashboard:\n  cd apps/progress && bun run dev\n`);
  console.log(`  → Overview / Versions / Trends / Regressions (auto latest vs previous)\n`);

  return {
    runId,
    exitCode: correctnessOk ? 0 : exitCode || 1,
    correctnessOk,
    versionId,
    packageDir,
  };
}

if (import.meta.main) {
  // Optional flags only — never feature/task ids
  const argv = process.argv.slice(2);
  const opts: PipelineOptions = {};
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--skip-measure") opts.skipMeasure = true;
    else if (a === "--quick" || a === "-q") opts.quick = true;
    else if (a === "--samples") opts.samples = argv[++i];
    else if (a === "--warmup") opts.warmup = argv[++i];
    else if (a === "--help" || a === "-h") {
      console.log(`MathZig single test pipeline

  bun run mz
  bun tools/testing/pipeline.ts

Options (optional):
  --quick          parity quick set (default: full); also skips browser_smoke + graph_perf_tripwire + graph_soak
  --skip-measure   correctness + package only (still runs smoke/tripwire/soak on full)
  --samples <n>    PERF_SAMPLES
  --warmup <n>     PERF_WARMUP

Full protocol also runs (task-17 + task-16):
  browser_smoke         bun tests/browser/graph_demo.smoke.ts
  graph_perf_tripwire   bun tools/testing/graph_perf_tripwire.ts  (>30% vs results.md)
  graph_soak            bun tests/soak/graph_soak.ts  (MATHZIG_SOAK_FULL=1 → 1M ticks + 10k reloads)

No feature_id or task_id.
Identity = {branch}__{UTC_time}__{short_sha}[__dirty]
Always records progress for the dashboard.
Live: every stage, each parity case, each measure step.
`);
      process.exit(0);
    } else if (a.startsWith("-")) {
      console.error(`Unknown flag: ${a} (no feature/task ids — see --help)`);
      process.exit(2);
    } else {
      console.error(
        `Unexpected argument "${a}".\n` +
          `This pipeline takes no feature/task id — just: bun run mz`
      );
      process.exit(2);
    }
  }

  const result = await runPipeline(opts);
  process.exit(result.exitCode);
}
