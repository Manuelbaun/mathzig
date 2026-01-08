import * as fs from "node:fs";
import * as path from "node:path";
import { compareValues, type Expected } from "./compare";
import { ZigVmBackend } from "./backends/zig_vm";
import { TsFfiBackend } from "./backends/ts_ffi";
import { TsWasmVmBackend } from "./backends/ts_wasm_vm";
import { WasmAotBackend, StandaloneUnsupportedError } from "./backends/wasm_aot";
import {
  evaluateStandaloneBudget,
  standaloneParticipated,
  type StandaloneSkipBudget,
  type StandaloneStats,
} from "../../tools/testing/standalone_skip_budget.ts";

export interface ParityBackend {
  name: string;
  init(): Promise<void> | void;
  reset?(): Promise<void> | void;
  evaluate(expr: string, vars: Record<string, number>): Promise<any> | any;
  dispose(): Promise<void> | void;
}

type ParityCase = {
  id: string;
  expr: string;
  vars: Record<string, number>;
  setup?: string[];
  expected?: Expected;
  tolerance?: number | { abs?: number; rel?: number };
  skip?: string[];
};

type BackendResult = {
  status: "PASS" | "FAIL" | "SKIP";
  reason?: string;
  value?: any;
};

type RunOptions = {
  taskId?: string;
  quick?: boolean;
  backends?: string[];
  isolateCases?: boolean;
  /** When true, also run (or only run if backends filtered) the standalone wasm_aot sub-run. */
  standalone?: boolean;
  /** Print each case as it finishes (default true for CLI). */
  verbose?: boolean;
};

const CASES_DIR = path.resolve("tests/parity/cases");
const ARTIFACTS_DIR = path.resolve("tests/artifacts/parity");

const DEFAULT_BACKENDS: ParityBackend[] = [
  new ZigVmBackend(),
  new TsFfiBackend(),
  new TsWasmVmBackend(),
  new WasmAotBackend(),
];
const STANDALONE_BACKEND = new WasmAotBackend({ standalone: true, name: "wasm_aot_standalone" });
const ALL_BACKENDS: ParityBackend[] = [...DEFAULT_BACKENDS, STANDALONE_BACKEND];
const KNOWN_BACKENDS = new Set(ALL_BACKENDS.map((b) => b.name));

/** Clear current TTY line (after \r progress) then print a full result line. */
function printCaseLine(
  backend: string,
  index: number,
  total: number,
  id: string,
  status: "PASS" | "FAIL" | "SKIP",
  detail?: string
): void {
  const n = `${index}/${total}`.padStart(7);
  const b = backend.padEnd(14);
  const mark =
    status === "PASS" ? "✓ PASS" : status === "FAIL" ? "✗ FAIL" : "○ SKIP";
  const tail = detail ? `  ${detail.slice(0, 80)}` : "";
  const line = `  ${n}  [${b}]  ${id.padEnd(36).slice(0, 36)}  ${mark}${tail}`;
  // Clear residual "▶ running…" line when stdout is a TTY.
  if (process.stdout.isTTY) {
    process.stdout.write("\x1b[2K\r");
  }
  console.log(line);
}

function printCaseRunning(
  backend: string,
  index: number,
  total: number,
  id: string
): void {
  if (!process.stdout.isTTY) return;
  const n = `${index}/${total}`.padStart(7);
  const b = backend.padEnd(14);
  process.stdout.write(
    `\x1b[2K\r  ▶ ${n}  [${b}]  ${id.slice(0, 40)} …`
  );
}

