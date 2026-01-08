/**
 * LEGACY multi-option feature gate (requires feature_id).
 *
 * Daily path is now: `bun run mz` → tools/testing/pipeline.ts
 * (no feature/task ids; always all backends; always records progress).
 *
 * Keep this file for existing scripts/tests that still call it explicitly.
 * Prefer pipeline.ts for all new work.
 *
 * Env (bench / soft-perf / progress policy):
 * - FEATURE_GATE_BENCH_MODE  default `zig`  (allowed: zig | ts | all)
 * - FEATURE_GATE_BENCH_TIER  default `smoke` (label only)
 * - PERF_STRICT              default off
 * - PROGRESS_DISABLE         default off
 * - PROGRESS_REFRESH_APP     default off
 * - FEATURE_GATE_PARITY_BACKENDS  default zig_vm,ts_ffi
 */
import * as fs from "node:fs";
import * as path from "node:path";
import {
  type BaselineSource,
  type BenchMode,
  type StepsDocument,
  writeJsonAtomic,
} from "./feature_gate_steps.ts";
import {
  maybeRefreshProgressApp,
  writeGateProgressPackage,
} from "./feature_gate_progress.ts";

type StepResult = "PASS" | "FAIL";

const featureId = process.argv[2];
let baselineId = process.argv[3] ?? "";
const maxRegressionPct = process.argv[4] ?? "5";
const parityBackends = (process.env.FEATURE_GATE_PARITY_BACKENDS ?? "zig_vm,ts_ffi")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

function parseBenchMode(raw: string | undefined): BenchMode {
  const v = (raw ?? "zig").trim().toLowerCase();
  if (v === "zig" || v === "ts" || v === "all") return v;
  console.error(
    `Invalid FEATURE_GATE_BENCH_MODE=${JSON.stringify(raw)}; allowed: zig | ts | all`
  );
  process.exit(2);
}

function parsePerfStrict(raw: string | undefined): boolean {
  if (raw === undefined || raw === "") return false;
  const v = raw.trim().toLowerCase();
  return v === "1" || v === "true" || v === "yes" || v === "on";
}

/** Bench capture mode after correctness (default zig — same cost class as today's gate). */
const benchMode = parseBenchMode(process.env.FEATURE_GATE_BENCH_MODE);
/**
 * Tier label only (default smoke). Not used to filter benches yet — still full
 * record_performance for the selected mode. Real filtering is a later PR.
 */
const benchTier = (process.env.FEATURE_GATE_BENCH_TIER ?? "smoke").trim() || "smoke";
/** When false (default), post-correctness step failures do not fail the gate exit code. */
const perfStrict = parsePerfStrict(process.env.PERF_STRICT);

if (!featureId || process.argv.length > 5) {
  console.error(
    "Usage: bun tools/testing/feature_gate.ts <feature_id> [baseline_feature_id] [max_regression_pct]"
  );
  process.exit(2);
}

const runDir = path.resolve(process.cwd(), `tests/artifacts/runs/${featureId}`);
const summaryMd = path.join(runDir, "summary.md");
const stepsJson = path.join(runDir, "steps.json");
fs.mkdirSync(runDir, { recursive: true });

/** Process exit status: set only by correctness (always) and soft steps when PERF_STRICT. */
let status = 0;
/** Post-correctness soft fails (for summary note; steps still status=fail with reason null). */
const softFailedStepIds: string[] = [];
const startedAt = new Date().toISOString();

const summary: string[] = [];
summary.push("# Feature Test Gate", "");
summary.push(`- feature_id: ${featureId}`);
summary.push(`- started_at_utc: ${startedAt}`);
summary.push(`- bench_mode: ${benchMode}`);
summary.push(`- bench_tier: ${benchTier} (label only; not filtered yet)`);
summary.push(`- perf_strict: ${perfStrict ? "on" : "off"}`, "");

