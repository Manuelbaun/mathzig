import * as fs from "node:fs";
import * as path from "node:path";

type BackendName = "zig_vm" | "ts_ffi" | "ts_wasm_vm" | "wasm_aot";

type ParityCase = {
  id: string;
  expr: string;
  skip?: string[];
};

type CsvCounts = {
  pass: number;
  fail: number;
  skip: number;
  total: number;
};

type PerfRow = {
  timestamp: number;
  featureId: string;
  testName: string;
  opsPerSec: number;
};

const ROOT = process.cwd();
const BACKENDS: BackendName[] = ["zig_vm", "ts_ffi", "ts_wasm_vm", "wasm_aot"];
const CASES_DIR = path.resolve(ROOT, "tests/parity/cases");
const PARITY_ARTIFACTS_DIR = path.resolve(ROOT, "tests/artifacts/parity");
const PERF_LOG = path.resolve(ROOT, "tests/artifacts/performance/performance_log.csv");
const OUT_DIR = path.resolve(ROOT, "tests/artifacts/testing_overview");
const OUT_MD = path.join(OUT_DIR, "latest.md");
const OUT_JSON = path.join(OUT_DIR, "latest.json");

function main() {
  const parityCoverage = summarizeParityCoverage();
  const latestParity = summarizeLatestParityRun();
  const perf = summarizePerf();
  const tests = summarizeTestFiles();

  const data = {
    generatedAtIso: new Date().toISOString(),
    tests,
    parityCoverage,
    latestParity,
    perf,
  };

  const md = toMarkdown(data);
  ensureDir(OUT_DIR);
  fs.writeFileSync(OUT_MD, md, "utf8");
  fs.writeFileSync(OUT_JSON, `${JSON.stringify(data, null, 2)}\n`, "utf8");

  console.log(`Wrote ${path.relative(ROOT, OUT_MD)}`);
  console.log(`Wrote ${path.relative(ROOT, OUT_JSON)}`);
}

function summarizeTestFiles() {
  const zigTests = countFiles(path.resolve(ROOT, "tests/zig"), (f) =>
    f.endsWith(".test.zig")
  );
  const tsTests = countFiles(path.resolve(ROOT, "tests/ts"), (f) =>
    f.endsWith(".test.ts")
  );

  return {
    zigTestFiles: zigTests,
    tsTestFiles: tsTests,
    parityCaseFiles: countFiles(CASES_DIR, (f) => f.endsWith(".json")),
  };
}

function summarizeParityCoverage() {
  const files = safeList(CASES_DIR).filter((f) => f.endsWith(".json")).sort();
  let totalCases = 0;
  const backendRunnable: Record<BackendName, number> = {
    zig_vm: 0,
    ts_ffi: 0,
    ts_wasm_vm: 0,
    wasm_aot: 0,
  };
  const backendSkipped: Record<BackendName, number> = {
    zig_vm: 0,
    ts_ffi: 0,
    ts_wasm_vm: 0,
    wasm_aot: 0,
  };
  const perFile: Array<{
    file: string;
    cases: number;
    runnable: Record<BackendName, number>;
    skipped: Record<BackendName, number>;
  }> = [];

  for (const file of files) {
    const full = path.join(CASES_DIR, file);
    const raw = JSON.parse(fs.readFileSync(full, "utf8"));
    if (!Array.isArray(raw)) continue;
    const cases = raw as ParityCase[];
    totalCases += cases.length;

    const fileRun: Record<BackendName, number> = {
      zig_vm: 0,
      ts_ffi: 0,
      ts_wasm_vm: 0,
      wasm_aot: 0,
    };
    const fileSkip: Record<BackendName, number> = {
      zig_vm: 0,
      ts_ffi: 0,
      ts_wasm_vm: 0,
      wasm_aot: 0,
    };

    for (const c of cases) {
      const skipSet = new Set(c.skip ?? []);
      for (const backend of BACKENDS) {
        if (skipSet.has(backend)) {
          backendSkipped[backend] += 1;
          fileSkip[backend] += 1;
        } else {
          backendRunnable[backend] += 1;
          fileRun[backend] += 1;
        }
      }
    }

    perFile.push({
      file,
      cases: cases.length,
      runnable: fileRun,
      skipped: fileSkip,
    });
  }

  return { totalCases, backendRunnable, backendSkipped, perFile };
}

