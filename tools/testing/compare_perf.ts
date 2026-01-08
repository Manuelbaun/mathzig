import * as fs from "node:fs";
import * as path from "node:path";

type Suite = "all" | "zig" | "ts";

type PerfRow = {
  featureId: string;
  testName: string;
  ops: number;
  opsStddev: number;
  sampleCount: number;
};

type Agg = {
  avgOps: number;
  avgStddev: number;
  avgSamples: number;
  count: number;
};

type Row = {
  testName: string;
  baselineOps: number | null;
  afterOps: number | null;
  deltaOps: number | null;
  pct: number | null;
  cvAfter: number | null;
  cls: string;
  relThreshold: number;
  absRegression: boolean;
  relRegression: boolean;
  unstable: boolean;
  status: "OK" | "REGRESSION_REL" | "REGRESSION_ABS" | "UNSTABLE" | "MISSING_AFTER" | "NEW_IN_AFTER";
};

function usage(): never {
  console.error(
    "Usage: bun tools/testing/compare_perf.ts <baseline_feature_id> <after_feature_id> [max_regression_pct] [suite]"
  );
  process.exit(2);
}

const baselineId = process.argv[2];
const afterId = process.argv[3];
const defaultRegressionPct = Number(process.argv[4] ?? "5");
const suite = (process.argv[5] ?? "all") as Suite;
if (!baselineId || !afterId) usage();
if (!Number.isFinite(defaultRegressionPct)) usage();
if (suite !== "all" && suite !== "zig" && suite !== "ts") usage();

const HOT_THRESHOLD = Number(process.env.PERF_THRESH_HOT ?? "3");
const INTEGRATION_THRESHOLD = Number(process.env.PERF_THRESH_INTEGRATION ?? "8");
const UNSTABLE_CV = Number(process.env.PERF_UNSTABLE_CV ?? "0.10");
const ABS_DROP_OPS = Number(process.env.PERF_ABS_DROP_OPS ?? "1000");

const csv = path.resolve(process.cwd(), "tests/artifacts/performance/performance_log.csv");
const outDir = path.resolve(process.cwd(), "tests/artifacts/performance");
const outMd = path.join(outDir, `${afterId}_vs_${baselineId}.md`);
if (!fs.existsSync(csv)) {
  console.error(`Missing ${path.relative(process.cwd(), csv)}`);
  process.exit(2);
}
fs.mkdirSync(outDir, { recursive: true });

const text = fs.readFileSync(csv, "utf8");
const lines = text.split(/\r?\n/).filter(Boolean);
if (lines.length < 2) {
  console.error("No perf rows found");
  process.exit(2);
}

const header = lines[0].split(",");
const idx = Object.fromEntries(header.map((h, i) => [h, i]));
const idxFeature = idx["feature_id"] ?? 1;
const idxTest = idx["test_name"] ?? 2;
const idxOpsP50 = idx["ops_p50"];
const idxOps = idx["ops_per_sec"] ?? 5;
const idxStd = idx["ops_stddev"];
const idxSamples = idx["sample_count"];

function suiteMatch(testName: string): boolean {
  if (suite === "all") return true;
  if (suite === "zig") return testName.startsWith("zig_");
  return testName.startsWith("ffi_") || testName.startsWith("native_") || testName.startsWith("ts_");
}

const rows: PerfRow[] = [];
for (let i = 1; i < lines.length; i += 1) {
  const cols = lines[i].split(",");
  const featureId = cols[idxFeature] ?? "";
  const testName = cols[idxTest] ?? "";
  if (!featureId || !testName || !suiteMatch(testName)) continue;
  const ops = Number((idxOpsP50 != null ? cols[idxOpsP50] : undefined) ?? cols[idxOps]);
  const opsStddev = Number((idxStd != null ? cols[idxStd] : undefined) ?? "0");
  const sampleCount = Number((idxSamples != null ? cols[idxSamples] : undefined) ?? "1");
  if (!Number.isFinite(ops)) continue;
  rows.push({ featureId, testName, ops, opsStddev: Number.isFinite(opsStddev) ? opsStddev : 0, sampleCount: Number.isFinite(sampleCount) ? sampleCount : 1 });
}

function aggByFeature(fid: string) {
  const map = new Map<string, Agg>();
  for (const r of rows) {
    if (r.featureId !== fid) continue;
    const prev = map.get(r.testName) ?? { avgOps: 0, avgStddev: 0, avgSamples: 0, count: 0 };
    prev.avgOps += r.ops;
    prev.avgStddev += r.opsStddev;
    prev.avgSamples += r.sampleCount;
    prev.count += 1;
    map.set(r.testName, prev);
  }
  for (const v of map.values()) {
    v.avgOps /= v.count;
    v.avgStddev /= v.count;
    v.avgSamples /= v.count;
  }
  return map;
}