function detectAutoBaseline(excludeId: string): string | null {
  const runsRoot = path.resolve(process.cwd(), "tests/artifacts/runs");
  if (!fs.existsSync(runsRoot)) return null;

  const candidates = fs
    .readdirSync(runsRoot, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .filter((id) => id !== excludeId)
    .map((id) => {
      const summaryPath = path.join(runsRoot, id, "summary.md");
      if (!fs.existsSync(summaryPath)) return null;
      const text = fs.readFileSync(summaryPath, "utf8");
      if (!text.includes("## Final Status") || !text.includes("\nPASS")) return null;
      const mtimeMs = fs.statSync(summaryPath).mtimeMs;
      return { id, mtimeMs };
    })
    .filter((x): x is { id: string; mtimeMs: number } => x !== null)
    .sort((a, b) => b.mtimeMs - a.mtimeMs);

  return candidates[0]?.id ?? null;
}

let baselineSource: BaselineSource = "none";
if (baselineId) {
  baselineSource = "explicit";
} else {
  const auto = detectAutoBaseline(featureId);
  if (auto) {
    baselineId = auto;
    baselineSource = "auto";
  }
}

if (baselineId) {
  summary.push(`- baseline_feature_id: ${baselineId}`);
  summary.push(`- baseline_source: ${baselineSource}`);
  summary.push(`- max_regression_pct: ${maxRegressionPct}`);
} else {
  summary.push("- baseline_feature_id: none");
  summary.push("- baseline_source: none");
}

const stepsDoc: StepsDocument = {
  schema_version: 1,
  feature_id: featureId,
  started_at: startedAt,
  finished_at: null,
  baseline_feature_id: baselineId || null,
  baseline_source: baselineSource,
  max_regression_pct: maxRegressionPct,
  parity_backends: parityBackends,
  bench_mode: benchMode,
  bench_tier: benchTier,
  perf_strict: perfStrict,
  steps: [],
  final_status: null,
  artifacts: {
    parity_report: `tests/artifacts/parity/${featureId}_report.md`,
    perf_log: "tests/artifacts/performance/performance_log.csv",
    perf_compare: baselineId
      ? `tests/artifacts/performance/${featureId}_vs_${baselineId}.md`
      : null,
    overview: "tests/artifacts/testing_overview/latest.md",
  },
};

function writeSummary() {
  fs.writeFileSync(summaryMd, `${summary.join("\n")}\n`, "utf8");
}

function writeSteps() {
  writeJsonAtomic(stepsJson, stepsDoc);
}

function writeOutputs() {
  writeSummary();
  writeSteps();
}

/**
 * @param soft When true, a non-zero child exit does not set process status unless PERF_STRICT.
 *             Soft is for post-correctness steps (perf, compare, overview).
 */
function runStep(name: string, cmd: string[], opts?: { soft?: boolean }): boolean {
  const soft = opts?.soft === true;
  const log = path.join(runDir, `${name}.log`);
  const started = Date.now();

  const res = Bun.spawnSync({
    cmd,
    stdout: "pipe",
    stderr: "pipe",
  });

  const output = `${new TextDecoder().decode(res.stdout ?? new Uint8Array())}${new TextDecoder().decode(res.stderr ?? new Uint8Array())}`;
  fs.writeFileSync(log, output, "utf8");

  const stepStatus: StepResult = res.exitCode === 0 ? "PASS" : "FAIL";
  const softFail = stepStatus === "FAIL" && soft && !perfStrict;
  if (stepStatus === "FAIL" && !softFail) {
    status = 1;
  }
  if (softFail) softFailedStepIds.push(name);

  const durationSec = Math.max(0, Math.round((Date.now() - started) / 1000));
  const logRel = path.relative(process.cwd(), log);

  summary.push(`## ${name}`, "");
  summary.push(`- status: ${stepStatus}`);
  if (softFail) {
    summary.push("- soft_fail: true (PERF_STRICT off; does not fail gate exit)");
    console.warn(`[feature_gate] soft fail: ${name} (PERF_STRICT off; exit still based on correctness)`);
  }
  summary.push(`- duration_sec: ${durationSec}`);
  summary.push(`- command: \`${cmd.join(" ")}\``);
  summary.push(`- log: ${logRel}`);
  summary.push("");

  // pass/fail steps always have reason: null (schema); soft-fail is exit-policy only.
  stepsDoc.steps.push({
    id: name,
    status: stepStatus === "PASS" ? "pass" : "fail",
    duration_sec: durationSec,
    command: cmd,
    log: logRel,
    reason: null,
  });
  writeOutputs();

  return stepStatus === "PASS";
}

function appendSkipped(name: string, reason: string) {
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
  writeOutputs();
}

/**
 * Soft progress package step: never changes gate exit status.
 * Prefer library writePackage over re-spawning for efficiency.
 */
function recordProgressPackageStep(): string | null {
  // Finalize steps.json so writePackage sees complete gate outcome.
  stepsDoc.finished_at = new Date().toISOString();
  stepsDoc.final_status = status === 0 ? "pass" : "fail";
  writeSteps();

  const log = path.join(runDir, "progress_package.log");
  const logRel = path.relative(process.cwd(), log);
  const cmdLabel = [
    "writePackage",
    `--feature ${featureId}`,
    baselineId ? `--baseline-feature ${baselineId}` : null,
    `--bench-mode ${benchMode}`,
    `--tier ${benchTier}`,
    baselineId ? "--compare" : null,
  ]
    .filter(Boolean)
    .join(" ");

  const result = writeGateProgressPackage({
    featureId,
    stepsPath: stepsJson,
    baselineFeatureId: baselineId || null,
    benchMode,
    tier: benchTier,
  });

  if (result.skipped) {
    const reason = result.skipReason ?? "PROGRESS_DISABLE set";
    console.log(`[feature_gate] progress package skipped: ${reason}`);
    fs.writeFileSync(log, `skipped: ${reason}\n`, "utf8");
    summary.push("## progress_package", "");
    summary.push("- status: SKIPPED");
    summary.push(`- reason: ${reason}`);
    summary.push(`- soft_fail: true (never fails gate exit)`);
    summary.push("");
    stepsDoc.steps.push({
      id: "progress_package",
      status: "skipped",
      duration_sec: null,
      command: null,
      log: null,
      reason,
    });
    writeOutputs();
    return null;
  }

  const lines: string[] = [];
  if (result.ok) {
    lines.push(`ok: true`);
    lines.push(`version_id: ${result.versionId}`);
    lines.push(`package_dir: ${result.packageDir}`);
    if (result.baselineVersionId) {
      lines.push(`baseline_version_id: ${result.baselineVersionId}`);
    } else if (baselineId) {
      lines.push(`baseline_version_id: null (no package found for baseline feature)`);
    }
    console.log(
      `[feature_gate] wrote progress package ${result.versionId} → ${path.relative(process.cwd(), result.packageDir!)}`
    );
  } else {
    lines.push(`ok: false`);
    lines.push(`error: ${result.errorMessage}`);
    console.error(
      `[feature_gate] progress package write failed (soft): ${result.errorMessage}`
    );
    softFailedStepIds.push("progress_package");
  }
  fs.writeFileSync(log, `${lines.join("\n")}\n`, "utf8");

  const stepStatus: StepResult = result.ok ? "PASS" : "FAIL";
  summary.push("## progress_package", "");
  summary.push(`- status: ${stepStatus}`);
  summary.push("- soft_fail: true (never fails gate exit)");
  summary.push(`- duration_sec: ${result.durationSec}`);
  summary.push(`- command: \`${cmdLabel}\``);
  summary.push(`- log: ${logRel}`);
  if (result.ok && result.packageDir) {
    summary.push(`- package: ${path.relative(process.cwd(), result.packageDir)}`);
  }
  summary.push("");

  stepsDoc.steps.push({
    id: "progress_package",
    status: result.ok ? "pass" : "fail",
    duration_sec: result.durationSec,
    command: ["bun", "tools/progress/write_package.ts", "--feature", featureId],
    log: logRel,
    reason: null,
  });
  writeOutputs();

  return result.ok && result.packageDir
    ? path.relative(process.cwd(), result.packageDir)
    : null;
}

writeOutputs();

/** Tracks correctness outcomes separately from overall process status / soft perf fails. */
let correctnessOk = true;

// --- Correctness (always hard-fail the gate) ---
if (!runStep("zig_vm_baseline", ["zig", "build", "vm-baseline", "--summary", "all"])) correctnessOk = false;
if (!runStep("zig_tests", ["zig", "build", "test", "--summary", "all"])) correctnessOk = false;
if (!runStep("ts_tests", ["bun", "test"])) correctnessOk = false;
const parityCmd = [
  "bun",
  "tests/parity/cli.ts",
  `--task-id=${featureId}`,
  "--full",
  `--backends=${parityBackends.join(",")}`,
];
if (!runStep("parity_full", parityCmd)) correctnessOk = false;

// Mode-aware step id: perf_zig_record | perf_ts_record | perf_all_record
const perfRecordStepId = `perf_${benchMode}_record`;

if (correctnessOk) {
  // Soft unless PERF_STRICT: infra/regression noise must not block day-to-day work.
  runStep(
    perfRecordStepId,
    ["bun", "tests/performance/record_performance.ts", featureId, benchMode],
    { soft: true }
  );

  if (baselineId) {
    runStep(
      "parity_compare",
      ["bun", "tools/testing/compare_parity.ts", baselineId, featureId],
      { soft: true }
    );
    // Suite matches bench mode so compare filters the same backend set that was recorded.
    runStep(
      "perf_compare",
      [
        "bun",
        "tools/testing/compare_perf.ts",
        baselineId,
        featureId,
        maxRegressionPct,
        benchMode,
      ],
      { soft: true }
    );
  }
} else {
  appendSkipped(perfRecordStepId, "correctness gate failed (baseline/zig/ts/parity)");
  if (baselineId) {
    appendSkipped("parity_compare", "correctness gate failed (baseline/zig/ts/parity)");
    appendSkipped("perf_compare", "correctness gate failed (baseline/zig/ts/parity)");
  }
}

// Overview is post-correctness: soft unless PERF_STRICT (prefer not blocking on overview alone).
runStep("testing_overview", ["bun", "tools/testing/testing_overview.ts"], { soft: true });

// Always attempt progress package after gate steps (unless PROGRESS_DISABLE). Soft; never fails exit.
const progressPackageRel = recordProgressPackageStep();

// Optional stub: rebuild index only until apps/progress exists.
const refresh = maybeRefreshProgressApp(process.env);
if (refresh.ran) {
  if (refresh.ok) {
    console.log(`[feature_gate] PROGRESS_REFRESH_APP: ${refresh.message}`);
  } else {
    console.warn(`[feature_gate] PROGRESS_REFRESH_APP soft fail: ${refresh.message}`);
  }
}

summary.push("## Artifacts", "");
summary.push(`- parity report: tests/artifacts/parity/${featureId}_report.md`);
summary.push("- perf log: tests/artifacts/performance/performance_log.csv");
if (baselineId) {
  summary.push(`- perf compare: tests/artifacts/performance/${featureId}_vs_${baselineId}.md`);
}
summary.push("- overview: tests/artifacts/testing_overview/latest.md");
if (progressPackageRel) {
  summary.push(`- progress package: ${progressPackageRel}`);
} else {
  summary.push("- progress package: (skipped or write failed; see progress_package step)");
}
summary.push("");
summary.push("## Final Status", "");
summary.push(status === 0 ? "PASS" : "FAIL");
if (!correctnessOk) {
  summary.push("");
  summary.push("_Exit driven by correctness failure._");
} else if (status === 0 && softFailedStepIds.length > 0) {
  summary.push("");
  summary.push(
    `_Correctness passed; soft post-correctness fails (${softFailedStepIds.join(", ")}) ignored (PERF_STRICT off / progress always soft)._`
  );
}

stepsDoc.finished_at = new Date().toISOString();
stepsDoc.final_status = status === 0 ? "pass" : "fail";
writeOutputs();

console.log(`Wrote ${path.relative(process.cwd(), summaryMd)}`);
console.log(`Wrote ${path.relative(process.cwd(), stepsJson)}`);
process.exit(status);