export async function runParity(opts: RunOptions = {}) {
  const taskId = opts.taskId ?? "baseline";
  const verbose = opts.verbose !== false;
  const cases = loadCases(opts.quick);
  let backends = filterBackends(DEFAULT_BACKENDS, opts.backends);
  // `--standalone` adds the wasm_aot_standalone backend (or is the sole
  // request when backends=wasm_aot_standalone).
  if (opts.standalone || (opts.backends ?? []).includes("wasm_aot_standalone")) {
    if (!backends.some((b) => b.name === "wasm_aot_standalone")) {
      backends = [...backends, STANDALONE_BACKEND];
    }
  }
  // If the only requested backend is standalone, drop the defaults.
  if (opts.backends?.length === 1 && opts.backends[0] === "wasm_aot_standalone") {
    backends = [STANDALONE_BACKEND];
  }
  // Standalone sub-run always needs a reference; pull zig_vm if missing.
  if (backends.some((b) => b.name === "wasm_aot_standalone") &&
      !backends.some((b) => b.name === "zig_vm")) {
    backends = [new ZigVmBackend(), ...backends];
  }
  const isolateCases = opts.isolateCases ?? false;

  ensureDir(ARTIFACTS_DIR);

  const results: Record<string, Record<string, BackendResult>> = {};
  const total = cases.length;
  // Final per-case status after compare (for CSV + live lines).
  const finalStatus: Record<string, Record<string, { status: "PASS" | "FAIL" | "SKIP"; reason?: string }>> =
    {};

  // Prefer evaluating reference backend first so we can print final PASS/FAIL live.
  const reference = selectReference(backends.map((b) => b.name));
  backends = [
    ...backends.filter((b) => b.name === reference),
    ...backends.filter((b) => b.name !== reference),
  ];

  if (verbose) {
    console.log(
      `Parity: ${total} cases × ${backends.map((b) => b.name).join(", ")}  (task=${taskId})`
    );
    console.log(`Reference: ${reference}`);
  }

  for (const backend of backends) {
    if (verbose) {
      console.log(`\n── backend ${backend.name} (${total} cases) ──`);
    }
    let initialized = false;
    if (!isolateCases) {
      if (verbose) console.log(`  init ${backend.name}…`);
      await backend.init();
      initialized = true;
      if (verbose) console.log(`  init ${backend.name}: ok`);
    }
    results[backend.name] = {};
    finalStatus[backend.name] = {};
    let i = 0;
    let pass = 0;
    let fail = 0;
    let skip = 0;

    for (const testCase of cases) {
      i += 1;
      if (verbose) {
        // Show which case is starting (important for slow AOT compiles).
        printCaseRunning(backend.name, i, total, testCase.id);
      }

      if (
        testCase.skip?.includes(backend.name) ||
        (backend.name === "wasm_aot_standalone" && testCase.skip?.includes("wasm_aot"))
      ) {
        results[backend.name][testCase.id] = { status: "SKIP", reason: "case skip list" };
        finalStatus[backend.name][testCase.id] = { status: "SKIP", reason: "case skip list" };
        skip += 1;
        if (verbose) {
          printCaseLine(backend.name, i, total, testCase.id, "SKIP", "case skip list");
        }
        continue;
      }
      if (typeof backend.reset === "function") {
        await backend.reset();
      }
      if (isolateCases) {
        if (initialized) {
          await backend.dispose();
        }
        await backend.init();
        initialized = true;
      }
      try {
        if (testCase.setup && testCase.setup.length > 0) {
          for (const line of testCase.setup) {
            await backend.evaluate(line, testCase.vars);
          }
        }
        const rawVal = await backend.evaluate(testCase.expr, testCase.vars);
        const val = snapshotValue(rawVal, testCase.expected);
        results[backend.name][testCase.id] = { status: "PASS", value: val };
      } catch (err: any) {
        if (err instanceof StandaloneUnsupportedError || err?.skip === true) {
          const reason = String(err?.message ?? err);
          results[backend.name][testCase.id] = { status: "SKIP", reason };
          finalStatus[backend.name][testCase.id] = { status: "SKIP", reason };
          skip += 1;
          if (verbose) {
            printCaseLine(backend.name, i, total, testCase.id, "SKIP", reason);
          }
          continue;
        }
        const reason = String(err?.message ?? err);
        results[backend.name][testCase.id] = {
          status: "FAIL",
          reason,
          value: { __error: reason },
        };
      }

      // Immediate final status vs reference (or self for reference backend).
      const caseResult = results[backend.name][testCase.id]!;
      const refRes = results[reference]?.[testCase.id];

      if (caseResult.status === "SKIP") {
        finalStatus[backend.name][testCase.id] = {
          status: "SKIP",
          reason: caseResult.reason,
        };
        skip += 1;
        if (verbose) {
          printCaseLine(
            backend.name,
            i,
            total,
            testCase.id,
            "SKIP",
            caseResult.reason ?? ""
          );
        }
        continue;
      }

      if (!refRes || refRes.status === "SKIP") {
        // Reference not ready or skipped — keep eval status for reference backend itself.
        if (backend.name === reference) {
          const st = caseResult.status === "PASS" ? "PASS" : "FAIL";
          finalStatus[backend.name][testCase.id] = {
            status: st,
            reason: caseResult.reason,
          };
          if (st === "PASS") pass += 1;
          else fail += 1;
          if (verbose) {
            printCaseLine(backend.name, i, total, testCase.id, st, caseResult.reason);
          }
        } else {
          finalStatus[backend.name][testCase.id] = {
            status: "SKIP",
            reason: "reference skipped",
          };
          skip += 1;
          if (verbose) {
            printCaseLine(
              backend.name,
              i,
              total,
              testCase.id,
              "SKIP",
              "reference skipped"
            );
          }
        }
        continue;
      }

      // Compare even when a backend FAILEDed — matching errors vs the
      // reference still count as parity PASS (pre-task-05 behaviour).
      const compare = compareValues(refRes.value, caseResult.value, {
        tolerance: normalizeTolerance(testCase.tolerance),
        expected: testCase.expected,
      });

      if (compare.ok) {
        finalStatus[backend.name][testCase.id] = { status: "PASS" };
        pass += 1;
        if (verbose) {
          printCaseLine(backend.name, i, total, testCase.id, "PASS");
        }
      } else {
        const reason = compare.reason ?? "mismatch";
        finalStatus[backend.name][testCase.id] = { status: "FAIL", reason };
        fail += 1;
        if (verbose) {
          printCaseLine(backend.name, i, total, testCase.id, "FAIL", reason);
        }
      }
    }

    if (initialized) {
      await backend.dispose();
    }
    if (verbose) {
      console.log(
        `  ${backend.name} done: pass=${pass} fail=${fail} skip=${skip}`
      );
    }
  }

  const reportLines: string[] = [];
  let failureCount = 0;
  const standaloneStats = { covered: 0, skipped: 0, failed: 0 };

  for (const backend of backends) {
    const csvLines: string[] = ["id,expr,status,reason"];
    for (const testCase of cases) {
      const fin = finalStatus[backend.name]?.[testCase.id] ?? {
        status: "FAIL" as const,
        reason: "missing result",
      };
      if (fin.status === "SKIP") {
        csvLines.push(
          `${testCase.id},"${escapeCsv(testCase.expr)}",SKIP,"${escapeCsv(fin.reason ?? "")}"`
        );
        if (backend.name === "wasm_aot_standalone") standaloneStats.skipped += 1;
      } else if (fin.status === "PASS") {
        csvLines.push(`${testCase.id},"${escapeCsv(testCase.expr)}",PASS,`);
        if (backend.name === "wasm_aot_standalone") standaloneStats.covered += 1;
      } else {
        const reason = fin.reason ?? "mismatch";
        csvLines.push(
          `${testCase.id},"${escapeCsv(testCase.expr)}",FAIL,"${escapeCsv(reason)}"`
        );
        reportLines.push(`- **${backend.name}** ${testCase.id}: ${reason}`);
        failureCount += 1;
        if (backend.name === "wasm_aot_standalone") standaloneStats.failed += 1;
      }
    }

    const csvPath = path.join(ARTIFACTS_DIR, `${taskId}_${backend.name}.csv`);
    fs.writeFileSync(csvPath, csvLines.join("\n"));
    if (verbose) {
      console.log(`  wrote ${path.relative(process.cwd(), csvPath)}`);
    }
  }

  const reportPath = path.join(ARTIFACTS_DIR, `${taskId}_report.md`);
  let report = reportLines.length === 0
    ? "# Parity Report\n\nAll cases passed."
    : `# Parity Report\n\nFailures:\n${reportLines.join("\n")}`;
  if (backends.some((b) => b.name === "wasm_aot_standalone")) {
    report += `\n\n## Standalone sub-run (wasm_aot_standalone)\n\n` +
      `- covered: ${standaloneStats.covered}\n` +
      `- skipped-with-reason: ${standaloneStats.skipped}\n` +
      `- failed: ${standaloneStats.failed}\n`;
  }
  fs.writeFileSync(reportPath, report);

  if (verbose) {
    console.log(
      `\nParity summary: failures=${failureCount}  reference=${reference}`
    );
  }

  return { results, reportPath, reference, failureCount, standaloneStats };
}