function summarizeLatestParityRun() {
  const reports = safeList(PARITY_ARTIFACTS_DIR)
    .filter((f) => f.endsWith("_report.md"))
    .map((f) => ({
      file: f,
      full: path.join(PARITY_ARTIFACTS_DIR, f),
      mtimeMs: fs.statSync(path.join(PARITY_ARTIFACTS_DIR, f)).mtimeMs,
    }))
    .sort((a, b) => b.mtimeMs - a.mtimeMs);

  if (reports.length === 0) {
    return {
      taskId: null,
      reportFile: null,
      byBackend: {},
    };
  }

  for (const latest of reports) {
    const taskId = latest.file.replace(/_report\.md$/, "");
    const byBackend: Record<string, CsvCounts> = {};
    let foundCsv = false;

    for (const backend of BACKENDS) {
      const csv = path.join(PARITY_ARTIFACTS_DIR, `${taskId}_${backend}.csv`);
      if (!fs.existsSync(csv)) continue;
      foundCsv = true;
      byBackend[backend] = summarizeParityCsv(csv);
    }

    if (!foundCsv) {
      continue;
    }

    return {
      taskId,
      reportFile: latest.file,
      byBackend,
    };
  }

  return {
    taskId: null,
    reportFile: null,
    byBackend: {},
  };
}

function summarizeParityCsv(csvPath: string): CsvCounts {
  const lines = fs.readFileSync(csvPath, "utf8").split(/\r?\n/).slice(1).filter(Boolean);
  const counts: CsvCounts = { pass: 0, fail: 0, skip: 0, total: 0 };

  for (const line of lines) {
    const m = line.match(/,(PASS|FAIL|SKIP),/);
    if (!m) continue;
    const status = m[1];
    counts.total += 1;
    if (status === "PASS") counts.pass += 1;
    if (status === "FAIL") counts.fail += 1;
    if (status === "SKIP") counts.skip += 1;
  }
  return counts;
}

function summarizePerf() {
  if (!fs.existsSync(PERF_LOG)) {
    return {
      latestFeatureId: null,
      malformedRows: 0,
      rows: 0,
      tests: {},
    };
  }

  const lines = fs.readFileSync(PERF_LOG, "utf8").split(/\r?\n/).slice(1).filter(Boolean);
  const rows: PerfRow[] = [];
  let malformedRows = 0;

  for (const line of lines) {
    const cols = line.split(",");
    if (cols.length < 9) {
      malformedRows += 1;
      continue;
    }
    const timestamp = Number(cols[0]);
    const featureId = cols[1];
    const testName = cols[2];
    const opsPerSec = Number(cols[5]);
    if (!Number.isFinite(timestamp) || !featureId || !testName || !Number.isFinite(opsPerSec)) {
      malformedRows += 1;
      continue;
    }
    rows.push({ timestamp, featureId, testName, opsPerSec });
  }

  if (rows.length === 0) {
    return {
      latestFeatureId: null,
      malformedRows,
      rows: 0,
      tests: {},
    };
  }

  const latestFeatureId = rows[rows.length - 1].featureId;
  const latestRows = rows.filter((r) => r.featureId === latestFeatureId);
  const grouped = new Map<string, number[]>();
  for (const row of latestRows) {
    const arr = grouped.get(row.testName) ?? [];
    arr.push(row.opsPerSec);
    grouped.set(row.testName, arr);
  }

  const tests: Record<string, { samples: number; avgOpsPerSec: number }> = {};
  for (const [testName, values] of grouped) {
    const avg = values.reduce((a, b) => a + b, 0) / values.length;
    tests[testName] = {
      samples: values.length,
      avgOpsPerSec: Number(avg.toFixed(2)),
    };
  }

  return {
    latestFeatureId,
    malformedRows,
    rows: rows.length,
    tests,
  };
}