function classify(testName: string): { cls: string; threshold: number } {
  const t = testName.toLowerCase();
  if (t.includes("arithmetic") || t.includes("vecdot") || t.includes("matrix") || t.includes("bench")) {
    return { cls: "hot", threshold: HOT_THRESHOLD };
  }
  if (t.includes("timeseries") || t.includes("ode") || t.includes("integration")) {
    return { cls: "integration", threshold: INTEGRATION_THRESHOLD };
  }
  return { cls: "default", threshold: defaultRegressionPct };
}

const base = aggByFeature(baselineId);
const after = aggByFeature(afterId);
const testNames = [...new Set([...base.keys(), ...after.keys()])].sort((a, b) => a.localeCompare(b));

const out: Row[] = [];
let failures = 0;
for (const testName of testNames) {
  const b = base.get(testName);
  const a = after.get(testName);
  const { cls, threshold } = classify(testName);

  if (b && !a) {
    out.push({ testName, baselineOps: b.avgOps, afterOps: null, deltaOps: null, pct: null, cvAfter: null, cls, relThreshold: threshold, absRegression: false, relRegression: false, unstable: false, status: "MISSING_AFTER" });
    continue;
  }
  if (!b && a) {
    out.push({ testName, baselineOps: null, afterOps: a.avgOps, deltaOps: null, pct: null, cvAfter: null, cls, relThreshold: threshold, absRegression: false, relRegression: false, unstable: false, status: "NEW_IN_AFTER" });
    continue;
  }
  if (!b || !a) continue;

  const deltaOps = a.avgOps - b.avgOps;
  const pct = b.avgOps === 0 ? 0 : (deltaOps / b.avgOps) * 100;
  const cvAfter = a.avgOps === 0 ? 0 : a.avgStddev / a.avgOps;
  const relRegression = pct < -threshold;
  const absRegression = deltaOps < -Math.abs(ABS_DROP_OPS);
  const unstable = a.avgSamples >= 3 && cvAfter > UNSTABLE_CV;

  let status: Row["status"] = "OK";
  if (relRegression) status = "REGRESSION_REL";
  else if (absRegression) status = "REGRESSION_ABS";
  else if (unstable) status = "UNSTABLE";

  if (status !== "OK") failures += 1;

  out.push({ testName, baselineOps: b.avgOps, afterOps: a.avgOps, deltaOps, pct, cvAfter, cls, relThreshold: threshold, absRegression, relRegression, unstable, status });
}

const md: string[] = [];
md.push("# Performance Compare");
md.push("");
md.push(`- Baseline feature_id: '${baselineId}'`);
md.push(`- After feature_id: '${afterId}'`);
md.push(`- Suite filter: '${suite}'`);
md.push(`- Class thresholds: hot=${HOT_THRESHOLD}%, integration=${INTEGRATION_THRESHOLD}%, default=${defaultRegressionPct}%`);
md.push(`- Unstable CV threshold: ${UNSTABLE_CV}`);
md.push(`- Absolute drop threshold (ops/s): ${ABS_DROP_OPS}`);
md.push("");
md.push("| Test | Class | Baseline ops/s | After ops/s | Delta ops/s | Delta % | CV(after) | Status |");
md.push("| :--- | :--- | ---: | ---: | ---: | ---: | ---: | :--- |");
for (const r of out) {
  const b = r.baselineOps == null ? "NA" : r.baselineOps.toFixed(2);
  const a = r.afterOps == null ? "NA" : r.afterOps.toFixed(2);
  const d = r.deltaOps == null ? "NA" : r.deltaOps.toFixed(2);
  const p = r.pct == null ? "NA" : `${r.pct.toFixed(2)}%`;
  const cv = r.cvAfter == null ? "NA" : r.cvAfter.toFixed(4);
  md.push(`| \`${r.testName}\` | ${r.cls} | ${b} | ${a} | ${d} | ${p} | ${cv} | ${r.status} |`);
}

fs.writeFileSync(outMd, `${md.join("\n")}\n`, "utf8");
console.log(`Wrote ${path.relative(process.cwd(), outMd)}`);

if (failures > 0) {
  console.error(`Detected ${failures} failing perf checks`);
  process.exit(1);
}