const KNOWN_FAILURES_PATH = path.resolve("tests/known_failures.json");

function loadStandaloneBudget(): StandaloneSkipBudget | null {
  if (!fs.existsSync(KNOWN_FAILURES_PATH)) return null;
  try {
    const raw = JSON.parse(fs.readFileSync(KNOWN_FAILURES_PATH, "utf8")) as {
      standalone_skip_budget?: StandaloneSkipBudget;
    };
    const b = raw.standalone_skip_budget;
    if (
      !b ||
      typeof b.max_skips !== "number" ||
      typeof b.max_fails !== "number"
    ) {
      return null;
    }
    return b;
  } catch {
    return null;
  }
}

/**
 * Enforce standalone_skip_budget when wasm_aot_standalone participated.
 * Writes optional artifact JSON; returns budget result (or null if N/A).
 */
export function enforceStandaloneBudget(
  taskId: string,
  stats: StandaloneStats,
  opts: { verbose?: boolean; writeArtifact?: boolean } = {}
): ReturnType<typeof evaluateStandaloneBudget> | null {
  if (!standaloneParticipated(stats)) return null;
  const budget = loadStandaloneBudget();
  if (!budget) {
    if (opts.verbose !== false) {
      console.warn(
        "standalone_budget: no standalone_skip_budget in tests/known_failures.json — skip ceiling not enforced"
      );
    }
    return null;
  }
  const result = evaluateStandaloneBudget(stats, budget);
  if (opts.verbose !== false) {
    console.log(result.summary_line);
  }
  if (opts.writeArtifact !== false) {
    ensureDir(ARTIFACTS_DIR);
    const outPath = path.join(ARTIFACTS_DIR, `${taskId}_standalone_budget.json`);
    fs.writeFileSync(
      outPath,
      JSON.stringify(
        {
          task_id: taskId,
          ...result.stats,
          max_skips: budget.max_skips,
          max_fails: budget.max_fails,
          ok: result.ok,
          over_skips: result.over_skips,
          over_fails: result.over_fails,
          summary_line: result.summary_line,
          note: budget.note,
        },
        null,
        2
      ) + "\n"
    );
    if (opts.verbose !== false) {
      console.log(`  wrote ${path.relative(process.cwd(), outPath)}`);
    }
  }
  return result;
}