function toMarkdown(data: any): string {
  const lines: string[] = [];
  lines.push("# Testing Overview");
  lines.push("");
  lines.push(`Generated: ${data.generatedAtIso}`);
  lines.push("");
  lines.push("## Inventory");
  lines.push("");
  lines.push(`- Zig test files: ${data.tests.zigTestFiles}`);
  lines.push(`- TS test files: ${data.tests.tsTestFiles}`);
  lines.push(`- Parity case files: ${data.tests.parityCaseFiles}`);
  lines.push(`- Parity total cases: ${data.parityCoverage.totalCases}`);
  lines.push("");
  lines.push("## Backend Coverage");
  lines.push("");
  lines.push("| Backend | Runnable | Skipped |");
  lines.push("| :--- | ---: | ---: |");
  for (const backend of BACKENDS) {
    lines.push(
      `| ${backend} | ${data.parityCoverage.backendRunnable[backend]} | ${data.parityCoverage.backendSkipped[backend]} |`
    );
  }

  lines.push("");
  lines.push("## Latest Parity Run");
  lines.push("");
  if (!data.latestParity.taskId) {
    lines.push("- No parity report found.");
  } else {
    lines.push(`- task_id: ${data.latestParity.taskId}`);
    lines.push(`- report: tests/artifacts/parity/${data.latestParity.reportFile}`);
    lines.push("");
    lines.push("| Backend | Pass | Fail | Skip | Total |");
    lines.push("| :--- | ---: | ---: | ---: | ---: |");
    for (const backend of BACKENDS) {
      const c = data.latestParity.byBackend[backend];
      if (!c) {
        lines.push(`| ${backend} | - | - | - | - |`);
      } else {
        lines.push(`| ${backend} | ${c.pass} | ${c.fail} | ${c.skip} | ${c.total} |`);
      }
    }
  }

  lines.push("");
  lines.push("## Latest Performance Batch");
  lines.push("");
  lines.push(`- latest feature_id: ${data.perf.latestFeatureId ?? "none"}`);
  lines.push(`- parsed rows: ${data.perf.rows}`);
  lines.push(`- malformed rows ignored: ${data.perf.malformedRows}`);
  lines.push("");

  const perfTests = Object.entries(data.perf.tests) as Array<[string, { samples: number; avgOpsPerSec: number }]>;
  if (perfTests.length === 0) {
    lines.push("- No valid perf rows found.");
  } else {
    lines.push("| Test | Samples | Avg ops/s |");
    lines.push("| :--- | ---: | ---: |");
    for (const [name, s] of perfTests.sort((a, b) => a[0].localeCompare(b[0]))) {
      lines.push(`| ${name} | ${s.samples} | ${s.avgOpsPerSec} |`);
    }
  }

  lines.push("");
  lines.push("## Per-File Parity Breakdown");
  lines.push("");
  lines.push("| File | Cases | zig_vm run/skip | ts_ffi run/skip | ts_wasm_vm run/skip | wasm_aot run/skip |");
  lines.push("| :--- | ---: | ---: | ---: | ---: | ---: |");
  for (const row of data.parityCoverage.perFile) {
    lines.push(
      `| ${row.file} | ${row.cases} | ${row.runnable.zig_vm}/${row.skipped.zig_vm} | ${row.runnable.ts_ffi}/${row.skipped.ts_ffi} | ${row.runnable.ts_wasm_vm}/${row.skipped.ts_wasm_vm} | ${row.runnable.wasm_aot}/${row.skipped.wasm_aot} |`
    );
  }

  lines.push("");
  return lines.join("\n");
}

function safeList(dir: string): string[] {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir);
}

function countFiles(dir: string, pred: (filePath: string) => boolean): number {
  if (!fs.existsSync(dir)) return 0;
  let count = 0;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      count += countFiles(full, pred);
    } else if (pred(full)) {
      count += 1;
    }
  }
  return count;
}

function ensureDir(dir: string) {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

main();
