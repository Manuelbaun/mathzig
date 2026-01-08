import * as os from "node:os";

const taskBase = process.argv[2];
const baselineBase = process.argv[3] ?? "";
const maxRegressionPct = process.argv[4] ?? "5";
const countsArg = process.argv[5] ?? "1,2,4,8";

if (!taskBase) {
  console.error("Usage: bun tools/testing/feature_gate_matrix.ts <task_base_id> [baseline_base_id] [max_regression_pct] [thread_counts]");
  process.exit(2);
}

function parseCounts(raw: string): number[] {
  const nums = raw
    .split(",")
    .map((s) => Number(s.trim()))
    .filter((n) => Number.isFinite(n) && n > 0)
    .map((n) => Math.floor(n));
  return [...new Set(nums)].sort((a, b) => a - b);
}

const counts = parseCounts(countsArg);
if (counts.length === 0) {
  console.error("No valid thread counts. Example: 1,2,4,8");
  process.exit(2);
}

const hostCores = os.cpus().length;
console.log(`Feature gate matrix start: task_base=${taskBase}, baseline_base=${baselineBase || "(none)"}, counts=${counts.join(",")}, host_cores=${hostCores}`);

let failures = 0;
for (const n of counts) {
  const taskId = `${taskBase}_t${n}`;
  const baselineId = baselineBase ? `${baselineBase}_t${n}` : "";
  const env = {
    ...process.env,
    MATHZIG_THREADS: String(n),
    PERF_THREAD_COUNTS: String(n),
  };

  const cmd = ["bun", "tools/testing/feature_gate.ts", taskId];
  if (baselineId) cmd.push(baselineId, maxRegressionPct);

  console.log(`\n=== Running feature gate for threads=${n} (task_id=${taskId}) ===`);
  const res = Bun.spawnSync({ cmd, env, stdout: "inherit", stderr: "inherit" });
  if ((res.exitCode ?? 1) !== 0) {
    failures += 1;
    console.error(`Feature gate failed for threads=${n} (task_id=${taskId})`);
  }
}

if (failures > 0) {
  console.error(`Feature gate matrix failed: ${failures}/${counts.length} runs failed.`);
  process.exit(1);
}

console.log(`Feature gate matrix passed: ${counts.length}/${counts.length} runs passed.`);