function loadCases(quick?: boolean): ParityCase[] {
  if (!fs.existsSync(CASES_DIR)) return [];
  const files = fs.readdirSync(CASES_DIR).filter((f) => f.endsWith(".json")).sort();
  const selected = quick ? files.filter((f) => f.startsWith("core")) : files;
  const cases: ParityCase[] = [];
  const seenIds = new Set<string>();
  for (const file of selected) {
    const fullPath = path.join(CASES_DIR, file);
    const raw = JSON.parse(fs.readFileSync(fullPath, "utf-8"));
    if (!Array.isArray(raw)) {
      throw new Error(`Parity case file must be a JSON array: ${fullPath}`);
    }
    for (let idx = 0; idx < raw.length; idx += 1) {
      const item = validateCase(raw[idx], fullPath, idx + 1);
      if (seenIds.has(item.id)) {
        throw new Error(`Duplicate parity case id '${item.id}' in ${fullPath}`);
      }
      seenIds.add(item.id);
      cases.push(item);
    }
  }
  return cases;
}

function validateCase(input: unknown, filePath: string, oneBasedIndex: number): ParityCase {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    throw new Error(`Invalid parity case at ${filePath}#${oneBasedIndex}: expected object`);
  }

  const c = input as Record<string, unknown>;

  if (typeof c.id !== "string" || c.id.trim() === "") {
    throw new Error(`Invalid parity case at ${filePath}#${oneBasedIndex}: missing string id`);
  }
  if (typeof c.expr !== "string" || c.expr.trim() === "") {
    throw new Error(`Invalid parity case '${c.id}' in ${filePath}: missing string expr`);
  }

  const vars = normalizeVars(c.vars, c.id, filePath);
  const setup = normalizeSetup(c.setup, c.id, filePath);
  const skip = normalizeSkip(c.skip, c.id, filePath);
  const tolerance = normalizeToleranceInput(c.tolerance, c.id, filePath);

  return {
    id: c.id,
    expr: c.expr,
    vars,
    setup,
    expected: c.expected as Expected | undefined,
    tolerance,
    skip,
  };
}

function normalizeVars(
  vars: unknown,
  caseId: string,
  filePath: string
): Record<string, number> {
  if (vars === undefined) return {};
  if (!vars || typeof vars !== "object" || Array.isArray(vars)) {
    throw new Error(`Invalid vars for case '${caseId}' in ${filePath}: expected object`);
  }
  const out: Record<string, number> = {};
  for (const [k, v] of Object.entries(vars as Record<string, unknown>)) {
    if (typeof v !== "number" || !Number.isFinite(v)) {
      throw new Error(`Invalid vars.${k} for case '${caseId}' in ${filePath}: expected finite number`);
    }
    out[k] = v;
  }
  return out;
}

function normalizeSetup(setup: unknown, caseId: string, filePath: string): string[] | undefined {
  if (setup === undefined) return undefined;
  if (!Array.isArray(setup) || setup.some((x) => typeof x !== "string")) {
    throw new Error(`Invalid setup for case '${caseId}' in ${filePath}: expected string[]`);
  }
  return setup as string[];
}

function normalizeSkip(skip: unknown, caseId: string, filePath: string): string[] | undefined {
  if (skip === undefined) return undefined;
  if (!Array.isArray(skip) || skip.some((x) => typeof x !== "string")) {
    throw new Error(`Invalid skip for case '${caseId}' in ${filePath}: expected string[]`);
  }
  const list = skip as string[];
  for (const backend of list) {
    if (!KNOWN_BACKENDS.has(backend)) {
      throw new Error(`Invalid skip backend '${backend}' for case '${caseId}' in ${filePath}`);
    }
  }
  return list;
}

function normalizeToleranceInput(
  tolerance: unknown,
  caseId: string,
  filePath: string
): number | { abs?: number; rel?: number } | undefined {
  if (tolerance === undefined) return undefined;
  if (typeof tolerance === "number") {
    if (!Number.isFinite(tolerance) || tolerance < 0) {
      throw new Error(`Invalid numeric tolerance for case '${caseId}' in ${filePath}`);
    }
    return tolerance;
  }
  if (!tolerance || typeof tolerance !== "object" || Array.isArray(tolerance)) {
    throw new Error(`Invalid tolerance for case '${caseId}' in ${filePath}: expected number or object`);
  }
  const t = tolerance as Record<string, unknown>;
  const abs = t.abs;
  const rel = t.rel;
  if (abs !== undefined && (typeof abs !== "number" || !Number.isFinite(abs) || abs < 0)) {
    throw new Error(`Invalid tolerance.abs for case '${caseId}' in ${filePath}`);
  }
  if (rel !== undefined && (typeof rel !== "number" || !Number.isFinite(rel) || rel < 0)) {
    throw new Error(`Invalid tolerance.rel for case '${caseId}' in ${filePath}`);
  }
  return { abs: abs as number | undefined, rel: rel as number | undefined };
}

function normalizeTolerance(
  tolerance?: number | { abs?: number; rel?: number }
): { abs?: number; rel?: number } | undefined {
  if (tolerance === undefined) return undefined;
  if (typeof tolerance === "number") {
    return { abs: tolerance, rel: tolerance };
  }
  return tolerance;
}

function filterBackends(backends: ParityBackend[], names?: string[]): ParityBackend[] {
  if (!names || names.length === 0) return backends;
  const set = new Set(names);
  const fromDefaults = backends.filter((b) => set.has(b.name));
  // wasm_aot_standalone is opt-in and not in DEFAULT_BACKENDS.
  if (set.has("wasm_aot_standalone") && !fromDefaults.some((b) => b.name === "wasm_aot_standalone")) {
    fromDefaults.push(STANDALONE_BACKEND);
  }
  if (fromDefaults.length === 0) {
    throw new Error(`No known backends in: ${names.join(",")}. Known: ${[...KNOWN_BACKENDS].join(",")}`);
  }
  return fromDefaults;
}

function selectReference(backendNames: string[]): string {
  if (backendNames.includes("zig_vm")) return "zig_vm";
  if (backendNames.includes("ts_ffi")) return "ts_ffi";
  return backendNames[0];
}

function ensureDir(dir: string) {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

function escapeCsv(val: string): string {
  return val.replace(/"/g, '""');
}

function snapshotValue(value: any, expected?: Expected): any {
  if (value === null || value === undefined) return value;
  const t = typeof value;
  if (t === "number" || t === "boolean" || t === "string") return value;
  if (Array.isArray(value)) return value.map((v) => snapshotValue(v));
  if (value && typeof value === "object" && value.__error) return value;

  const tag = typeof value?.tag === "number" ? value.tag : undefined;

  // Unit values compare best as numbers.
  if (tag === 2 && typeof value?.num === "number") {
    return value.num;
  }

  // Matrix wrappers are converted to plain shape+data snapshots.
  if (tag === 3 || isMatrixLike(value)) {
    const rows = Number(value.rows ?? NaN);
    const cols = Number(value.cols ?? NaN);
    const rawData = value.data instanceof Float64Array
      ? value.data
      : Array.isArray(value.data)
        ? Float64Array.from(value.data)
        : null;
    if (Number.isFinite(rows) && Number.isFinite(cols) && rawData) {
      return { tag: 3, rows, cols, data: Float64Array.from(rawData) };
    }
  }

  // Record wrappers can be snapshotted by expected keys when present.
  if ((tag === 10 || typeof value?.getField === "function") && isRecordExpected(expected)) {
    const fields: Record<string, any> = {};
    for (const key of expected.keys) {
      try {
        fields[key] = snapshotValue(value.getField(key));
      } catch {
        fields[key] = { __error: `missing:${key}` };
      }
    }
    return {
      tag: 10,
      __record_keys: [...expected.keys],
      getField: (k: string) => fields[k],
    };
  }

  // Series wrappers are snapshotted by length to avoid stale FFI handles.
  // Support: FFI Series (len method), wasm {tag:4,len}, or {tag:4,ptr} with len field.
  if (tag === 4 || typeof value?.len === "function" || typeof value?.len === "number") {
    try {
      if (typeof value?.len === "number" && Number.isFinite(value.len)) {
        return { tag: 4, len: value.len };
      }
      if (typeof value?.len === "function") {
        const len = Number(value.len());
        if (Number.isFinite(len)) {
          return { tag: 4, len };
        }
      }
    } catch {
      return { tag: 4, __error: "series_len_unavailable" };
    }
  }

  if (tag === 1 && typeof value?.real === "function" && typeof value?.imag === "function") {
    try {
      return { tag: 1, re: Number(value.real()), im: Number(value.imag()) };
    } catch {
      // fall through
    }
  }

  // String values: snapshot before FFI context teardown (wasm_aot returns plain strings).
  if (tag === 6 && value?.owner?.backend?.call) {
    try {
      const buf = new Uint8Array(4096);
      const len = Number(
        value.owner.backend.call("mathzig_format_last_value", value.owner.handle, buf, BigInt(buf.length))
      );
      if (!Number.isFinite(len) || len <= 0) return "";
      let text = new TextDecoder().decode(buf.subarray(0, len));
      if (text.length >= 2 && text.startsWith("\"") && text.endsWith("\"")) {
        text = text.slice(1, -1);
      }
      return text;
    } catch {
      return { tag: 6, __error: "string_snapshot_unavailable" };
    }
  }

  return value;
}

function isRecordExpected(expected?: Expected): expected is { tag: "record"; keys: string[] } {
  return !!expected && (expected as any).tag === "record" && Array.isArray((expected as any).keys);
}

function isMatrixLike(value: any): boolean {
  return !!value &&
    typeof value === "object" &&
    typeof value.rows === "number" &&
    typeof value.cols === "number";
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const unknown = args.filter((a) =>
    !a.startsWith("--task-id=") &&
    !a.startsWith("--backends=") &&
    a !== "--quick" &&
    a !== "--full" &&
    a !== "--isolate" &&
    a !== "--standalone" &&
    a !== "--verbose" &&
    a !== "--quiet"
  );
  if (unknown.length > 0) {
    throw new Error(`Unknown parity args: ${unknown.join(", ")}`);
  }
  const taskIdArg = args.find((a) => a.startsWith("--task-id="));
  const full = args.includes("--full");
  const quick = args.includes("--quick");
  if (full && quick) {
    throw new Error("Use either --quick or --full, not both");
  }
  const backendsArg = args.find((a) => a.startsWith("--backends="));
  const isolateCases = args.includes("--isolate");
  const standalone = args.includes("--standalone");
  // Default: verbose live case lines. --quiet turns them off.
  const verbose = !args.includes("--quiet");

  const taskId = taskIdArg
    ? taskIdArg.split("=")[1]
    : standalone && !backendsArg
      ? (full ? "baseline_full_standalone" : quick ? "baseline_quick_standalone" : "baseline_standalone")
      : quick
        ? "baseline_quick_check"
        : full
          ? "baseline_full"
          : "baseline";
  const backends = backendsArg ? backendsArg.split("=")[1].split(",") : undefined;

  runParity({ taskId, quick, backends, isolateCases, standalone, verbose }).then((res) => {
    console.log(`Parity complete. Reference: ${res.reference}`);
    console.log(`Report: ${res.reportPath}`);
    if (res.standaloneStats && standaloneParticipated(res.standaloneStats)) {
      console.log(
        `Standalone: covered=${res.standaloneStats.covered} skipped=${res.standaloneStats.skipped} failed=${res.standaloneStats.failed}`,
      );
    }
    let budgetFailed = false;
    if (res.standaloneStats) {
      const budgetResult = enforceStandaloneBudget(taskId, res.standaloneStats, {
        verbose,
        writeArtifact: true,
      });
      if (budgetResult && !budgetResult.ok) {
        console.error(
          `Standalone budget exceeded: ${budgetResult.summary_line}`
        );
        budgetFailed = true;
      }
    }
    if (res.failureCount > 0) {
      console.error(`Parity failed: ${res.failureCount} mismatches`);
      process.exitCode = 1;
    }
    if (budgetFailed) {
      process.exitCode = 1;
    }
  });
}
